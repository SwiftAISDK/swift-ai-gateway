import Foundation
import Testing
@testable import SwiftAIGateway
import SwiftAIProvider
import SwiftAITransport

@Suite("Weekly20261114 Gateway routing and tool config")
struct Weekly20261114RoutingTests {
    @Test func headquartersAndTakoDeveloperControlsRemainExact() async throws {
        let options = GatewayProviderOptions(headquarters: ["!US"], additionalOptions: ["models": ["backup"]]).providerOptions
        #expect(options["gateway"]?["headquarters"] == ["!US"])
        let config = GatewayTakoSearchConfig(variableCost: false, maxVariableCostUSD: .null, extraBody: ["output_settings": ["flat_results": ["max_results": 3]]])
        let tool = GatewayTools.takoSearch(config)
        #expect(tool["args"]?["variableCost"] == false)
        #expect(tool["args"]?["maxVariableCostUsd"] == .null)
        #expect(tool["args"]?["extraBody"]?["output_settings"]?["flat_results"]?["max_results"] == 3)
        let transport = RecordingTransport(response: jsonResponse(#"{"content":[{"type":"text","text":"ok"}],"finishReason":{"unified":"stop"}}"#))
        let provider = try GatewayProvider(configuration: .init(apiKey: "key", transport: transport))
        _ = try await provider.languageModel("m").generate(.init(messages: [.user("Hi")], tools: ["tako": tool], providerOptions: options))
        let body = try decodeJSONBody(#require(await transport.requests().first?.body))
        #expect(body["providerOptions"]?["gateway"]?["headquarters"] == ["!US"])
        #expect(body["tools"]?[0]?["args"]?["variableCost"] == false)
    }
}
