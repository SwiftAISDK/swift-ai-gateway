import Foundation
import Testing
@testable import SwiftAIGateway
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport

@Suite struct Weekly20261108GatewayTests {
    @Test func generationCostFieldsPreserveZeroAndOmitNull() async throws {
        let transport = RecordingTransport(responses: [jsonResponse(#"{"data":{"id":"gen","market_cost":0,"surcharge_cost":0.02,"gateway_cost":0.03}}"#), jsonResponse(#"{"data":{"market_cost":null,"surcharge_cost":null}}"#)])
        let provider = try GatewayProvider(configuration: .init(apiKey: "key", transport: transport))
        let value = try await provider.getGenerationInfo(id: "gen")
        #expect(value.marketCost == 0 && value.surchargeCost == 0.02 && value.gatewayCost == 0.03)
        let absent = try await provider.getGenerationInfo(id: "absent")
        #expect(absent.marketCost == nil && absent.surchargeCost == nil && absent.gatewayCost == nil)
    }

    @Test func emptyAPIKeyFallsThroughToFreshOIDCAndInvalidKeyRemainsSelected() async throws {
        let previous = ProcessInfo.processInfo.environment["VERCEL_OIDC_TOKEN"]
        defer { if let previous { setenv("VERCEL_OIDC_TOKEN", previous, 1) } else { unsetenv("VERCEL_OIDC_TOKEN") } }
        setenv("VERCEL_OIDC_TOKEN", "oidc-first", 1)
        let transport = RecordingTransport(response: jsonResponse(#"{"data":{}}"#))
        let provider = try GatewayProvider(configuration: .init(apiKey: "", transport: transport))
        setenv("VERCEL_OIDC_TOKEN", "oidc-second", 1)
        _ = try await provider.getGenerationInfo(id: "gen")
        #expect(await transport.requests().first?.headers["authorization"] == "Bearer oidc-second")
        let explicit = try GatewayProvider(configuration: .init(apiKey: "invalid-key", transport: transport))
        _ = try await explicit.getGenerationInfo(id: "gen")
        #expect(await transport.requests().last?.headers["authorization"] == "Bearer invalid-key")
    }

    @Test func imageClientOnlyOptionsAreRemovedAndZeroSeedRemains() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"images":["AQI="]}"#))
        let model = try GatewayProvider(configuration: .init(apiKey: "key", transport: transport)).imageModel("test/image")
        let result = try await model.generateImage(.init(prompt: "paint", seed: 0, providerOptions: ["gateway": ["experimental_streamingImageDecoding": true, "order": ["test"]], "test": ["format": "png"]]))
        let body = try decodeJSONBody(#require(await transport.requests().first?.body))
        #expect(body["seed"] == 0)
        #expect(body["providerOptions"] == ["gateway": ["order": ["test"]], "test": ["format": "png"]])
        #expect(result.base64Images == ["AQI="])
        #expect(result.warnings.contains { $0.feature == "gateway.experimental_streamingImageDecoding" })
    }

    @Test func transcriptionReturnsIndependentWordsAndWarnsForSharedTimings() async throws {
        let transport = RecordingTransport(responses: [jsonResponse(#"{"text":"hello","segments":[{"text":"hello","startSecond":0,"endSecond":1}],"words":[{"text":"hello","startSecond":0.1,"endSecond":0.5}]}"#), jsonResponse(#"{"text":"empty","words":[]}"#), jsonResponse(#"{"text":"omitted","words":null}"#)])
        let model = try GatewayProvider(configuration: .init(apiKey: "key", transport: transport)).transcriptionModel("test/transcribe")
        let result = try await model.transcribe(.init(audio: Data([1]), timestampGranularities: [.word]))
        #expect(result.words == [.init(text: "hello", startSecond: 0.1, endSecond: 0.5)])
        #expect(result.segments == [.init(text: "hello", startSecond: 0, endSecond: 1)])
        #expect(result.warnings.contains { $0.feature == "timestampGranularities" })
        let body = try decodeJSONBody(#require(await transport.requests().first?.body))
        #expect(body["timestampGranularities"] == nil)
        #expect(try await model.transcribe(.init(audio: Data())).words == [])
        #expect(try await model.transcribe(.init(audio: Data())).words == nil)
    }

    @Test func videoUploadsSurviveGenerateAndCompletedPolling() async throws {
        let videos = #"[{"type":"uploaded","mediaType":"video/mp4"},{"type":"url","url":"https://example.com/video.webm","mediaType":"video/webm"}]"#
        let transport = RecordingTransport(responses: [jsonResponse("{\"videos\":" + videos + "}"), jsonResponse("{\"status\":\"completed\",\"videos\":" + videos + "}")])
        let model = try GatewayProvider(configuration: .init(apiKey: "key", transport: transport)).videoModel("test/video")
        let result = try await model.generateVideo(.init(prompt: "hello", seed: 0))
        #expect(result.uploadedVideos == [.init(mediaType: "video/mp4")])
        #expect(result.urls == ["https://example.com/video.webm"])
        let asyncModel = try #require(model as? any AsyncVideoModel)
        let status = try await asyncModel.videoGenerationStatus(.init(operation: ["gatewayJobId": "job"]))
        guard case let .completed(completed) = status else { Issue.record("Expected completed video"); return }
        #expect(completed.uploadedVideos == result.uploadedVideos)
        #expect(try decodeJSONBody(#require(await transport.requests().first?.body))["seed"] == 0)
    }

    @Test func deepseekToolsUseProviderIDsAndPassPinnedConfiguration() {
        let search = GatewayTools.deepseekSearch(query: "Swift", count: 0, needContent: false, oriQuestion: "Question", localization: "127.0.0.1")
        #expect(search["id"] == "gateway.deepseek_search")
        #expect(search["args"] == ["query": "Swift", "count": 0, "needContent": false, "oriQuestion": "Question", "localization": "127.0.0.1"])
        #expect(GatewayTools.deepseekFetch(url: "https://example.com")["args"] == ["url": "https://example.com"])
        #expect(GatewayTools.deepseekFetch()["args"] == [:])
    }

    @Test func providerExecutedToolErrorsKeepAdditiveFieldsInUnaryAndStreams() async throws {
        let error: JSONValue = ["error": "gateway_rate_limit", "message": "wait", "statusCode": 429, "retryAfter": "60", "statusText": "Too Many Requests", "future": ["value": true]]
        let part: JSONValue = ["type": "tool-result", "toolCallId": "call", "toolName": "deepseek_search", "result": error, "providerExecuted": true]
        let transport = RecordingTransport(responses: [jsonResponse(String(decoding: try encodeJSONBody(["content": .array([part]), "finishReason": "stop"]), as: UTF8.self)), sseResponse("data: " + String(decoding: try encodeJSONBody(part), as: UTF8.self) + "\n\ndata: {\"type\":\"finish\",\"finishReason\":\"stop\"}")])
        let model = try GatewayProvider(configuration: .init(apiKey: "key", transport: transport)).languageModel("test/model")
        let result = try await model.generate(.init(messages: [.user("search")], tools: ["deepseek_search": GatewayTools.deepseekSearch()]))
        #expect(result.toolResults.first?.result == error)
        var results: [AIToolResult] = []
        for try await event in model.stream(.init(messages: [.user("search")])) { if case let .toolResult(value) = event { results.append(value) } }
        #expect(results.first?.result == error)
    }

    @Test func normalizedRealtimeAuthAndServerHeadersResolveFreshKeys() async throws {
        let keys = GatewayWeeklyKeys()
        let transport = RecordingTransport(response: jsonResponse(#"{"token":"vcst_123","expiresAt":12345}"#))
        let provider = try GatewayProvider(configuration: .init(apiKeyProvider: { await keys.next() }, baseURL: "https://example.com/v4/ai", transport: transport), teamIDOrSlug: "東京-team")
        let model = provider.realtimeModel("openai/gpt-realtime-2")
        let server = try await model.getResolvedServerWebSocketConfig()
        #expect(server.url == "wss://example.com/v4/ai/realtime-model?ai-model-id=openai%2Fgpt-realtime-2")
        #expect(server.headers["authorization"] == "Bearer key-1")
        #expect(server.headers["x-vercel-ai-gateway-team"] == "東京-team")
        let token = try await model.doCreateClientSecret(.init(expiresAfterSeconds: 0, sessionConfig: .init(instructions: "applied later")))
        #expect(token.token == "vcst_123" && token.expiresAt == 12345)
        let request = try #require(await transport.requests().first)
        #expect(request.url.absoluteString == "https://example.com/v1/realtime/client-secrets")
        #expect(request.headers["authorization"] == "Bearer key-2")
        #expect(try decodeJSONBody(#require(request.body)) == ["model": "openai/gpt-realtime-2", "expiresIn": 0])
        let client = model.getWebSocketConfig(token: token.token, url: token.url)
        #expect(client.protocols.prefix(2) == ["ai-gateway-realtime.v1", "ai-gateway-auth.vcst_123"])
        #expect(client.protocols.last?.hasPrefix("ai-gateway-team.") == true)
        await #expect(throws: AIError.self) { _ = try await model.getResolvedServerWebSocketConfig(intent: .transcription) }
        await #expect(throws: AIError.self) { _ = try await model.serializeClientEvent(.inputAudioCommit, intent: .transcription) }
        #expect(throws: AIError.self) { _ = try model.buildSessionConfig(.init(), intent: .transcription) }
    }

    @Test func normalizedRealtimeCodecPreservesUsageAndProviderEnvelope() async throws {
        let model = try GatewayProvider(configuration: .init(apiKey: "key")).realtimeModel("test/live")
        let raw: JSONValue = ["type": "response-done", "responseId": "resp", "status": "completed", "usage": ["inputTokens": 0, "outputTokens": 2, "outputAudioTokens": 1], "raw": ["provider": "wire"]]
        let event = try #require(model.parseServerEvent(raw).first)
        #expect(event == .responseDone(responseID: "resp", status: "completed", raw: raw))
        #expect(event.usage?.inputTokens == 0 && event.usage?.outputAudioTokens == 1)
        #expect(try await model.serializeClientEvent(.conversationItemCreate(.functionCallOutput(callID: "call", name: "lookup", output: "{}"))) == .json(["type": "conversation-item-create", "item": ["type": "function-call-output", "callId": "call", "name": "lookup", "output": "{}"]]))
        let config = AIRealtimeSessionConfiguration(instructions: "hello", outputModalities: [.text], inputAudioFormat: .init(type: "audio/pcm", rate: 16_000), tools: [], providerOptions: ["google": ["option": false]])
        let payload = model.buildSessionConfig(config)
        #expect(payload == ["instructions": "hello", "outputModalities": ["text"], "inputAudioFormat": ["type": "audio/pcm", "rate": 16000], "tools": [], "providerOptions": ["google": ["option": false]]])
        #expect(try await model.serializeClientEvent(.sessionUpdate(config)) == .json(["type": "session-update", "config": payload]))
        #expect(try await model.serializeClientEvent(.contextAppend(content: "context", delegationID: nil)) == .json(["type": "context-append", "content": "context", "delegationId": .null]))
    }
}

private actor GatewayWeeklyKeys {
    var count = 0
    func next() -> String { count += 1; return "key-\(count)" }
}
