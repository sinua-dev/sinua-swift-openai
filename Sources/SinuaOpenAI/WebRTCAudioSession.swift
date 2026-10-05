import LiveKitWebRTC
import SinuaVoice

/// The app's audio session through WebRTC's own wrapper (design note 30, V1/V2). The
/// policy goes into WebRTC's configuration too, so its audio engine doesn't put its own
/// default back when it starts. Main thread. Not exercised by any test (it is the real
/// session; the simulator's is the Mac's): `AudioSessionClaims` and the policy are.
enum WebRTCAudioSession {
    static func activate(_ p: AudioSessionPolicy) throws {
        let c = LKRTCAudioSessionConfiguration.webRTC()
        c.category = p.category.rawValue
        c.mode = p.mode.rawValue
        c.categoryOptions = p.options
        LKRTCAudioSessionConfiguration.setWebRTC(c)
        let s = LKRTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        defer { s.unlockForConfiguration() }
        try s.setConfiguration(c, active: true)
    }

    /// WebRTC passes `notifyOthersOnDeactivation`, so other apps' audio resumes.
    static func deactivate() {
        let s = LKRTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        defer { s.unlockForConfiguration() }
        do {
            try s.setActive(false)
        } catch {
            NSLog("Sinua: couldn't deactivate the audio session: \(error.localizedDescription)")
        }
    }

    /// Claims the session for a source (activating it when no other Sinua source holds
    /// it); false for `.unmanaged`.
    static func claim(_ mode: VoiceAudioSession) throws -> Bool {
        guard let policy = mode.policy else { return false }
        try AudioSessionClaims.shared.claim { try activate(policy) }
        return true
    }

    static func release() {
        AudioSessionClaims.shared.release { deactivate() }
    }
}
