import SwiftAIProvider
import Testing
@testable import SwiftAIGateway

// Translated from @ai-sdk/gateway 4.0.152's create-gateway-error, gateway-error-types
// and gateway-fetch-metadata tests.
@Suite struct GatewayAccessPolicyAndCatalogUpstreamTests {
    @Test func preservesGenerationAndEveryErrorDetail() throws {
        let error = try policyError(
            ["policyIds": ["ap_1", "ap_2"], "removedModels": ["openai/gpt-5"], "removedProviders": ["openai"]],
            generationID: "gen_123"
        )
        #expect(error.name == "GatewayAccessPolicyDeniedError")
        #expect(error.type == .forbidden)
        #expect(error.upstreamType == "access_policy_denied")
        #expect(error.isAccessPolicyDenied)
        #expect(error.statusCode == 403)
        #expect(error.isRetryable == false)
        #expect(error.description == "\(policyErrorMessage) [gen_123]")
        #expect(error.generationID == "gen_123")
        #expect(error.policyIDs == ["ap_1", "ap_2"])
        #expect(error.removedModels == ["openai/gpt-5"])
        #expect(error.removedProviders == ["openai"])
    }

    @Test func ignoresExtraKeysAndKeepsEmptyLists() throws {
        let error = try policyError([
            "name": "AccessPolicyDeniedError", "type": "access_policy_denied", "statusCode": 403,
            "message": .string(policyErrorMessage), "policyIds": ["ap_1"], "removedModels": [], "removedProviders": ["openai"]
        ])
        #expect(error.isAccessPolicyDenied)
        #expect(error.policyIDs == ["ap_1"])
        #expect(error.removedModels == [])
        #expect(error.removedProviders == ["openai"])
    }

    @Test func keepsPartialDetails() throws {
        let error = try policyError(["policyIds": ["ap_1"]])
        #expect(error.isAccessPolicyDenied)
        #expect(error.policyIDs == ["ap_1"])
        #expect(error.removedModels == nil)
        #expect(error.removedProviders == nil)
    }

    @Test(arguments: [nil as JSONValue?, "model", .null, ["policyIds": [1, 2]], ["policyIds": ["ap_1"], "removedProviders": [1]]])
    func ignoresMissingAndMalformedParameterData(parameter: JSONValue?) throws {
        let error = try policyError(parameter)
        #expect(error.isAccessPolicyDenied)
        #expect(error.statusCode == 403)
        #expect(error.message == policyErrorMessage)
        #expect(error.policyIDs == nil)
        #expect(error.removedModels == nil)
        #expect(error.removedProviders == nil)
    }

    @Test func exposesDenialDefaultsAndDistinguishesOrdinaryForbiddenErrors() {
        let denied = GatewayError.accessPolicyDenied()
        let forbidden = GatewayError(type: .forbidden, message: "Forbidden", statusCode: 403)
        #expect(denied.name == "GatewayAccessPolicyDeniedError")
        #expect(denied.upstreamType == "access_policy_denied")
        #expect(denied.message == "Access policy denied")
        #expect(denied.statusCode == 403)
        #expect(denied.isRetryable == false)
        #expect(denied.policyIDs == nil)
        #expect(denied.removedModels == nil)
        #expect(denied.removedProviders == nil)
        #expect(denied.isAccessPolicyDenied)
        #expect(forbidden.name == "GatewayForbiddenError")
        #expect(!forbidden.isAccessPolicyDenied)
    }

    @Test func malformedPolicyEnvelopeRetainsTheResponseErrorClassification() {
        let error = gatewayErrorFromHTTPStatus(statusCode: 403, body: #"{"error":{"type":"access_policy_denied"}}"#, headers: [:])
        #expect(error.type == .responseError)
        #expect(error.upstreamType == "access_policy_denied")
        #expect(error.name == "GatewayResponseError")
        #expect(!error.isAccessPolicyDenied)
    }

    @Test func preservesAllCatalogModelTypesIncludingExtraction() async throws {
        let knownTypes = ["embedding", "decision", "evaluation", "extraction", "image", "language", "realtime", "reranking", "speech", "transcription", "video"]
        let models: [JSONValue] = knownTypes.map { type in
            ["id": .string("model-\(type)"), "name": .string("Model \(type)"), "specification": [
                "specificationVersion": "v4", "provider": "test-provider", "modelId": .string("model-\(type)")
            ], "modelType": .string(type)]
        }
        let transport = RecordingTransport(response: jsonResponse(try decisionJSONText(["models": .array(models)])))
        let provider = try GatewayProvider(configuration: .init(apiKey: "test-token", baseURL: "https://api.example.com", transport: transport))
        let result = try await provider.getAvailableModels()
        #expect(result.count == knownTypes.count)
        #expect(result.map(\.modelType) == knownTypes.map(Optional.some))
    }
}

private let policyErrorMessage = "Access policy denied: model openai/gpt-5 is not allowed by the access policies that apply to this request (policies: ap_1)."

private func policyError(_ parameter: JSONValue?, generationID: String? = nil) throws -> GatewayError {
    let payload = JSONValue.object([
        "error": .object(["type": "access_policy_denied", "message": .string(policyErrorMessage), "param": parameter]),
        "generationId": generationID.map(JSONValue.string)
    ])
    return gatewayErrorFromHTTPStatus(statusCode: 403, body: try decisionJSONText(payload), headers: [:])
}
