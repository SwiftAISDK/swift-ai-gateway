@testable import SwiftAIGateway
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

// Translations of upstream @ai-sdk/gateway 4.0.146 language-model, provider,
// fetch-metadata and error tests that cover behavior fixed in the parity
// audit (V4 call-option body, V4 result/stream parsing, error mapping,
// o11y headers and the metadata cache).

private func coreProvider(
    _ transport: RecordingTransport,
    settings: (inout GatewayProviderSettings) -> Void = { _ in }
) throws -> GatewayProvider {
    var configuration = GatewayProviderSettings(apiKey: "test-token", baseURL: "https://api.test.com", transport: transport)
    settings(&configuration)
    return try GatewayProvider(configuration: configuration)
}

private func coreBody(_ transport: RecordingTransport, _ index: Int = 0) async throws -> JSONValue {
    let requests = await transport.requests()
    return try decodeJSONBody(try #require(requests[index].body))
}

private func coreGatewayError(_ error: any Error) -> GatewayError? {
    if let error = error as? GatewayError { return error }
    if case let .gateway(error) = error as? AIError { return error }
    return nil
}

private func coreErrorResponse(_ status: Int, _ body: String) -> AIHTTPResponse {
    AIHTTPResponse(statusCode: status, headers: ["content-type": "application/json"], body: Data(body.utf8))
}

private struct CoreThrowingTransport: AIStreamingTransport {
    let error: any Error
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse { throw error }
    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse { throw error }
}

private struct CoreNetworkError: Error, CustomStringConvertible {
    var description: String { "Network connection failed" }
}

private func coreWithEnvironment<T>(_ updates: [String: String?], operation: () async throws -> T) async rethrows -> T {
    var previous: [String: String?] = [:]
    for key in updates.keys { previous[key] = getenv(key).map { String(cString: $0) } }
    for (key, value) in updates {
        if let value { setenv(key, value, 1) } else { unsetenv(key) }
    }
    defer {
        for (key, value) in previous {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    return try await operation()
}

private func collect(_ stream: AsyncThrowingStream<LanguageStreamPart, Error>) async throws -> [LanguageStreamPart] {
    var parts: [LanguageStreamPart] = []
    for try await part in stream { parts.append(part) }
    return parts
}

@Suite struct GatewayLanguageModelParityAuditTests {
    // upstream: doGenerate "should pass headers correctly"
    @Test func passesHeadersCorrectly() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"content":{"type":"text","text":"Hello, World!"},"finish_reason":"stop"}"#))
        _ = try await coreProvider(transport).languageModel("test-model")
            .generate(.init(messages: [.user("Hello")], headers: ["Custom-Header": "test-value"]))
        let headers = normalizeHeaders(try #require(await transport.requests().first).headers)
        #expect(headers["authorization"] == "Bearer test-token")
        #expect(headers["custom-header"] == "test-value")
        #expect(headers["ai-language-model-specification-version"] == "4")
        #expect(headers["ai-language-model-id"] == "test-model")
        #expect(headers["ai-language-model-streaming"] == "false")
    }

    // upstream: "should extract text response" / "should default warnings to an empty array"
    @Test func extractsSingleObjectContentAndDefaultsWarnings() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"id":"test-id","created":1711115037,"model":"test-model","content":{"type":"text","text":"Hello, World!"},"finish_reason":"stop","usage":{"prompt_tokens":4,"completion_tokens":30}}"#))
        let result = try await coreProvider(transport).languageModel("test-model").generate(.init(messages: [.user("Hello")]))
        #expect(result.text == "Hello, World!")
        #expect(result.warnings.isEmpty)
        #expect(result.usage?.inputTokens == 4)
        #expect(result.usage?.outputTokens == 30)
    }

    // upstream: "should forward warnings returned by the gateway"
    @Test func forwardsWarnings() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"content":[{"type":"text","text":"Hello"}],"warnings":[{"type":"compatibility","feature":"maxOutputTokens","details":"lowered to 38000"},{"type":"other","message":"from provider"}]}"#))
        let result = try await coreProvider(transport).languageModel("test-model").generate(.init(messages: [.user("Hello")]))
        #expect(result.warnings.count == 2)
        #expect(result.warnings.first?.type == "compatibility")
        #expect(result.warnings.last?.message == "from provider")
    }

    // The Gateway returns LanguageModelV4GenerateResult: nested usage, a
    // `{unified, raw}` finish reason and `response` metadata. An empty
    // content array is a valid result, not a parsing failure.
    @Test func parsesV4GenerateResult() async throws {
        let transport = RecordingTransport(response: jsonResponse("""
        {"content":[{"type":"reasoning","text":"think"},{"type":"text","text":"Hi"}],"finishReason":{"unified":"stop","raw":"end_turn"},"usage":{"inputTokens":{"total":10,"noCache":7,"cacheRead":3},"outputTokens":{"total":20,"text":15,"reasoning":5}},"response":{"id":"resp_1","modelId":"anthropic/claude","timestamp":"2023-12-07T10:30:00.000Z"},"providerMetadata":{"gateway":{"cost":"0.01"}}}
        """))
        let result = try await coreProvider(transport).languageModel("test-model").generate(.init(messages: [.user("Hello")]))
        #expect(result.text == "Hi")
        #expect(result.reasoning == "think")
        #expect(result.finishReason == "stop")
        #expect(result.usage?.inputTokens == 10)
        #expect(result.usage?.outputTokens == 20)
        #expect(result.usage?.totalTokens == 30)
        #expect(result.usage?.inputTokensCacheRead == 3)
        #expect(result.usage?.outputReasoningTokens == 5)
        #expect(result.responseMetadata.id == "resp_1")
        #expect(result.responseMetadata.modelID == "anthropic/claude")
        #expect(result.responseMetadata.timestamp == ISO8601DateFormatter().date(from: "2023-12-07T10:30:00Z"))
        #expect(result.providerMetadata["gateway"]?["cost"]?.stringValue == "0.01")

        let empty = RecordingTransport(response: jsonResponse(#"{"content":[],"finishReason":{"unified":"length","raw":null}}"#))
        let emptyResult = try await coreProvider(empty).languageModel("test-model").generate(.init(messages: [.user("Hello")]))
        #expect(emptyResult.text == "")
        #expect(emptyResult.finishReason == "length")
    }

    // The request body is LanguageModelV4CallOptions without abortSignal.
    @Test func sendsV4CallOptionsBody() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"content":[{"type":"text","text":"ok"}]}"#))
        let call = AIToolCall(id: "call_1", name: "lookup", arguments: #"{"q":"x"}"#)
        let request = LanguageModelRequest(
            messages: [
                AIMessage(role: .system, content: [.text("Be brief.")]),
                AIMessage(role: .user, content: [
                    .text("Look", providerMetadata: ["anthropic": ["cacheControl": ["type": "ephemeral"]]]),
                    .text(""),
                    .imageURL("https://example.com/image.png"),
                    .imageURL("data:image/png;base64,AQID"),
                    .file(mimeType: "application/pdf", data: Data("%PDF".utf8), filename: "a.pdf")
                ]),
                AIMessage(role: .assistant, content: [.text("checking"), .toolCall(call)]),
                AIMessage(role: .tool, content: [
                    .toolResult(AIToolResult(toolCallID: "call_1", toolName: "lookup", result: ["temp": 20])),
                    .toolApprovalResponse(AIToolApprovalResponse(id: "approval_1", approved: true))
                ])
            ],
            maxOutputTokens: 100,
            responseFormat: .json(schema: ["type": "object"], name: "answer"),
            tools: [
                "lookup": ["type": "object", "description": "Look up a value.", "properties": ["q": ["type": "string"]], "strict": true]
            ],
            toolChoice: "required",
            providerOptions: ["gateway": ["order": ["openai"]]],
            abortSignal: AIAbortController().signal
        )
        _ = try await coreProvider(transport).languageModel("test-model").generate(request)
        let body = try await coreBody(transport)
        #expect(body["abortSignal"] == nil)
        #expect(body["prompt"]?[0] == ["role": "system", "content": "Be brief."])
        #expect(body["prompt"]?[1]?["content"] == [
            ["type": "text", "text": "Look", "providerOptions": ["anthropic": ["cacheControl": ["type": "ephemeral"]]]],
            ["type": "file", "mediaType": "image", "data": ["type": "url", "url": "https://example.com/image.png"]],
            ["type": "file", "mediaType": "image/png", "data": ["type": "data", "data": "AQID"]],
            ["type": "file", "mediaType": "application/pdf", "filename": "a.pdf", "data": ["type": "data", "data": .string(Data("%PDF".utf8).base64EncodedString())]]
        ])
        #expect(body["prompt"]?[2]?["content"] == [
            ["type": "text", "text": "checking"],
            ["type": "tool-call", "toolCallId": "call_1", "toolName": "lookup", "input": ["q": "x"]]
        ])
        // Only provider-executed approval responses reach the model prompt.
        #expect(body["prompt"]?[3]?["content"] == [
            ["type": "tool-result", "toolCallId": "call_1", "toolName": "lookup", "output": ["type": "json", "value": ["temp": 20]]]
        ])
        #expect(body["maxOutputTokens"] == 100)
        #expect(body["responseFormat"] == ["type": "json", "schema": ["type": "object"], "name": "answer"])
        #expect(body["tools"] == [[
            "type": "function", "name": "lookup", "description": "Look up a value.", "strict": true,
            "inputSchema": ["type": "object", "properties": ["q": ["type": "string"]]]
        ]])
        #expect(body["toolChoice"] == ["type": "required"])
        #expect(body["providerOptions"] == ["gateway": ["order": ["openai"]]])
        #expect(body["includeRawChunks"] == nil)
    }

    // upstream: "should convert API call errors to Gateway errors" (contextual auth message)
    @Test func authenticationErrorUsesContextualMessage() async throws {
        let transport = RecordingTransport(response: coreErrorResponse(401, #"{"error":{"message":"Invalid API key provided","type":"authentication_error"}}"#))
        do {
            _ = try await coreProvider(transport).languageModel("test-model").generate(.init(messages: [.user("Hello")]))
            Issue.record("Expected error")
        } catch {
            let error = try #require(coreGatewayError(error))
            #expect(error.name == "GatewayAuthenticationError")
            #expect(error.message.contains("Invalid API key"))
            #expect(error.message.contains("vercel.com/d?to="))
            #expect(error.statusCode == 401)
            #expect(error.type == .authenticationError)
            #expect(error.cause != nil)
        }
    }

    // upstream: "should handle malformed error responses" / "should use raw response body when JSON parsing fails"
    @Test func malformedErrorBodyKeepsRawStringResponse() async throws {
        let transport = RecordingTransport(response: coreErrorResponse(500, "invalid json response"))
        do {
            _ = try await coreProvider(transport).languageModel("test-model").generate(.init(messages: [.user("Hello")]))
            Issue.record("Expected error")
        } catch {
            let error = try #require(coreGatewayError(error))
            #expect(error.name == "GatewayResponseError")
            #expect(error.type == .responseError)
            #expect(error.statusCode == 500)
            #expect(error.message == "Invalid error response format: Gateway request failed")
            #expect(error.response == .string("invalid json response"))
        }
    }

    // upstream: "should include actual response body when APICallError has no data"
    @Test func invalidEnvelopeKeepsJSONResponseAndGenerationID() async throws {
        let transport = RecordingTransport(response: coreErrorResponse(404, #"{"ferror":{"message":"Model not found","type":"model_not_found"},"generationId":"gen_1"}"#))
        do {
            _ = try await coreProvider(transport).languageModel("test-model").generate(.init(messages: [.user("test")]))
            Issue.record("Expected error")
        } catch {
            let error = try #require(coreGatewayError(error))
            #expect(error.type == .responseError)
            #expect(error.response == ["ferror": ["message": "Model not found", "type": "model_not_found"], "generationId": "gen_1"])
            #expect(error.generationID == "gen_1")
        }
    }

    // upstream: "should handle various error types with proper conversion"
    @Test func mapsTypedErrorsWithCause() async throws {
        for (status, body, type, message) in [
            (400, #"{"error":{"message":"Invalid request format","type":"invalid_request_error"}}"#, GatewayErrorType.invalidRequestError, "Invalid request format"),
            (429, #"{"error":{"message":"Rate limit exceeded. Try again later.","type":"rate_limit_exceeded"}}"#, .rateLimitExceeded, "Rate limit exceeded. Try again later."),
            (500, #"{"error":{"message":"Database connection failed","type":"internal_server_error"}}"#, .internalServerError, "Database connection failed")
        ] {
            let transport = RecordingTransport(response: coreErrorResponse(status, body))
            do {
                _ = try await coreProvider(transport).languageModel("test-model").generate(.init(messages: [.user("Hello")]))
                Issue.record("Expected error")
            } catch {
                let error = try #require(coreGatewayError(error))
                #expect(error.type == type)
                #expect(error.message == message)
                #expect(error.statusCode == status)
                #expect(error.cause?.responseBody.contains(message) == true)
            }
        }
    }

    // upstream: "should handle network errors gracefully" (doGenerate and doStream)
    @Test func networkErrorsBecomeGatewayResponseErrors() async throws {
        let provider = try coreProvider(RecordingTransport(response: jsonResponse("{}"))) { $0.transport = CoreThrowingTransport(error: CoreNetworkError()) }
        let model = try provider.languageModel("test-model")
        do {
            _ = try await model.generate(.init(messages: [.user("Hello")]))
            Issue.record("Expected error")
        } catch {
            let error = try #require(coreGatewayError(error))
            #expect(error.name == "GatewayResponseError")
            #expect(error.message == "Invalid error response format: Gateway request failed: Network connection failed")
            #expect(error.statusCode == 500)
            #expect(error.isRetryable)
        }
        do {
            _ = try await collect(model.stream(.init(messages: [.user("Hello")])))
            Issue.record("Expected error")
        } catch {
            let error = try #require(coreGatewayError(error))
            #expect(error.message == "Invalid error response format: Gateway request failed: Network connection failed")
        }
    }

    // upstream: "should not double-wrap existing Gateway errors"
    @Test func doesNotDoubleWrapGatewayErrors() async throws {
        let existing = GatewayError(type: .authenticationError, message: "Already a Gateway error", statusCode: 401)
        let provider = try coreProvider(RecordingTransport(response: jsonResponse("{}"))) { $0.transport = CoreThrowingTransport(error: existing) }
        do {
            _ = try await provider.languageModel("test-model").generate(.init(messages: [.user("Hello")]))
            Issue.record("Expected error")
        } catch let error as GatewayError {
            #expect(error == existing)
        }
    }

    // upstream: "should include o11y headers in the request" + provider
    // "should pass o11y headers ... when environment variables are set" /
    // "should not include undefined o11y headers".
    @Test func sendsO11yHeadersFromVercelEnvironment() async throws {
        try await coreWithEnvironment([
            "VERCEL_DEPLOYMENT_ID": "test-deployment",
            "VERCEL_ENV": "production",
            "VERCEL_REGION": "iad1",
            "VERCEL_PROJECT_ID": "prj_test123"
        ]) {
            let transport = RecordingTransport(response: jsonResponse(#"{"content":[{"type":"text","text":"ok"}]}"#))
            _ = try await coreProvider(transport).languageModel("test-model").generate(.init(messages: [.user("Hello")]))
            let headers = normalizeHeaders(try #require(await transport.requests().first).headers)
            #expect(headers["ai-o11y-deployment-id"] == "test-deployment")
            #expect(headers["ai-o11y-environment"] == "production")
            #expect(headers["ai-o11y-region"] == "iad1")
            #expect(headers["ai-o11y-project-id"] == "prj_test123")
        }
        #expect(gatewayO11yHeaders(environment: [:]) == [:])
        #expect(gatewayO11yHeaders(environment: ["VERCEL_ENV": ""]) == [:])
    }
}

@Suite struct GatewayLanguageStreamParityAuditTests {
    // upstream: "should stream text deltas" + includeRawChunks in the body
    @Test func streamsLegacyTextDeltasAndSendsIncludeRawChunks() async throws {
        let transport = RecordingTransport(response: sseResponse("""
        data: {"type":"text-delta","textDelta":"Hello"}

        data: {"type":"text-delta","textDelta":", "}

        data: {"type":"text-delta","textDelta":"World!"}

        data: {"type":"finish","finishReason":"stop","usage":{"prompt_tokens":10,"completion_tokens":20}}

        """))
        let parts = try await collect(try coreProvider(transport).languageModel("test-model").stream(.init(messages: [.user("Hello")])))
        let deltas = parts.compactMap { part -> String? in
            if case let .textDeltaPart(_, delta, _) = part { return delta }
            return nil
        }
        #expect(deltas == ["Hello", ", ", "World!"])
        guard case let .finishMetadata(reason, usage, _) = parts.last else {
            Issue.record("Expected finish"); return
        }
        #expect(reason == "stop")
        #expect(usage?.inputTokens == 10)
        let body = try await coreBody(transport)
        #expect(body["includeRawChunks"] == false)
        #expect(normalizeHeaders(try #require(await transport.requests().first).headers)["ai-language-model-streaming"] == "true")
    }

    // upstream: "should forward server stream-start warnings exactly once" and
    // "should preserve explicit mid-stream provider error metadata"
    @Test func forwardsStreamStartOnceAndMidStreamErrors() async throws {
        let transport = RecordingTransport(response: sseResponse("""
        data: {"type":"stream-start","warnings":[{"type":"other","message":"from provider"}]}

        data: {"type":"text-delta","textDelta":"Partial output"}

        data: {"type":"error","error":{"message":"Upstream provider overloaded","type":"provider_overloaded","statusCode":503,"isRetryable":true}}

        """))
        let parts = try await collect(try coreProvider(transport).languageModel("test-model").stream(.init(messages: [.user("Hello")])))
        let starts = parts.filter { if case .streamStart = $0 { return true }; return false }
        #expect(starts == [.streamStart(warnings: [AIWarning(type: "other", message: "from provider")])])
        let errors = parts.compactMap { part -> (String, JSONValue?)? in
            if case let .error(message, rawValue) = part { return (message, rawValue) }
            return nil
        }
        #expect(errors.count == 1)
        #expect(errors.first?.0 == "Upstream provider overloaded")
        #expect(errors.first?.1 == ["message": "Upstream provider overloaded", "type": "provider_overloaded", "statusCode": 503, "isRetryable": true])
    }

    // upstream: "raw chunks filtering"
    @Test func forwardsOnlyRequestedRawChunks() async throws {
        let sse = """
        data: {"type":"stream-start","warnings":[]}

        data: {"type":"raw","rawValue":{"id":"test-chunk","object":"chat.completion.chunk","choices":[{"delta":{"content":"Hello"}}]}}

        data: {"type":"text-delta","textDelta":"Hello"}

        data: {"type":"finish","finishReason":"stop","usage":{"prompt_tokens":10,"completion_tokens":5}}

        """
        for include in [false, true] {
            let transport = RecordingTransport(response: sseResponse(sse))
            let parts = try await collect(try coreProvider(transport).languageModel("test-model").stream(.init(messages: [.user("Hello")], includeRawChunks: include)))
            let raws = parts.compactMap { part -> JSONValue? in
                if case let .raw(value) = part { return value }
                return nil
            }
            #expect(raws == (include ? [["id": "test-chunk", "object": "chat.completion.chunk", "choices": [["delta": ["content": "Hello"]]]]] : []))
        }
    }

    // upstream: "timestamp conversion"
    @Test func forwardsResponseMetadataWithParsedTimestamp() async throws {
        let transport = RecordingTransport(response: sseResponse("""
        data: {"type":"response-metadata","id":"test-id","modelId":"test-model","timestamp":"2023-12-07T10:30:00.000Z"}

        data: {"type":"response-metadata","id":"test-id-2","modelId":"test-model","timestamp":null}

        data: {"type":"finish","finishReason":"stop"}

        """))
        let parts = try await collect(try coreProvider(transport).languageModel("test-model").stream(.init(messages: [.user("Hello")])))
        let metadata = parts.compactMap { part -> AIResponseMetadata? in
            if case let .responseMetadata(value) = part, value.id != nil { return value }
            return nil
        }
        #expect(metadata.count == 2)
        #expect(metadata[0].modelID == "test-model")
        #expect(metadata[0].timestamp == ISO8601DateFormatter().date(from: "2023-12-07T10:30:00Z"))
        #expect(metadata[1].timestamp == nil)
    }

    // V4 streams send tool-input-* parts followed by one `tool-call`; the
    // call must be published once, with the V4 finish reason and usage.
    @Test func publishesV4ToolCallOnceWithV4Finish() async throws {
        let transport = RecordingTransport(response: sseResponse("""
        data: {"type":"text-start","id":"t1"}

        data: {"type":"text-delta","id":"t1","delta":"Hi"}

        data: {"type":"text-end","id":"t1"}

        data: {"type":"tool-input-start","id":"call_1","toolName":"lookup"}

        data: {"type":"tool-input-delta","id":"call_1","delta":"{}"}

        data: {"type":"tool-input-end","id":"call_1"}

        data: {"type":"tool-call","toolCallId":"call_1","toolName":"lookup","input":"{}"}

        data: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool_use"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":4}}}

        """))
        let parts = try await collect(try coreProvider(transport).languageModel("test-model").stream(.init(messages: [.user("Hello")])))
        let calls = parts.filter { if case .toolCall = $0 { return true }; return false }
        #expect(calls.count == 1)
        let lifecycle = parts.compactMap { part -> String? in
            switch part {
            case let .textStart(id, _): return "text-start:\(id)"
            case let .textEnd(id, _): return "text-end:\(id)"
            case let .toolInputEnd(id, _): return "input-end:\(id)"
            case let .toolCall(call): return "call:\(call.id)"
            default: return nil
            }
        }
        #expect(lifecycle == ["text-start:t1", "text-end:t1", "input-end:call_1", "call:call_1"])
        guard case let .finishMetadata(reason, usage, _) = parts.last else {
            Issue.record("Expected finish"); return
        }
        #expect(reason == "tool-calls")
        #expect(usage?.totalTokens == 7)
    }
}

@Suite struct GatewayProviderMetadataParityAuditTests {
    private static let catalog = #"{"models":[{"id":"model-1","name":"Model 1","description":"A model","pricing":{"input":"0.000003","output":"0.000015","input_cache_read":"0.0000003","input_cache_write":"0.00000375"},"specification":{"specificationVersion":"v4","provider":"test","modelId":"model-1"},"modelType":"language"},{"id":"model-unknown-type","name":"Unknown","specification":{"specificationVersion":"v4","provider":"test","modelId":"x"},"modelType":"some-future-type"},{"id":"model-2","name":"Model 2","pricing":{"input":"0.000001","output":"0.000002","input_cache_read":""},"specification":{"specificationVersion":"v4","provider":"test","modelId":"model-2"}}]}"#

    // upstream fetch-metadata: pricing mapping, description, modelType filtering
    @Test func mapsPricingDescriptionAndFiltersUnknownModelTypes() async throws {
        let transport = RecordingTransport(response: jsonResponse(Self.catalog))
        let models = try await coreProvider(transport).getAvailableModels()
        #expect(models.map(\.id) == ["model-1", "model-2"])
        #expect(models[0].description == "A model")
        #expect(models[0].pricing == GatewayModelPricing(input: "0.000003", output: "0.000015", cachedInputTokens: "0.0000003", cacheCreationInputTokens: "0.00000375"))
        #expect(models[1].pricing == GatewayModelPricing(input: "0.000001", output: "0.000002"))
        #expect(models[0].specificationVersion == "v4")
    }

    @Test func preservesAllKnownModelTypes() async throws {
        let types = ["embedding", "decision", "evaluation", "image", "language", "realtime", "reranking", "speech", "transcription", "video"]
        let entries = types.map { #"{"id":"model-\#($0)","name":"Model \#($0)","specification":{"specificationVersion":"v4","provider":"p","modelId":"model-\#($0)"},"modelType":"\#($0)"}"# }
        let transport = RecordingTransport(response: jsonResponse(#"{"models":[\#(entries.joined(separator: ","))]}"#))
        let models = try await coreProvider(transport).getAvailableModels()
        #expect(models.compactMap(\.modelType) == types)
    }

    // upstream provider: "metadata caching"
    @Test func cachesMetadataForTheRefreshInterval() async throws {
        let clock = CoreTestClock()
        let transport = RecordingTransport(response: jsonResponse(#"{"models":[]}"#))
        let provider = try coreProvider(transport) {
            $0.metadataCacheRefreshMillis = 10_000
            $0.currentDate = { clock.now }
        }
        _ = try await provider.getAvailableModels()
        #expect(await transport.requests().count == 1)
        _ = try await provider.getAvailableModels()
        #expect(await transport.requests().count == 1)
        clock.advance(9)
        _ = try await provider.getAvailableModels()
        #expect(await transport.requests().count == 1)
        clock.advance(2)
        _ = try await provider.getAvailableModels()
        await provider.metadataCache.waitForPendingRefresh()
        #expect(await transport.requests().count == 2)
    }

    @Test func defaultsToFiveMinuteRefreshInterval() async throws {
        let clock = CoreTestClock()
        let transport = RecordingTransport(response: jsonResponse(#"{"models":[]}"#))
        let provider = try coreProvider(transport) { $0.currentDate = { clock.now } }
        _ = try await provider.getAvailableModels()
        clock.advance(4 * 60)
        _ = try await provider.getAvailableModels()
        #expect(await transport.requests().count == 1)
        clock.advance(2 * 60)
        _ = try await provider.getAvailableModels()
        await provider.metadataCache.waitForPendingRefresh()
        #expect(await transport.requests().count == 2)
    }

    // upstream fetch-metadata/provider: metadata errors become Gateway errors
    @Test func metadataErrorsBecomeGatewayErrors() async throws {
        let transport = RecordingTransport(response: coreErrorResponse(401, #"{"error":{"message":"Invalid API key","type":"authentication_error"}}"#))
        do {
            _ = try await coreProvider(transport).getCredits()
            Issue.record("Expected error")
        } catch {
            let error = try #require(coreGatewayError(error))
            #expect(error.type == .authenticationError)
            #expect(error.message.contains("Invalid API key or token"))
        }
        let network = try coreProvider(transport) { $0.transport = CoreThrowingTransport(error: CoreNetworkError()) }
        do {
            _ = try await network.getAvailableModels()
            Issue.record("Expected error")
        } catch {
            let error = try #require(coreGatewayError(error))
            #expect(error.message == "Invalid error response format: Gateway request failed: Network connection failed")
        }
    }

    // upstream: custom headers are spread after the team header
    @Test func customTeamHeaderOverridesTeamIDOrSlug() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"content":[{"type":"text","text":"ok"}]}"#))
        let provider = try GatewayProvider(
            configuration: .init(apiKey: "k", headers: ["X-Vercel-AI-Gateway-Team": "custom-team"], transport: transport),
            teamIDOrSlug: "team_123"
        )
        _ = try await provider.languageModel("m").generate(.init(messages: [.user("Hi")]))
        let headers = try #require(await transport.requests().first).headers
        #expect(headers.filter { $0.key.lowercased() == "x-vercel-ai-gateway-team" }.map(\.value) == ["custom-team"])
    }

    // upstream gateway.tools.exaSearch
    @Test func exaSearchToolForwardsConfiguration() {
        let tool = GatewayTools.exaSearch(type: "fast", numResults: 5, category: "news", includeDomains: ["example.com"], contents: ["text": ["maxCharacters": 500]])
        #expect(tool == [
            "type": "provider",
            "id": "gateway.exa_search",
            "name": "exa_search",
            "args": ["type": "fast", "numResults": 5, "category": "news", "includeDomains": ["example.com"], "contents": ["text": ["maxCharacters": 500]]]
        ])
    }
}

private final class CoreTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_704_067_200)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}
