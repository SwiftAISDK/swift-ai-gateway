@testable import SwiftAIGateway
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func gatewayUpstreamPreservesStructuredErrorInAPICallCause() async throws {
    let responseBody = """
    {
      "error": {
        "message": "Database connection failed",
        "type": "internal_server_error",
        "metadata": {
          "database": {"code":"CONNECTION_REFUSED","retryable":true}
        }
      }
    }
    """
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 500,
        headers: ["content-type": "application/json", "x-request-id": "gateway-request-1"],
        body: Data(responseBody.utf8)
    ))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.languageModel("google/gemini-3.7-flash")

    do {
        _ = try await model.generate(LanguageModelRequest(messages: [.user("Hi")]))
        Issue.record("Expected a Gateway internal-server error.")
    } catch let error as AIError {
        guard case let .gateway(gatewayError) = error else {
            Issue.record("Expected AIError.gateway, got \(error).")
            return
        }
        let cause = try #require(gatewayError.cause)
        #expect(gatewayError.type == .internalServerError)
        #expect(gatewayError.message == "Database connection failed")
        #expect(cause.statusCode == 500)
        #expect(cause.responseHeaders["x-request-id"] == "gateway-request-1")
        #expect(cause.description.contains("Database connection failed"))
        #expect(cause.responseBody.contains(#""code":"CONNECTION_REFUSED""#))
    }
}

@Test func gatewayUpstreamSerializesMalformedStructuredErrorsInCause() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 404,
        headers: ["content-type": "application/json"],
        body: Data(#"{"ferror":{"message":"Model not found","type":"model_not_found"}}"#.utf8)
    ))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.languageModel("missing-model")

    do {
        _ = try await model.generate(LanguageModelRequest(messages: [.user("Hi")]))
        Issue.record("Expected a Gateway response error.")
    } catch let error as AIError {
        guard case let .gateway(gatewayError) = error else {
            Issue.record("Expected AIError.gateway, got \(error).")
            return
        }
        #expect(gatewayError.type == .responseError)
        #expect(gatewayError.response?["ferror"]?["message"]?.stringValue == "Model not found")
        #expect(gatewayError.cause?.responseBody == #"{"ferror":{"message":"Model not found","type":"model_not_found"}}"#)
    }
}

@Test func gatewayUpstreamSerializesNestedLargeNumbersInCauseWithoutOverflow() {
    let error = gatewayErrorFromHTTPStatus(
        statusCode: 500,
        body: #"{"error":{"message":"Large metadata","type":"internal_server_error","details":{"magnitude":1e100}}}"#,
        headers: [:]
    )

    #expect(error.cause?.responseBody == #"{"error":{"details":{"magnitude":1e+100},"message":"Large metadata","type":"internal_server_error"}}"#)
}

@Test func gatewayUpstreamNewModelIDsRemainAvailableThroughStringModelSurface() throws {
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(
        apiKey: "gateway-key",
        transport: RecordingTransport(response: jsonResponse("{}"))
    ))

    #expect(try provider.languageModel("anthropic/claude-opus-5-fast").modelID == "anthropic/claude-opus-5-fast")
    #expect(try provider.languageModel("deepseek/deepseek-v4-pro-0813").modelID == "deepseek/deepseek-v4-pro-0813")
    #expect(try provider.languageModel("google/gemini-3.7-flash").modelID == "google/gemini-3.7-flash")
    #expect(try provider.languageModel("meta/muse-glimmer-30b").modelID == "meta/muse-glimmer-30b")
    #expect(try provider.languageModel("sakana/namazu").modelID == "sakana/namazu")
    #expect(try provider.languageModel("xai/grok-4.6").modelID == "xai/grok-4.6")
    #expect(try provider.imageModel("xai/grok-imagine-image-2.0").modelID == "xai/grok-imagine-image-2.0")
}
