import AVFoundation
import Foundation
import LiveKitWebRTC
import SinuaVoice

/// `VoiceSource` for OpenAI's GPT-Live (`gpt-live-1`) over WebRTC -- the native mirror of the
/// Web `OpenAILiveVoiceSource` (packages/voice/src/OpenAILiveVoiceSource.ts), on the same
/// LiveKit WebRTC build as `OpenAIRealtimeVoiceSource`.
///
/// GPT-Live has no client credential: your server opens the session (`POST /v1/live/sessions`
/// with its project key). This source gathers ICE, POSTs `{ "sdp": … }` as JSON to your
/// `sessionURL` (with `Authorization: Bearer` when you give it a credential -- your own
/// token, never `sk-…`), and takes OpenAI's 201 JSON back unchanged (or the bare SDP). The
/// session is live at `session.started`; the client never sends `session.start`. Model,
/// voice, instructions, delegation and prior conversation are set by your server.
///
/// State comes from `OpenAILiveSession` (SinuaVoice, unit-tested against
/// spec/openai-live-cases.json): the model's audio level is `speaking`, an open backend
/// delegation is `thinking`, user speech that stops the model is a barge-in.
///
/// `disconnect()` goes idle at once, then sends `session.close` and keeps the call until
/// `session.closed` (up to 5 s) so the final usage is confirmed. `expired` /
/// `connection_lost`, or a call that drops without `session.closed`, is replaced by a new
/// session (up to 3 attempts, a fresh credential each); `close_requested`,
/// `remote_hangup` and `content` end in idle.
///
/// `warp`: WARP's libwebrtc field trials only (DTLS 1.3 / SNAP / SPED). OpenAI documents no
/// `dcid` for GPT-Live, so there's no pre-negotiated channel here; experimental.
///
/// **Not exercised at runtime by any test** (a peer connection opens the real mic and
/// speakers). Compile-verified; the I/O-free rules are unit-tested.
public final class OpenAILiveVoiceSource: NSObject, VoiceSource, @unchecked Sendable {
    public static let updateHz = 30.0
    static let iceGatheringTimeout: TimeInterval = 10
    static let startedTimeout: TimeInterval = 15
    static let closeTimeout: TimeInterval = 5
    static let reconnectingReasons: Set<String> = ["expired", "connection_lost"]

    private let sessionURL: URL
    private let credentials: CredentialSource?
    private let warp: Bool
    private let reconnects: Bool
    private let urlSession: URLSession
    private let requestPermission: () async -> Bool
    private let session = OpenAILiveSession()
    private let tap = PcmTap()
    private lazy var renderer = Renderer(sink: tap.sink)

    // Main-thread state.
    private var factory: LKRTCPeerConnectionFactory?
    private var pc: LKRTCPeerConnection?
    private var channel: LKRTCDataChannel?
    private var remoteTrack: LKRTCAudioTrack?
    private var gatheringWaiter: CheckedContinuation<Void, Error>?
    private var startedWaiter: CheckedContinuation<Void, Error>?
    private var closeTimer: DispatchWorkItem?
    private var waitGeneration = 0
    private var wantConnected = false
    private var connected = false
    private var reconnecting = false
    private var timer: DispatchSourceTimer?
    private var metricsCb: ((VoiceMetrics) -> Void)?
    private var connectionCb: ((Bool) -> Void)?
    private var sessionUp = false
    private var micTrack: LKRTCAudioTrack?
    private var muted = false

    /// `sessionURL`: your endpoint that opens the GPT-Live session (never `api.openai.com`).
    /// `credential`: your own token for it, fresh per session with `.url(…)` / `.provider { … }`;
    /// nil when your endpoint authenticates another way.
    public init(
        sessionURL: URL,
        credential: CredentialSource? = nil,
        warp: Bool = false,
        reconnect: Bool = true,
        urlSession: URLSession = .shared,
        requestPermission: @escaping () async -> Bool = AVPcmAudioDevice.requestPermission
    ) {
        self.sessionURL = sessionURL
        credentials = credential
        self.warp = warp
        reconnects = reconnect
        self.urlSession = urlSession
        self.requestPermission = requestPermission
        super.init()
        session.onClosed = { [weak self] reason in self?.closed(reason) }
    }

    /// `session.started`'s id for the current call, once live (e.g. for your server's sideband).
    public var sessionId: String? { session.sessionId }

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { metricsCb = cb }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { session.onState = cb }
    public func onInterrupt(_ cb: @escaping () -> Void) { session.onInterrupt = cb }
    public func onConnectionChange(_ cb: @escaping (Bool) -> Void) { connectionCb = cb }
    public var reportsConnection: Bool { true }
    public var supportsMute: Bool { true }

    /// Muted, the mic track is disabled: WebRTC sends silence and the session stays up.
    public func setMuted(_ muted: Bool) {
        let apply = { [self] in
            self.muted = muted
            micTrack?.isEnabled = !muted
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func setSessionUp(_ up: Bool) {
        guard up != sessionUp else { return }
        sessionUp = up
        connectionCb?(up)
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

    /// Your token for this (re)connect, or nil without a credential source.
    private func resolveToken() async throws -> String? {
        guard let credentials else { return nil }
        let token = try await credentials.resolve(vendor: "OpenAILiveVoiceSource").credential
        try InsecureCredential.checkOpenAILive(sessionURL: sessionURL, credential: token)
        return token
    }

    public func connect() async throws {
        await MainActor.run {
            finishClose()  // a graceful close still draining from a previous disconnect()
            wantConnected = true
            session.connecting()
        }
        do {
            try InsecureCredential.checkOpenAILive(sessionURL: sessionURL, credential: nil)
            let token = try await resolveToken()  // auth first: no prompt for a bad credential
            guard await requestPermission() else { throw VoiceSourceError.permissionDenied }
            try await call(token)
            await MainActor.run {
                connected = true
                startTimer()
                setSessionUp(true)
            }
        } catch {
            await MainActor.run { teardown() }
            throw error
        }
    }

    /// Idle at once; then `session.close`, and the call is kept (mic silent, playback off)
    /// until `session.closed` confirms the final usage, or 5 s pass.
    public func disconnect() {
        let work = { [self] in
            let graceful = connected && session.isStarted && channel?.readyState == .open
            wantConnected = false
            reconnecting = false
            connected = false
            timer?.cancel()
            timer = nil
            session.stopped()
            setSessionUp(false)
            guard graceful else { return teardown() }
            micTrack?.isEnabled = false
            remoteTrack?.isEnabled = false
            metricsCb?(.silent)
            send(#"{"type":"session.close"}"#)
            let item = DispatchWorkItem { [weak self] in
                NSLog("OpenAILiveVoiceSource: no session.closed within 5s; final usage unconfirmed")
                self?.finishClose()
            }
            closeTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeTimeout, execute: item)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    /// Ends a graceful close (answered, timed out, or cut short by a new connect). Main thread.
    private func finishClose() {
        guard let item = closeTimer else { return }
        item.cancel()
        closeTimer = nil
        teardown()
    }

    // MARK: - The call (one GPT-Live session)

    private func call(_ token: String?) async throws {
        let (pc, constraints) = try await MainActor.run { () throws -> (LKRTCPeerConnection, LKRTCMediaConstraints) in
            if warp, factory == nil { WarpFieldTrials.enable() }
            let f = factory ?? LKRTCPeerConnectionFactory()
            factory = f
            let config = LKRTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let pc = f.peerConnection(with: config, constraints: constraints, delegate: self) else {
                throw OpenAIRealtimeError.peerConnection
            }
            self.pc = pc
            let mic = f.audioTrack(with: f.audioSource(with: constraints), trackId: "mic")
            mic.isEnabled = !muted
            micTrack = mic
            pc.add(mic, streamIds: ["mic"])
            // Created before the offer (OpenAI's sequence).
            let dc = pc.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration())
            dc?.delegate = self
            channel = dc
            return (pc, constraints)
        }
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        // GPT-Live takes one complete offer (no trickle ICE).
        try await wait(timeout: Self.iceGatheringTimeout, error: OpenAIRealtimeError.timeout) { cont in
            if pc.iceGatheringState == .complete { return cont.resume() }
            self.gatheringWaiter = cont
        } cancel: {
            self.gatheringWaiter
        } clear: {
            self.gatheringWaiter = nil
        }
        let sdp = await MainActor.run { pc.localDescription?.sdp } ?? offer.sdp
        let (status, body) = try await OpenAIRealtimeSignaling.send(
            OpenAILiveSignaling.sessionRequest(sdpOffer: sdp, token: token, url: sessionURL), session: urlSession)
        let answer = try OpenAILiveSignaling.answer(status: status, body: body)
        guard await MainActor.run(body: { self.pc === pc }) else { throw CancellationError() }
        try await pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer.sdp))
        try await wait(timeout: Self.startedTimeout, error: OpenAIRealtimeError.timeout) { cont in
            if self.session.isStarted { return cont.resume() }
            self.startedWaiter = cont
        } cancel: {
            self.startedWaiter
        } clear: {
            self.startedWaiter = nil
        }
    }

    /// Parks a continuation (main thread) until it's resumed elsewhere or `timeout` passes.
    private func wait(
        timeout: TimeInterval, error: Error,
        park: @escaping (CheckedContinuation<Void, Error>) -> Void,
        cancel: @escaping () -> CheckedContinuation<Void, Error>?,
        clear: @escaping () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                self.waitGeneration += 1
                let generation = self.waitGeneration
                park(cont)
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    // A later wait owns the slot now: this timer is stale.
                    guard generation == self.waitGeneration, let w = cancel() else { return }
                    clear()
                    w.resume(throwing: error)
                }
            }
        }
    }

    private func send(_ text: String) {
        _ = channel?.sendData(LKRTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    private func closeCall() {
        remoteTrack?.remove(renderer)
        remoteTrack = nil
        tap.reset()
        channel?.delegate = nil
        channel?.close()
        channel = nil
        micTrack = nil
        pc?.close()
        pc = nil
        gatheringWaiter?.resume(throwing: CancellationError())
        gatheringWaiter = nil
        startedWaiter?.resume(throwing: OpenAIRealtimeError.channelClosed)
        startedWaiter = nil
    }

    /// `session.closed` from the server. Main thread.
    private func closed(_ reason: String) {
        if let w = startedWaiter {
            startedWaiter = nil
            let message = "OpenAILiveVoiceSource: the session closed before it started (\(reason))"
            w.resume(throwing: CredentialError.fatal(message))
        }
        if closeTimer != nil { return finishClose() }
        guard connected, wantConnected else { return }
        if Self.reconnectingReasons.contains(reason) {
            dropped("session closed (\(reason))")
        } else {
            NSLog("OpenAILiveVoiceSource: session closed (%@)", reason)
            teardown()
        }
    }

    /// Main thread.
    private func dropped(_ reason: String) {
        if closeTimer != nil { return finishClose() }
        guard connected, wantConnected, !reconnecting else { return }
        Task { await reconnect(reason) }
    }

    private func reconnect(_ reason: String) async {
        let fatal = await MainActor.run { () -> String? in
            reconnecting = true
            connected = false
            let code = session.fatalCode
            closeCall()
            session.connecting()
            metricsCb?(.silent)  // go quiet instead of freezing
            return code
        }
        if reconnects, fatal == nil {
            attempts: for attempt in 1...RealtimeReconnect.defaultAttempts {
                guard await MainActor.run(body: { wantConnected }) else { break }
                try? await Task.sleep(nanoseconds: UInt64(RealtimeReconnect.delayMs(attempt: attempt)) * 1_000_000)
                do {
                    try await call(try await resolveToken())
                    let live = await MainActor.run { () -> Bool in
                        guard wantConnected else { return false }
                        reconnecting = false
                        connected = true
                        return true
                    }
                    if live { return }
                    break attempts
                } catch let e as OpenAIRealtimeSignaling.SignalingError {
                    if case .fatal = e { break attempts }
                    if case .malformed = e { break attempts }
                } catch let e as CredentialError where e.isFatal {
                    break attempts
                } catch {
                    NSLog("GPT-Live reconnect %d after %@ failed: %@", attempt, reason, String(describing: error))
                }
                await MainActor.run { closeCall() }
            }
        } else {
            let why = reconnects ? "fatal error \(fatal ?? "")" : "reconnect off"
            NSLog("GPT-Live %@; not reconnecting (%@)", reason, why)
        }
        await MainActor.run {
            reconnecting = false
            teardown()
        }
    }

    // MARK: - Tick / teardown

    private func startTimer() {
        guard timer == nil, wantConnected else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1 / Self.updateHz)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard remoteTrack != nil else {
            session.tick(level: 0, now: Self.now())  // delegation timeouts still run
            return
        }
        let m = tap.read()
        metricsCb?(m)
        session.tick(level: m.level, now: Self.now())
    }

    private func teardown() {
        wantConnected = false
        connected = false
        timer?.cancel()
        timer = nil
        closeTimer?.cancel()
        closeTimer = nil
        closeCall()
        factory = nil
        session.stopped()
        setSessionUp(false)
    }

    /// WebRTC audio thread: copy the model's PCM into the tap.
    private final class Renderer: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
        let sink: LiveKitPcmSink
        init(sink: LiveKitPcmSink) { self.sink = sink }

        func render(pcmBuffer: AVAudioPCMBuffer) {
            let n = Int(pcmBuffer.frameLength)
            guard n > 0 else { return }
            if let ch = pcmBuffer.floatChannelData?[0] {
                sink.write(UnsafeBufferPointer(start: ch, count: n))
            } else if let ch = pcmBuffer.int16ChannelData?[0] {
                let channels = pcmBuffer.format.isInterleaved ? Int(pcmBuffer.format.channelCount) : 1
                sink.write(int16: UnsafeBufferPointer(start: ch, count: n * channels), channels: channels)
            }
        }
    }
}

// MARK: - WebRTC delegates (WebRTC threads -> main)

extension OpenAILiveVoiceSource: LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
    public func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    public func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
    public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
    public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
    public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}

    public func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        guard newState == .complete else { return }
        DispatchQueue.main.async {
            guard pc === self.pc, let w = self.gatheringWaiter else { return }
            self.gatheringWaiter = nil
            w.resume()
        }
    }

    public func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        guard newState == .failed || newState == .closed else { return }
        DispatchQueue.main.async { if pc === self.pc { self.dropped("ice \(newState.rawValue)") } }
    }

    public func peerConnection(_ pc: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? LKRTCAudioTrack else { return }
        DispatchQueue.main.async {
            guard pc === self.pc, self.remoteTrack !== track else { return }
            self.remoteTrack?.remove(self.renderer)
            self.tap.reset()
            self.remoteTrack = track
            track.add(self.renderer)
        }
    }

    public func dataChannelDidChangeState(_ dc: LKRTCDataChannel) {
        let state = dc.readyState
        DispatchQueue.main.async {
            guard dc === self.channel, state == .closed else { return }
            self.dropped("data channel closed")
        }
    }

    public func dataChannel(_ dc: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        let text = String(decoding: buffer.data, as: UTF8.self)
        DispatchQueue.main.async {
            guard dc === self.channel else { return }
            self.session.handle(text, now: Self.now())
            if self.session.isStarted, let w = self.startedWaiter {
                self.startedWaiter = nil
                w.resume()
            }
        }
    }
}
