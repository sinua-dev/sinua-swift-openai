# SinuaOpenAI

A `VoiceSource` for the OpenAI Realtime API over WebRTC, driving a Sinua visual
from the model's own voice. iOS 15+.

It is a separate SwiftPM package because it pulls a WebRTC binary, and an app
that doesn't talk to OpenAI shouldn't carry one. [`packages/ios`](../ios) has no
dependency on this one.

```swift
import Sinua
import SinuaOpenAI

// Production: your backend answers { credential: "ek_…", expiresAt } -- a fresh one per connect.
let voice = OpenAIRealtimeVoiceSource(credentialUrl: URL(string: "https://your.app/api/voice/openai")!)
SinuaView(pattern: "breathing", size: 64, voice: voice)
```

## Credentials

Realtime uses WebRTC from clients and short-lived **ephemeral keys** (`ek_…`),
minted server-side by `POST /v1/realtime/client_secrets` with your secret key --
`mintOpenAIRealtimeCredential` in `@sinua/voice/server` does it, and
`npx @sinua/voice dev-proxy` serves one locally. The source takes the shared
contract (`CredentialSource`): `credentialUrl:` (your endpoint, answering
`{ credential, expiresAt? }`), `credential: .provider { … }`, or one pasted `ek_`.
A URL or provider is asked on every connect *and every reconnect*, which is what
a single-use key needs. The session's model, voice and instructions are fixed
where the `ek_` is minted.

A raw, long-lived API key is always **refused** before the mic prompt; there is
no opt-in.

## Why LiveKit's WebRTC build

The dependency is `livekit/webrtc-xcframework`, not a community Google build:
its symbols are prefixed (`LKRTC…`), so it cannot clash with another WebRTC in
the same app, it tracks current milestones, and an app using both this and
`SinuaLiveKit` links **one** WebRTC binary rather than two.

## Adding it

```swift
.package(path: "../sinua/packages/ios-openai")   // once published: .package(url: "https://github.com/sinua-dev/sinua-swift-openai", from: "0.1.0-beta.8")
```

It depends on `packages/ios` by path, so both must be present.

## Building

```sh
xcodebuild build -scheme SinuaOpenAI -destination 'platform=iOS Simulator,name=iPhone 17e'
```

## What is not verified — read this before trusting it

Compile-only. **The peer connection has never run**: not the SDP exchange, not
the data channel, not the audio tap, not the reconnect path, not echo
cancellation. Running it would open real audio on the build machine, and the
simulator has no silent audio device, so it is deliberately excluded from the
test suites.

What *is* tested, in `SinuaVoiceTests` over in [`packages/ios`](../ios): the
event-to-lifecycle mapping, the reconnect policy and its backoff, the transcript
replay, the fatal-error classification, and the HTTP signalling through a
`URLProtocol` stub. Those are the parts that can be exercised without a live
call. The rest is unproven.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](../../NOTICE).
