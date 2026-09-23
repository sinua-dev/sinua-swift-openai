import AVFoundation
import Foundation
import LiveKitWebRTC
import SinuaVoice

/// `VoiceSource` for OpenAI's Realtime API over WebRTC -- the native mirror of the
/// Web `OpenAIRealtimeVoiceSource` (packages/voice/src/OpenAIRealtimeVoiceSource.ts). OpenAI
/// recommends WebRTC for client devices (WebSocket is "from a trusted server").
///
/// WebRTC is LiveKit's prefixed build (`livekit/webrtc-xcframework`): maintained on
/// current Chromium milestones, `LK`-prefixed so it can't clash with another copy,
/// and the same binary an app using LiveKit (or ElevenLabs' official SDK) already
/// carries. WebRTC's own audio device does capture (with echo cancellation) and
/// playback; the model's remote track is tapped through `addRenderer` into the same
/// spectrum path as every other source (`PcmTap`).
///
/// Event and reconnect rules live in `OpenAIRealtimeSession` / `RealtimeReconnect` /
/// `OpenAIRealtimeSignaling` (SinuaVoice, unit-tested); this class wires them to a
/// peer connection. Callbacks arrive on the main thread.
///
/// Order: the credential first (a backend-minted `ek_`, or -- dev only -- a key
/// that mints one), then the mic permission, then the call. A bad credential
/// fails before any prompt.
///
/// Reconnect: a dropped call is replaced by a new session (Realtime has no
/// resumption), up to 3 attempts with LiveKit's backoff, each with a fresh
/// credential from `credentialProvider`, then the finalized transcript is
/// replayed. Fatal errors (401/403, `invalid_api_key`, …) give up at once.
///
/// **Not exercised at runtime by any test**: a peer connection opens the real
/// microphone and speakers (on the simulator: the Mac's), and this WebRTC build
/// has no silent audio device. Compile-verified only; not verified live.
public final class OpenAIRealtimeVoiceSource: NSObject, VoiceSource, @unchecked Sendable {
    public static let updateHz = 30.0
    static let connectTimeout: TimeInterval = 20

    private let credentialProvider: () async throws -> String
    private let callsURL: URL
    private let urlSession: URLSession
    private let requestPermission: () async -> Bool
    private let session = OpenAIRealtimeSession()
    private let tap = PcmTap()
    private lazy var renderer = Renderer(sink: tap.sink)

    // Main-thread state.
    private var factory: LKRTCPeerConnectionFactory?
    private var pc: LKRTCPeerConnection?
    private var channel: LKRTCDataChannel?
    private var remoteTrack: LKRTCAudioTrack?
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var wantConnected = false
    private var reconnecting = false
    private var timer: DispatchSourceTimer?
    private var metricsCb: ((VoiceMetrics) -> Void)?

    /// Production shape: `credentialProvider` returns a fresh `ek_` from your backend
    /// (`POST /v1/realtime/client_secrets` there) -- called again on every reconnect.
    public init(
        credentialProvider: @escaping () async throws -> String,
        callsURL: URL = OpenAIRealtimeSignaling.callsURL,
        urlSession: URLSession = .shared,
        requestPermission: @escaping () async -> Bool = AVPcmAudioDevice.requestPermission
    ) {
        self.credentialProvider = credentialProvider
        self.callsURL = callsURL
        self.urlSession = urlSession
        self.requestPermission = requestPermission
    }

    /// `ek_…`: used once (single-session; a drop without a provider ends in `idle`).
    /// Anything else is a raw API key that mints an `ek_` on the device -- **DEV ONLY**,
    /// and refused unless `allowInsecureApiKey` is set (`InsecureCredential`).
    /// This is the only path on iOS that accepts a raw key at all: a custom
    /// `credentialProvider` is handed straight to the call, never minted from.
    public convenience init(
        credential: String,
        model: String = OpenAIRealtimeSignaling.defaultModel,
        voice: String = OpenAIRealtimeSignaling.defaultVoice,
        instructions: String? = nil,
        allowInsecureApiKey: Bool = false
    ) {
        let c = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        var used = false
        self.init(credentialProvider: {
            guard !c.isEmpty else { throw OpenAIRealtimeError.missingCredential }
            if c.hasPrefix("ek_") {
                if used { throw OpenAIRealtimeError.credentialSpent }
                used = true
                return c
            }
            // Runs inside the provider, i.e. at connect time and on every
            // reconnect -- before the permission prompt and before the mic.
            try InsecureCredential.check(
                vendor: "OpenAIRealtimeVoiceSource",
                isEphemeral: false,
                allowInsecureApiKey: allowInsecureApiKey,
                ephemeralShape: InsecureCredential.openAIShape,
                mintHint: InsecureCredential.openAIMintHint)
            let req = OpenAIRealtimeSignaling.clientSecretRequest(
                apiKey: c, model: model, voice: voice, instructions: instructions)
            let (status, body) = try await OpenAIRealtimeSignaling.send(req)
            return try OpenAIRealtimeSignaling.clientSecret(status: status, body: body)
        })
    }

    public func onMetrics(_ cb: @escaping (VoiceMetrics) -> Void) { metricsCb = cb }
    public func onStateChange(_ cb: @escaping (AgentState) -> Void) { session.onState = cb }
    public func onInterrupt(_ cb: @escaping () -> Void) { session.onInterrupt = cb }

    public func connect() async throws {
        await MainActor.run {
            wantConnected = true
            session.connecting()
        }
        do {
            let ek = try await credentialProvider()  // auth first: no prompt for a bad credential
            guard await requestPermission() else { throw VoiceSourceError.permissionDenied }
            try await call(ek)
            await MainActor.run {
                session.connected()
                startTimer()
            }
        } catch {
            await MainActor.run { disconnect() }
            throw error
        }
    }

    public func disconnect() {
        if Thread.isMainThread { teardown() } else { DispatchQueue.main.sync { teardown() } }
    }

    // MARK: - The call (one Realtime session)

    private func call(_ ek: String) async throws {
        let (pc, constraints) = try await MainActor.run { () throws -> (LKRTCPeerConnection, LKRTCMediaConstraints) in
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
            pc.add(mic, streamIds: ["mic"])
            let dc = pc.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration())
            dc?.delegate = self
            channel = dc
            return (pc, constraints)
        }
        // Posted right after setLocalDescription, as OpenAI's own browser samples do (no gathering wait).
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        let (status, body) = try await OpenAIRealtimeSignaling.send(
            OpenAIRealtimeSignaling.callsRequest(sdpOffer: offer.sdp, ephemeralKey: ek, url: callsURL),
            session: urlSession)
        let answer = try OpenAIRealtimeSignaling.answer(status: status, body: body)
        guard await MainActor.run(body: { self.pc === pc }) else { throw CancellationError() }
        try await pc.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer))
        // Live once the event channel opens (the Web adapter's rule).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async { [self] in
                if channel?.readyState == .open { return cont.resume() }
                openWaiter = cont
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
                    guard let self, let w = self.openWaiter else { return }
                    self.openWaiter = nil
                    w.resume(throwing: OpenAIRealtimeError.timeout)
                }
            }
        }
        // A reconnect: give the new session the conversation so far (empty on the first call).
        await MainActor.run {
            for event in session.transcript.replayEvents() { send(event) }
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
        pc?.close()
        pc = nil
    }

    private func dropped(_ reason: String) {
        guard wantConnected, !reconnecting, timer != nil else { return }
        Task { await reconnect(reason) }
    }

    private func reconnect(_ reason: String) async {
        let fatal = await MainActor.run { () -> String? in
            reconnecting = true
            closeCall()
            session.connecting()
            metricsCb?(.silent)  // go quiet instead of freezing
            return session.fatalCode
        }
        if fatal == nil {
            attempts: for attempt in 1...RealtimeReconnect.defaultAttempts {
                guard await MainActor.run(body: { wantConnected }) else { break }
                try? await Task.sleep(nanoseconds: UInt64(RealtimeReconnect.delayMs(attempt: attempt)) * 1_000_000)
                do {
                    try await call(try await credentialProvider())
                    await MainActor.run {
                        reconnecting = false
                        session.connected()
                    }
                    return
                } catch let e as OpenAIRealtimeSignaling.SignalingError {
                    if case .fatal = e { break attempts }
                } catch let e as OpenAIRealtimeError where e == .credentialSpent || e == .missingCredential {
                    break attempts
                } catch {
                    NSLog(
                        "OpenAI Realtime reconnect %d after %@ failed: %@", attempt, reason, String(describing: error))
                }
                await MainActor.run { closeCall() }
            }
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
        guard remoteTrack != nil else { return }
        let m = tap.read()
        metricsCb?(m)
        session.tick(level: m.level)
    }

    private func teardown() {
        wantConnected = false
        timer?.cancel()
        timer = nil
        openWaiter?.resume(throwing: CancellationError())
        openWaiter = nil
        closeCall()
        factory = nil
        session.stopped()
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

extension OpenAIRealtimeVoiceSource: LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
    public func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    public func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
    public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}
    public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
    public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
    public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}

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
            guard dc === self.channel else { return }
            if state == .open, let w = self.openWaiter {
                self.openWaiter = nil
                w.resume()
            } else if state == .closed {
                if let w = self.openWaiter {
                    self.openWaiter = nil
                    w.resume(throwing: OpenAIRealtimeError.channelClosed)
                } else {
                    self.dropped("data channel closed")
                }
            }
        }
    }

    public func dataChannel(_ dc: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        let text = String(decoding: buffer.data, as: UTF8.self)
        DispatchQueue.main.async { if dc === self.channel { self.session.handle(text) } }
    }
}

public enum OpenAIRealtimeError: Error, Equatable {
    case missingCredential
    /// A pasted `ek_` is single-session; reconnecting needs a `credentialProvider`.
    case credentialSpent
    case peerConnection
    case channelClosed
    case timeout
}
