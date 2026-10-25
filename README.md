<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-gateway 1.0.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-gateway.git", from: "1.0.0")
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
socket lifecycle support come from `swift-ai-core`. Existing upstream baselines,
capabilities and documented gaps remain unchanged.

Run `swift test --package-path Packages/swift-ai-gateway` in the canonical checkout.
Distribution manifests and repositories are generated from the package catalog.

See [provider usage and capabilities](https://github.com/SwiftAISDK/SwiftAISDK/blob/main/docs-site/scripts/provider-guides/gateway.md) for authentication, options and supported surfaces.
