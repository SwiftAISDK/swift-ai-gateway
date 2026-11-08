<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-gateway 1.2.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-gateway.git", from: "1.2.0")
```

Products: `SwiftAIGateway`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# SwiftAIGateway

Swift-native port of `@ai-sdk/gateway`. Maintained in the canonical SwiftAISDK repository and exported as an independent Swift package.

```swift
import SwiftAIGateway

let provider = try GatewayProvider(configuration: .init(apiKey: "..."))
let model = try provider.languageModel("openai/gpt-5")
```

The package owns Gateway authentication, model and management routes, batch,
streaming audio and decision/evaluation adapters. Provider-neutral contracts and
socket lifecycle support come from `swift-ai-core`. The reviewed upstream
baseline is `@ai-sdk/gateway` 4.0.138.

`provider.realtimeModel("openai/gpt-realtime-2")` speaks Gateway's normalized
protocol. It supports short-lived client-secret WebSockets with team subprotocols
and trusted server WebSockets with freshly resolved headers. Use
`getResolvedServerWebSocketConfig()` with async credentials, or
`AIRealtimeSession.connectServer` from `SwiftAI` for the shared socket lifecycle.
The realtime route rejects transcription intent; streaming transcription keeps
its existing separate route. Usage stays in the original event envelope and is
available through `AIRealtimeServerEvent.usage`.

`GatewayTools.deepseekSearch` and `deepseekFetch` add Gateway-executed standalone
web tools. Their results and structured errors remain JSON, including
`retryAfter`, `statusText` and future additive fields, in unary and streamed tool
results. Generation info exposes optional `marketCost`, `surchargeCost` and
`gatewayCost`, preserving reported zero values.

Transcription returns independent `words` while retaining `segments`. The shared
`timestampGranularities` option is unsupported by the Gateway wire adapter and
produces a warning. Video results expose `uploadedVideos` for assets stored by
the provider even when no downloadable URL or base64 payload is returned.

An empty configured API key falls through to the Vercel OIDC environment token,
which is resolved for each request. A nonempty key remains selected if it is
invalid; async API key callbacks must return a nonempty key. Native construction
still reports missing credentials immediately.

`gateway.experimental_streamingImageDecoding` is a client-only upstream option.
The native adapter strips it from requests and warns when enabled: image results
still retain buffered base64 strings because the native incremental JSON/binary
response parser is not implemented. No reduced-memory or byte-result behavior
is claimed. Browser media ownership remains separate from native WebSockets.

Run `swift test --package-path Packages/swift-ai-gateway` in the canonical checkout.
Distribution manifests and repositories are generated from the package catalog.

See [provider usage and capabilities](https://github.com/SwiftAISDK/SwiftAISDK/blob/main/docs-site/scripts/provider-guides/gateway.md) for authentication, options and supported surfaces.
