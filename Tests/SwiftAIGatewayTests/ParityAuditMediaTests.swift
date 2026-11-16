import Foundation
import Testing
@testable import SwiftAIGateway
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

// Translations of @ai-sdk/gateway 4.0.146 media/batch/realtime-auth tests
// (gateway-{image,video,speech,transcription,embedding,reranking}-model.test.ts,
// gateway-speech-model-stream.test.ts, gateway-realtime-auth.test.ts and
// gateway-batch.test.ts) that were missing or only partially asserted.

private func mediaProvider(_ transport: RecordingTransport) throws -> GatewayProvider {
    try GatewayProvider(configuration: .init(apiKey: "test-token", baseURL: "https://api.test.com", transport: transport))
}

private func requestBody(_ transport: RecordingTransport, _ index: Int = 0) async throws -> JSONValue {
    let requests = await transport.requests()
    return try decodeJSONBody(try #require(requests[index].body))
}

private func gatewayErrorOf(_ error: any Error) -> GatewayError? {
    if let error = error as? GatewayError { return error }
    if case let AIError.gateway(error)? = error as? AIError { return error }
    return nil
}

private func errorResponse(_ status: Int, _ body: String) -> AIHTTPResponse {
    AIHTTPResponse(statusCode: status, headers: ["content-type": "application/json"], body: Data(body.utf8))
}

private func ndjsonResponse(_ text: String) -> AIHTTPResponse {
    AIHTTPResponse(statusCode: 200, headers: ["content-type": "application/x-ndjson"], body: Data(text.utf8))
}

@Suite struct ParityAuditImageTests {
    @Test func omitsOptionalParametersButSendsDefaultCountAndProviderOptions() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"images":["base64-image-1"]}"#))
        let model = try mediaProvider(transport).imageModel("google/imagen-4.0-generate")
        _ = try await model.generateImage(.init(prompt: "A simple prompt"))
        #expect(try await requestBody(transport) == ["prompt": "A simple prompt", "n": 1, "providerOptions": [:]])
        let request = try #require(await transport.requests().first)
        #expect(request.url.absoluteString == "https://api.test.com/image-model")
        #expect(request.headers["authorization"] == "Bearer test-token")
        #expect(request.headers["ai-image-model-specification-version"] == "4")
        #expect(request.headers["ai-model-id"] == "google/imagen-4.0-generate")
    }

    @Test func sendsAllParametersAndPassesSeedZero() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"images":["base64-1","base64-2"]}"#))
        let model = try mediaProvider(transport).imageModel("google/imagen-4.0-generate")
        let result = try await model.generateImage(.init(prompt: "A cat playing piano", size: "1024x1024", aspectRatio: "16:9", seed: 42, count: 2, providerOptions: ["vertex": ["safetySettings": "block_none"]]))
        #expect(result.base64Images == ["base64-1", "base64-2"])
        #expect(try await requestBody(transport) == [
            "prompt": "A cat playing piano", "n": 2, "size": "1024x1024", "aspectRatio": "16:9", "seed": 42,
            "providerOptions": ["vertex": ["safetySettings": "block_none"]]
        ])
        _ = try await model.generateImage(.init(prompt: "p", seed: 0, count: 1))
        #expect(try await requestBody(transport, 1)["seed"] == 0)
    }

    @Test func returnsUsageOnlyWhenProvided() async throws {
        let transport = RecordingTransport(responses: [
            jsonResponse(#"{"images":["base64-1"],"usage":{"inputTokens":27,"outputTokens":6240,"totalTokens":6267}}"#),
            jsonResponse(#"{"images":["base64-1"],"usage":{"inputTokens":10}}"#),
            jsonResponse(#"{"images":["base64-1"]}"#)
        ])
        let model = try mediaProvider(transport).imageModel("test/image")
        #expect(try await model.generateImage(.init(prompt: "p")).usage == TokenUsage(inputTokens: 27, outputTokens: 6240, totalTokens: 6267))
        #expect(try await model.generateImage(.init(prompt: "p")).usage == TokenUsage(inputTokens: 10))
        #expect(try await model.generateImage(.init(prompt: "p")).usage == nil)
    }

    @Test func returnsRetryabilityWarningsAndProviderMetadata() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"""
        {"images":["base64-1"],"isRetryable":false,
         "warnings":[{"type":"deprecated","setting":"size","message":"Use aspectRatio."},{"type":"unsupported","feature":"seed","details":"ignored"},{"type":"other","message":"note"}],
         "providerMetadata":{"vertex":{"images":[{"revisedPrompt":"r"}]},"gateway":{"routing":{"provider":"vertex"}}}}
        """#))
        let result = try await mediaProvider(transport).imageModel("test/image").generateImage(.init(prompt: "p"))
        #expect(result.isRetryable == false)
        #expect(result.warnings == [
            AIWarning(type: "deprecated", setting: "size", message: "Use aspectRatio."),
            AIWarning(type: "unsupported", feature: "seed", message: "ignored"),
            AIWarning(type: "other", message: "note")
        ])
        #expect(result.providerMetadata == ["vertex": ["images": [["revisedPrompt": "r"]]], "gateway": ["routing": ["provider": "vertex"]]])
        #expect(result.responseMetadata.modelID == "test/image")
    }

    @Test(arguments: [true, false])
    func streamingDecodingOptionIsStrippedLikeUpstream(enabled: Bool) async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"images":["AQI="]}"#))
        let model = try mediaProvider(transport).imageModel("test/image")
        let flag = JSONValue.bool(enabled)
        _ = try await model.generateImage(.init(prompt: "p", count: 2, providerOptions: ["gateway": ["experimental_streamingImageDecoding": flag, "tags": ["images"]], "openai": ["quality": "hd"]]))
        _ = try await model.generateImage(.init(prompt: "p", count: 2, providerOptions: ["gateway": ["experimental_streamingImageDecoding": flag]]))
        _ = try await model.generateImage(.init(prompt: "p", count: 2, providerOptions: ["gateway": ["experimental_streamingImageDecoding": flag], "openai": ["quality": "hd"]]))
        #expect(try await requestBody(transport, 0)["providerOptions"] == ["gateway": ["tags": ["images"]], "openai": ["quality": "hd"]])
        #expect(try await requestBody(transport, 1)["providerOptions"] == nil)
        #expect(try await requestBody(transport, 2)["providerOptions"] == ["openai": ["quality": "hd"]])
    }

    @Test func gatewayOptionsWithoutTheClientOptionAreForwardedUnchanged() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"images":["AQI="]}"#))
        _ = try await mediaProvider(transport).imageModel("test/image").generateImage(.init(prompt: "p", providerOptions: ["gateway": [:]]))
        #expect(try await requestBody(transport)["providerOptions"] == ["gateway": [:]])
    }

    @Test func mergesCustomHeadersAndPassesAbortSignal() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"images":["AQI="]}"#))
        let signal = AIAbortController().signal
        _ = try await mediaProvider(transport).imageModel("openai/dall-e-3").generateImage(.init(prompt: "p", headers: ["X-Custom-Header": "custom-value"], abortSignal: signal))
        let request = try #require(await transport.requests().first)
        #expect(request.headers["X-Custom-Header"] == "custom-value")
        #expect(request.headers["ai-model-id"] == "openai/dall-e-3")
        #expect(request.abortSignal != nil)
    }

    @Test func mapsAPIAndAuthenticationErrors() async throws {
        for (status, type) in [(400, "invalid_request_error"), (401, "authentication_error")] {
            let transport = RecordingTransport(response: errorResponse(status, #"{"error":{"message":"bad","type":"\#(type)"}}"#))
            do { _ = try await mediaProvider(transport).imageModel("test/image").generateImage(.init(prompt: "p")); Issue.record("Expected error") }
            catch { #expect(gatewayErrorOf(error)?.statusCode == status) }
        }
    }

    @Test func encodesFilesAndMaskLikeUpstream() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"images":["AQI="]}"#))
        _ = try await mediaProvider(transport).imageModel("test/image").generateImage(.init(
            prompt: "Edit these images",
            files: [ImageInputFile(data: Data([1, 2, 3]), mediaType: "image/png"), ImageInputFile(url: "https://example.com/image.png")],
            mask: ImageInputFile(data: Data([4, 5, 6]), mediaType: "image/png")
        ))
        let body = try await requestBody(transport)
        #expect(body["files"] == [["type": "file", "mediaType": "image/png", "data": "AQID"], ["type": "url", "url": "https://example.com/image.png"]])
        #expect(body["mask"] == ["type": "file", "mediaType": "image/png", "data": "BAUG"])
    }
}

@Suite struct ParityAuditVideoTests {
    private func resultEvent(_ videos: String = #"[{"type":"base64","data":"base64-video-1","mediaType":"video/mp4"}]"#) -> AIHTTPResponse {
        sseResponse(#"data: {"type":"result","videos":\#(videos)}"#)
    }

    @Test func omitsOptionalParametersButSendsDefaultCountAndProviderOptions() async throws {
        let transport = RecordingTransport(response: resultEvent())
        let model = try mediaProvider(transport).videoModel("google/veo-3.0-generate-001")
        let result = try await model.generateVideo(.init(prompt: "A simple prompt"))
        #expect(result.base64Videos == ["base64-video-1"])
        #expect(try await requestBody(transport) == ["prompt": "A simple prompt", "n": 1, "providerOptions": [:]])
        let request = try #require(await transport.requests().first)
        #expect(request.url.absoluteString == "https://api.test.com/video-model")
        #expect(request.headers["accept"] == "text/event-stream")
        #expect(request.headers["ai-video-model-specification-version"] == "4")
    }

    @Test func sendsAllParametersAndOmitsFalsyValuesLikeUpstream() async throws {
        let transport = RecordingTransport(response: resultEvent())
        let model = try mediaProvider(transport).videoModel("test/video")
        _ = try await model.generateVideo(.init(prompt: "A cat playing piano", aspectRatio: "16:9", durationSeconds: 5, resolution: "1920x1080", fps: 24, generateAudio: true, seed: 42, count: 1, providerOptions: ["fal": ["motionStrength": 0.8]]))
        #expect(try await requestBody(transport) == [
            "prompt": "A cat playing piano", "n": 1, "aspectRatio": "16:9", "resolution": "1920x1080", "duration": 5, "fps": 24,
            "seed": 42, "generateAudio": true, "providerOptions": ["fal": ["motionStrength": 0.8]]
        ])
        _ = try await model.generateVideo(.init(prompt: "p", aspectRatio: "", durationSeconds: 0, resolution: "", fps: 0, seed: 0))
        #expect(try await requestBody(transport, 1) == ["prompt": "p", "n": 1, "seed": 0, "providerOptions": [:]])
    }

    @Test func throwsSSEErrorEventsWithMessageAndStatus() async throws {
        let transport = RecordingTransport(response: sseResponse(#"data: {"type":"error","message":"Rate limit exceeded","errorType":"rate_limit_exceeded","statusCode":429,"param":null}"#))
        do { _ = try await mediaProvider(transport).videoModel("test/video").generateVideo(.init(prompt: "p")); Issue.record("Expected error") }
        catch {
            let gatewayError = try #require(gatewayErrorOf(error))
            #expect(gatewayError.message == "Rate limit exceeded")
            #expect(gatewayError.statusCode == 429)
            #expect(gatewayError.type == .rateLimitExceeded)
        }
    }

    @Test func ignoresHeartbeatCommentsAndThrowsOnEmptyStream() async throws {
        let transport = RecordingTransport(responses: [
            sseResponse(":\n\n:\n\ndata: {\"type\":\"result\",\"videos\":[{\"type\":\"base64\",\"data\":\"base64-1\",\"mediaType\":\"video/mp4\"}]}"),
            AIHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: Data())
        ])
        let model = try mediaProvider(transport).videoModel("test/video")
        #expect(try await model.generateVideo(.init(prompt: "p")).base64Videos == ["base64-1"])
        await #expect(throws: (any Error).self) { _ = try await model.generateVideo(.init(prompt: "p")) }
    }

    @Test func startOmitsOptionalFieldsAndCallbackURL() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"operation":{"gatewayJobId":"job_123"}}"#))
        let model = try #require(try mediaProvider(transport).videoModel("test/video") as? GatewayVideoModel)
        let result = try await model.startVideoGeneration(.init(request: .init(prompt: "A beautiful sunset over mountains")))
        #expect(result.operation == ["gatewayJobId": "job_123"])
        #expect(result.warnings.isEmpty)
        #expect(try await requestBody(transport) == ["prompt": "A beautiful sunset over mountains", "n": 1, "providerOptions": [:]])
        #expect(await transport.requests().first?.headers["idempotency-key"] == nil)
    }

    @Test func startSendsFullBodyWithCallbackURL() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"operation":{"gatewayJobId":"job_123"},"warnings":[{"type":"other","message":"queued"}],"providerMetadata":{"gateway":{"asyncJob":{"jobId":"job_123","status":"queued"}}}}"#))
        let model = try #require(try mediaProvider(transport).videoModel("test/video") as? GatewayVideoModel)
        let result = try await model.startVideoGeneration(.init(request: .init(prompt: "A beautiful sunset over mountains", aspectRatio: "16:9", durationSeconds: 5, resolution: "1280x720", fps: 24, generateAudio: true, seed: 123, providerOptions: ["gateway": ["tags": ["async"]]], headers: ["idempotency-key": "aisdk_vid_abc123"]), webhookURL: "https://example.com/webhook"))
        #expect(result.warnings == [AIWarning(type: "other", message: "queued")])
        #expect(result.providerMetadata == ["gateway": ["asyncJob": ["jobId": "job_123", "status": "queued"]]])
        #expect(try await requestBody(transport) == [
            "prompt": "A beautiful sunset over mountains", "n": 1, "aspectRatio": "16:9", "resolution": "1280x720", "duration": 5, "fps": 24,
            "seed": 123, "generateAudio": true, "providerOptions": ["gateway": ["tags": ["async"]]], "callbackUrl": "https://example.com/webhook"
        ])
        let request = try #require(await transport.requests().first)
        #expect(request.url.absoluteString == "https://api.test.com/video-model/start")
        #expect(request.headers["idempotency-key"] == "aisdk_vid_abc123")
    }

    @Test func statusMapsPendingErrorAndCancelled() async throws {
        let transport = RecordingTransport(responses: [
            jsonResponse(#"{"status":"pending","providerMetadata":{"gateway":{"asyncJob":{"jobId":"job_123","status":"running"}}}}"#),
            jsonResponse(#"{"status":"error","error":"Async video job failed"}"#),
            jsonResponse(#"{"status":"cancelled"}"#)
        ])
        let model = try #require(try mediaProvider(transport).videoModel("test/video") as? GatewayVideoModel)
        guard case let .pending(_, metadata, _) = try await model.videoGenerationStatus(.init(operation: ["gatewayJobId": "job_123"])) else { Issue.record("Expected pending"); return }
        #expect(metadata == ["gateway": ["asyncJob": ["jobId": "job_123", "status": "running"]]])
        #expect(try await requestBody(transport) == ["operation": ["gatewayJobId": "job_123"]])
        guard case let .failed(message, _, _) = try await model.videoGenerationStatus(.init(operation: ["gatewayJobId": "job_123"])) else { Issue.record("Expected error"); return }
        #expect(message == "Async video job failed")
        guard case let .failed(cancelled, _, _) = try await model.videoGenerationStatus(.init(operation: ["gatewayJobId": "job_123"])) else { Issue.record("Expected cancellation"); return }
        #expect(cancelled == "Video generation was cancelled.")
    }
}

@Suite struct ParityAuditSpeechTests {
    @Test func sendsSpeechOptionsAndOmitsAbsentOrEmptyOnes() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"audio":"AQID"}"#))
        let model = try mediaProvider(transport).speechModel("openai/tts-1")
        _ = try await model.speak(.init(text: "Hello world", voice: "alloy", format: "mp3", speed: 1.25, language: "en", instructions: "Speak clearly", providerOptions: ["openai": ["style": "friendly"]], headers: ["Custom-Header": "test-value"]))
        #expect(try await requestBody(transport) == ["text": "Hello world", "voice": "alloy", "outputFormat": "mp3", "instructions": "Speak clearly", "speed": 1.25, "language": "en", "providerOptions": ["openai": ["style": "friendly"]]])
        let request = try #require(await transport.requests().first)
        #expect(request.url.absoluteString == "https://api.test.com/speech-model")
        #expect(request.headers["Custom-Header"] == "test-value")
        #expect(request.headers["ai-speech-model-specification-version"] == "4")
        #expect(request.headers["ai-model-id"] == "openai/tts-1")
        _ = try await model.speak(.init(text: "Hello world"))
        _ = try await model.speak(.init(text: "Hello world", voice: "", format: "", language: "", instructions: ""))
        #expect(try await requestBody(transport, 1) == ["text": "Hello world"])
        #expect(try await requestBody(transport, 2) == ["text": "Hello world"])
    }

    @Test func extractsAudioAndMetadata() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"audio":"AQID","warnings":[{"type":"other","message":"test warning"}],"usage":{"characters":11},"providerMetadata":{"gateway":{"cost":"0.002"}}}"#, headers: ["x-request-id": "req-123"]))
        let result = try await mediaProvider(transport).speechModel("openai/tts-1").speak(.init(text: "Hello world"))
        #expect(result.audio == Data([1, 2, 3]))
        #expect(result.warnings == [AIWarning(type: "other", message: "test warning")])
        #expect(result.usage == ["characters": 11])
        #expect(result.providerMetadata == ["gateway": ["cost": "0.002"]])
        #expect(result.responseMetadata.headers["x-request-id"] == "req-123")
        #expect(result.responseMetadata.modelID == "openai/tts-1")
    }

    @Test func mapsTypedErrors() async throws {
        for (status, type, expected) in [(400, "invalid_request_error", GatewayErrorType.invalidRequestError), (500, "internal_server_error", .internalServerError)] {
            let transport = RecordingTransport(response: errorResponse(status, #"{"error":{"message":"m","type":"\#(type)"}}"#))
            do { _ = try await mediaProvider(transport).speechModel("openai/tts-1").speak(.init(text: "Hello")); Issue.record("Expected error") }
            catch { #expect(gatewayErrorOf(error)?.type == expected); #expect(gatewayErrorOf(error)?.statusCode == status) }
        }
    }

    @Test func streamClosedBeforeFinishUsesUpstreamGatewayMessage() async throws {
        let socket = WeeklySpeechSocketTransport()
        let provider = try GatewayProvider(configuration: .init(apiKey: "test-token"), webSocketTransport: socket)
        let result = try await provider.experimentalSpeech("elevenlabs/eleven-flash-v2.5").stream(.init(text: "Hi"))
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count >= 2 })
        socket.socket.closed(1011)
        do { for try await _ in result.stream {}; Issue.record("Expected close error") }
        catch {
            let gatewayError = try #require(gatewayErrorOf(error))
            #expect(gatewayError.type == .responseError)
            #expect(gatewayError.statusCode == 500)
            #expect(gatewayError.message.contains("AI Gateway speech stream closed before a finish part was received (code 1011)."))
        }
    }

    @Test func untypedServerErrorPartBecomesGatewayResponseErrorOnClose() async throws {
        let socket = WeeklySpeechSocketTransport()
        let provider = try GatewayProvider(configuration: .init(apiKey: "test-token"), webSocketTransport: socket)
        let result = try await provider.experimentalSpeech("test/model").stream(.init(text: "Hi"))
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count >= 2 })
        try socket.socket.receive(["type": "error", "error": ["code": "overloaded"]])
        socket.socket.closed(1011)
        var sawErrorPart = false
        do { for try await part in result.stream { if case .error = part { sawErrorPart = true } }; Issue.record("Expected terminal error") }
        catch {
            let gatewayError = try #require(gatewayErrorOf(error))
            #expect(gatewayError.type == .responseError)
            #expect(gatewayError.message == #"Invalid error response format: Gateway request failed: AI Gateway speech stream failed: {"code":"overloaded"}"#)
        }
        #expect(sawErrorPart)
    }
}

@Suite struct ParityAuditTranscriptionTests {
    @Test func encodesAudioAndOmitsEmptyProviderOptions() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"text":"Hello world"}"#))
        let model = try mediaProvider(transport).transcriptionModel("openai/gpt-4o-transcribe")
        _ = try await model.transcribe(.init(audio: Data([1, 2, 3]), mimeType: "audio/wav", providerOptions: ["openai": ["language": "en"]]))
        _ = try await model.transcribe(.init(audio: Data([1, 2, 3]), mimeType: "audio/wav"))
        #expect(try await requestBody(transport) == ["audio": "AQID", "mediaType": "audio/wav", "providerOptions": ["openai": ["language": "en"]]])
        #expect(try await requestBody(transport, 1) == ["audio": "AQID", "mediaType": "audio/wav"])
        #expect(await transport.requests().first?.url.absoluteString == "https://api.test.com/transcription-model")
    }

    @Test func extractsFieldsAndDefaultsOptionalOnes() async throws {
        let transport = RecordingTransport(responses: [
            jsonResponse(#"{"text":"Hello world","segments":[{"text":"Hello","startSecond":0,"endSecond":0.5},{"text":"world","startSecond":0.5,"endSecond":1}],"language":"en","durationInSeconds":1,"warnings":[{"type":"other","message":"test warning"}],"usage":{"inputTokens":11},"providerMetadata":{"gateway":{"cost":"0.002"}}}"#, headers: ["x-request-id": "req-123"]),
            jsonResponse(#"{"text":"Hello world"}"#),
            jsonResponse(#"{"text":"Hello world","segments":[{"text":"Hello world","startSecond":0,"endSecond":1}]}"#)
        ])
        let model = try mediaProvider(transport).transcriptionModel("openai/gpt-4o-transcribe")
        let result = try await model.transcribe(.init(audio: Data([1])))
        #expect(result.segments == [.init(text: "Hello", startSecond: 0, endSecond: 0.5), .init(text: "world", startSecond: 0.5, endSecond: 1)])
        #expect(result.language == "en")
        #expect(result.durationInSeconds == 1)
        #expect(result.warnings == [AIWarning(type: "other", message: "test warning")])
        #expect(result.usage == ["inputTokens": 11])
        #expect(result.providerMetadata == ["gateway": ["cost": "0.002"]])
        #expect(result.responseMetadata.headers["x-request-id"] == "req-123")
        let defaults = try await model.transcribe(.init(audio: Data([1])))
        #expect(defaults.segments.isEmpty)
        #expect(defaults.language == nil)
        #expect(defaults.durationInSeconds == nil)
        #expect(defaults.warnings.isEmpty)
        // Upstream never derives durationInSeconds from segment timings.
        #expect(try await model.transcribe(.init(audio: Data([1]))).durationInSeconds == nil)
    }

    @Test func warnsForSharedTimestampGranularitiesOnly() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"text":"Hello world","warnings":[{"type":"other","message":"test warning"}]}"#))
        let model = try mediaProvider(transport).transcriptionModel("openai/gpt-4o-transcribe")
        let warned = try await model.transcribe(.init(audio: Data([1, 2, 3]), providerOptions: ["openai": ["timestampGranularities": ["segment"]], "gateway": ["order": ["openai"]]], timestampGranularities: [.word, .segment]))
        #expect(warned.warnings == [
            AIWarning(type: "other", message: "test warning"),
            AIWarning(type: "unsupported", feature: "timestampGranularities", message: "The AI Gateway adapter does not forward the shared timestampGranularities option.")
        ])
        #expect(try await requestBody(transport) == ["audio": "AQID", "mediaType": "audio/wav", "providerOptions": ["openai": ["timestampGranularities": ["segment"]], "gateway": ["order": ["openai"]]]])
        let empty = try await model.transcribe(.init(audio: Data([1]), timestampGranularities: []))
        #expect(empty.warnings == [AIWarning(type: "other", message: "test warning")])
    }

    @Test(arguments: ["xai", "spacexai"])
    func warnsWhenXAIDiarizationIsUnavailable(namespace: String) async throws {
        let transport = RecordingTransport(responses: [
            jsonResponse(#"{"text":"Hello world"}"#),
            jsonResponse(#"{"text":"Hello world","segments":[{"text":"Hello world","startSecond":0,"endSecond":1,"speaker":"0"}]}"#)
        ])
        let model = try mediaProvider(transport).transcriptionModel("spacexai/grok-stt")
        let warned = try await model.transcribe(.init(audio: Data([1]), providerOptions: [namespace: ["diarize": true]]))
        #expect(warned.warnings.contains(AIWarning(type: "unsupported", feature: "providerOptions.xai.diarize", message: "AI Gateway does not currently expose xAI speaker diarization metadata.")))
        let available = try await model.transcribe(.init(audio: Data([1]), providerOptions: [namespace: ["diarize": true]]))
        #expect(available.warnings.isEmpty)
    }

    @Test func streamCloseWithoutFinishIsGatewayResponseError() async throws {
        let socket = WeeklySpeechSocketTransport()
        let provider = try GatewayProvider(configuration: .init(apiKey: "test-token"), webSocketTransport: socket)
        let result = try await provider.experimentalTranscription("openai/gpt-realtime-whisper").stream(.init(audio: .chunks([Data([1, 2, 3])]), inputAudioFormat: .init(mediaType: "audio/pcm", sampleRate: 16_000)))
        socket.socket.open()
        #expect(await weeklySpeechWait { !socket.socket.sent.isEmpty })
        socket.socket.closed(1011)
        do { for try await _ in result.stream {}; Issue.record("Expected close error") }
        catch {
            let gatewayError = try #require(gatewayErrorOf(error))
            #expect(gatewayError.type == .responseError)
            #expect(gatewayError.message.contains("AI Gateway transcription stream closed before a finish part was received"))
        }
    }

    @Test(arguments: [
        (JSONValue.object(["message": "model overloaded"]), "model overloaded"),
        (JSONValue.string("model overloaded"), "model overloaded"),
        (JSONValue.object(["code": "overloaded"]), #"{"code":"overloaded"}"#)
    ])
    func untypedErrorPartsSurfaceTheServerMessage(payload: JSONValue, expected: String) async throws {
        let socket = WeeklySpeechSocketTransport()
        let provider = try GatewayProvider(configuration: .init(apiKey: "test-token"), webSocketTransport: socket)
        let result = try await provider.experimentalTranscription("openai/gpt-realtime-whisper").stream(.init(audio: .chunks([Data([1, 2, 3])]), inputAudioFormat: .init(mediaType: "audio/pcm", sampleRate: 16_000)))
        socket.socket.open()
        #expect(await weeklySpeechWait { !socket.socket.sent.isEmpty })
        try socket.socket.receive(["type": "error", "error": payload])
        socket.socket.closed(1011)
        do { for try await _ in result.stream {}; Issue.record("Expected terminal error") }
        catch {
            let gatewayError = try #require(gatewayErrorOf(error))
            #expect(gatewayError.type == .responseError)
            #expect(gatewayError.message == "Invalid error response format: Gateway request failed: AI Gateway transcription stream failed: \(expected)")
            #expect(!gatewayError.message.contains("[object Object]"))
        }
    }
}

@Suite struct ParityAuditEmbeddingAndRerankingTests {
    @Test func embeddingForwardsDimensionsAndProviderOptionsOnlyWhenProvided() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"embeddings":[[0.1,0.2]],"usage":{"tokens":8}}"#))
        let model = try mediaProvider(transport).embeddingModel("openai/text-embedding-3-small")
        _ = try await model.embed(.init(values: ["sunny day"], dimensions: 256, providerOptions: ["openai": ["dimensions": 512]]))
        _ = try await model.embed(.init(values: ["sunny day"], dimensions: 256))
        _ = try await model.embed(.init(values: ["sunny day"], headers: ["Custom-Header": "test-value"]))
        #expect(try await requestBody(transport, 0) == ["values": ["sunny day"], "dimensions": 256, "providerOptions": ["openai": ["dimensions": 512]]])
        #expect(try await requestBody(transport, 1) == ["values": ["sunny day"], "dimensions": 256])
        #expect(try await requestBody(transport, 2) == ["values": ["sunny day"]])
        let request = try #require(await transport.requests().last)
        #expect(request.headers["Custom-Header"] == "test-value")
        #expect(request.headers["ai-embedding-model-specification-version"] == "4")
        #expect(request.headers["ai-model-id"] == "openai/text-embedding-3-small")
    }

    @Test func embeddingExtractsUsageWarningsAndProviderMetadata() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"embeddings":[[0.1]],"usage":{"tokens":42},"warnings":[{"type":"deprecated","setting":"dimensions","message":"Use outputDimensions instead."}],"providerMetadata":{"gateway":{"routing":{"test":true}}}}"#))
        let result = try await mediaProvider(transport).embeddingModel("test/embed").embed(.init(values: ["a"]))
        #expect(result.usage?.totalTokens == 42)
        #expect(result.warnings == [AIWarning(type: "deprecated", setting: "dimensions", message: "Use outputDimensions instead.")])
        #expect(result.providerMetadata == ["gateway": ["routing": ["test": true]]])
        #expect(result.rawValue["providerMetadata"] == ["gateway": ["routing": ["test": true]]])
    }

    @Test func embeddingAndRerankingConvertGatewayErrors() async throws {
        for (status, type, expected) in [(400, "invalid_request_error", GatewayErrorType.invalidRequestError), (500, "internal_server_error", .internalServerError)] {
            let body = #"{"error":{"message":"m","type":"\#(type)"}}"#
            do { _ = try await mediaProvider(RecordingTransport(response: errorResponse(status, body))).embeddingModel("e").embed(.init(values: ["a"])); Issue.record("Expected error") }
            catch { #expect(gatewayErrorOf(error)?.type == expected) }
            do { _ = try await mediaProvider(RecordingTransport(response: errorResponse(status, body))).rerankingModel("r").rerank(.init(query: "q", documents: ["a"])); Issue.record("Expected error") }
            catch { #expect(gatewayErrorOf(error)?.type == expected); #expect(gatewayErrorOf(error)?.statusCode == status) }
        }
    }

    @Test func rerankingSendsDocumentsQueryAndOmitsTopN() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"ranking":[{"index":1,"relevanceScore":0.9},{"index":0,"relevanceScore":0.1}],"warnings":[{"type":"other","message":"w"}],"providerMetadata":{"cohere":{"id":"x"}}}"#, headers: ["x-request-id": "r"]))
        let model = try mediaProvider(transport).rerankingModel("cohere/rerank-v3.5")
        let result = try await model.rerank(.init(query: "q", documents: ["a", "b"]))
        #expect(result.results == [RerankedDocument(index: 1, score: 0.9), RerankedDocument(index: 0, score: 0.1)])
        #expect(result.warnings == [AIWarning(type: "other", message: "w")])
        #expect(result.providerMetadata == ["cohere": ["id": "x"]])
        #expect(result.responseMetadata.headers["x-request-id"] == "r")
        #expect(try await requestBody(transport) == ["documents": ["a", "b"], "query": "q"])
        let request = try #require(await transport.requests().first)
        #expect(request.url.absoluteString == "https://api.test.com/reranking-model")
        #expect(request.headers["ai-reranking-model-specification-version"] == "4")
    }
}

@Suite struct ParityAuditRealtimeAuthTests {
    @Test func offersMarkerAndPrefixedToken() {
        #expect(GatewayRealtimeAuth.realtimeProtocols(token: "vck_test-token") == ["ai-gateway-realtime.v1", "ai-gateway-auth.vck_test-token"])
        #expect(GatewayRealtimeAuth.speechProtocols(token: "t").first == "ai-gateway-speech.v1")
        #expect(GatewayRealtimeAuth.transcriptionProtocols(token: "t").first == "ai-gateway-transcription.v1")
    }

    @Test func offersEncodedTeamScoping() throws {
        let protocols = GatewayRealtimeAuth.realtimeProtocols(token: "vck_test-token", teamIDOrSlug: "team/with/slashes")
        #expect(protocols.count == 3)
        let team = try #require(protocols.last)
        #expect(team.hasPrefix(GatewayRealtimeAuth.teamSubprotocolPrefix))
        let encoded = team.dropFirst(GatewayRealtimeAuth.teamSubprotocolPrefix.count)
        #expect(!encoded.isEmpty && encoded.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        #expect(GatewayRealtimeAuth.teamIDOrSlug(fromSecWebSocketProtocol: protocols.joined(separator: ", ")) == "team/with/slashes")
    }

    @Test func decodesAuthTokens() {
        #expect(GatewayRealtimeAuth.authToken(fromSecWebSocketProtocol: GatewayRealtimeAuth.realtimeProtocols(token: "vck_test-token").joined(separator: ", ")) == "vck_test-token")
        #expect(GatewayRealtimeAuth.authToken(fromSecWebSocketProtocol: "  ai-gateway-auth.oidc-token  ,  ai-gateway-realtime.v1  ") == "oidc-token")
        #expect(GatewayRealtimeAuth.authToken(fromSecWebSocketProtocol: "ai-gateway-realtime.v1") == nil)
        #expect(GatewayRealtimeAuth.authToken(fromSecWebSocketProtocol: "ai-gateway-auth.   ") == nil)
        #expect(GatewayRealtimeAuth.authToken(fromSecWebSocketProtocol: nil) == nil)
        #expect(GatewayRealtimeAuth.authToken(fromSecWebSocketProtocol: "") == nil)
        let jwt = "header.payload.signature"
        #expect(GatewayRealtimeAuth.authToken(fromSecWebSocketProtocol: GatewayRealtimeAuth.realtimeProtocols(token: jwt).joined(separator: ",")) == jwt)
    }

    @Test func decodesTeamScope() throws {
        #expect(GatewayRealtimeAuth.teamIDOrSlug(fromSecWebSocketProtocol: GatewayRealtimeAuth.realtimeProtocols(token: "t", teamIDOrSlug: "team_123").joined(separator: ", ")) == "team_123")
        let team = try #require(GatewayRealtimeAuth.realtimeProtocols(token: "token", teamIDOrSlug: "my-team").last)
        #expect(GatewayRealtimeAuth.teamIDOrSlug(fromSecWebSocketProtocol: "  \(team)  ,  ai-gateway-realtime.v1  ") == "my-team")
        #expect(GatewayRealtimeAuth.teamIDOrSlug(fromSecWebSocketProtocol: "ai-gateway-realtime.v1") == nil)
        #expect(GatewayRealtimeAuth.teamIDOrSlug(fromSecWebSocketProtocol: "ai-gateway-team.%%%") == nil)
    }

    @Test func realtimeModelProtocolsCarryTheProviderTeamScope() async throws {
        let provider = try GatewayProvider(configuration: .init(apiKey: "vck_test-token"), teamIDOrSlug: "my-team")
        let config = provider.realtimeModel("openai/gpt-realtime").getWebSocketConfig(token: "vcst_test-secret", url: "wss://ai-gateway.vercel.sh/v4/ai/realtime-model?ai-model-id=openai%2Fgpt-realtime")
        #expect(GatewayRealtimeAuth.teamIDOrSlug(fromSecWebSocketProtocol: config.protocols.joined(separator: ", ")) == "my-team")
        #expect(GatewayRealtimeAuth.authToken(fromSecWebSocketProtocol: config.protocols.joined(separator: ", ")) == "vcst_test-secret")
    }
}

@Suite struct ParityAuditBatchTests {
    private let succeeded = #"{"type":"text","id":"req-1","status":"succeeded","result":{"content":[{"type":"text","text":"pong 1"}],"finishReason":{"unified":"stop"},"response":{"modelId":"openai/gpt-5.6-luna","timestamp":"2026-08-18T00:00:00.000Z"},"usage":{"inputTokens":{"total":4,"noCache":4},"outputTokens":{"total":2,"text":2}},"warnings":[]}}"#
    private let failed = #"{"type":"text","id":"req-2","status":"failed","error":{"message":"boom"}}"#

    @Test func operationsPostBatchIDWithoutModelHeader() async throws {
        let transport = RecordingTransport(responses: [
            jsonResponse(#"{"batchId":"job_123","status":"completed","rawStatus":"ended","requestCounts":{"total":2,"pending":0,"completed":2,"failed":0},"createdAt":"2026-08-18T00:00:00.000Z"}"#),
            jsonResponse(#"{"batchId":"job_123","status":"pending","providerMetadata":{"gateway":{"asyncJob":{"jobId":"job_123","status":"cancel_requested"}}}}"#),
            ndjsonResponse("\(succeeded)\n\n\(failed)\n")
        ])
        let batch = try mediaProvider(transport).experimentalBatch()
        let status = try await batch.getBatchStatus(.init(batchID: "job_123"))
        #expect(status.status == .completed && status.rawStatus == "ended" && status.createdAt == "2026-08-18T00:00:00.000Z")
        #expect(status.requestCounts == AIBatchRequestCounts(total: 2, pending: 0, completed: 2, failed: 0))
        let cancel = try await batch.cancelBatch(.init(batchID: "job_123", headers: ["custom-header": "cancel-value"]))
        #expect(cancel.providerMetadata == ["gateway": ["asyncJob": ["jobId": "job_123", "status": "cancel_requested"]]])
        var ids: [String] = []
        for try await item in try await batch.getBatchResults(.init(batchID: "job_123")) {
            if case let .text(result) = item {
                switch result {
                case let .succeeded(id, _): ids.append(id)
                case let .failed(id, error, _): ids.append(id); #expect(error.message == "boom")
                default: Issue.record("Unexpected item")
                }
            }
        }
        #expect(ids == ["req-1", "req-2"])
        let requests = await transport.requests()
        #expect(requests.map(\.url.absoluteString) == ["https://api.test.com/batch/status", "https://api.test.com/batch/cancel", "https://api.test.com/batch/results"])
        for request in requests {
            #expect(try decodeJSONBody(try #require(request.body)) == ["batchId": "job_123"])
            #expect(request.headers.keys.contains { $0.lowercased() == "ai-model-id" } == false)
            #expect(request.headers["authorization"] == "Bearer test-token")
        }
        #expect(requests[1].headers["custom-header"] == "cancel-value")
    }

    @Test func cancelAllowsAcknowledgementWithoutProviderMetadata() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"status":"pending","providerMetadata":null}"#))
        let result = try await mediaProvider(transport).experimentalBatch().cancelBatch(.init(batchID: "job_123"))
        #expect(result.providerMetadata.isEmpty)
    }

    @Test func nonTerminalResultsAndMissingCancelJobsUseGatewayErrors() async throws {
        let results = RecordingTransport(response: errorResponse(400, #"{"error":{"message":"The batch is not yet terminal.","type":"invalid_request_error"}}"#))
        do { _ = try await mediaProvider(results).experimentalBatch().getBatchResults(.init(batchID: "job_123")); Issue.record("Expected error") }
        catch {
            #expect(gatewayErrorOf(error)?.type == .invalidRequestError)
            #expect(gatewayErrorOf(error)?.message == "The batch is not yet terminal.")
            #expect(gatewayErrorOf(error)?.statusCode == 400)
        }
        let cancel = RecordingTransport(response: errorResponse(404, #"{"error":{"message":"Async job not found.","type":"not_found"}}"#))
        do { _ = try await mediaProvider(cancel).experimentalBatch().cancelBatch(.init(batchID: "missing-job")); Issue.record("Expected error") }
        catch { #expect(gatewayErrorOf(error)?.type == .notFound) }
        #expect(await cancel.requests().count == 1)
    }
}
