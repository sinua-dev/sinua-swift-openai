import LiveKitWebRTC
import SinuaVoice

/// WARP's libwebrtc field trials (`OpenAIRealtimeSignaling.warpFieldTrials`), set once per
/// process before a peer connection factory exists. Unknown trial names are ignored by
/// libwebrtc, so a build without one of them just connects the standard way.
enum WarpFieldTrials {
    private static var done = false

    /// Main thread, before the first `LKRTCPeerConnectionFactory()` of this source.
    static func enable() {
        guard !done else { return }
        done = true
        LKRTCPeerConnectionFactory.configureFieldTrials(OpenAIRealtimeSignaling.warpFieldTrials)
    }
}
