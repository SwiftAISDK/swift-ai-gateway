@testable import SwiftAIGateway
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func gatewayBatchStartUsesGatewayWireContractAndStripsIdempotencyOption() async throws {
    let transport = RecordingTransport(response: jsonResponse("""
    {
      "batchId":"job_123",
      "status":"pending",
      "rawStatus":"queued",
      "requestCounts":{"total":1,"pending":1,"completed":0,"failed":0},
      "createdAt":"2026-08-18T00:00:00.000Z",
      "expiresAt":"2026-08-19T00:00:00.000Z",
      "providerMetadata":{"gateway":{"upstreamProvider":"openai"}},
      "warnings":[{"requestId":"req-1","warning":{"type":"unsupported","feature":"temperature","details":"ignored"}}]
    }
    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try #require(try provider.languageModel("openai/gpt-4.1-mini") as? any BatchLanguageModel)

    let result = try await model.startBatch(AIBatchStartOptions(
        requests: [
            AILanguageModelBatchRequest(
                id: "req-1",
                request: LanguageModelRequest(messages: [.user("Hello")], maxOutputTokens: 25)
            )
        ],
        providerOptions: [
            "gateway": [
                "idempotencyKey": "batch-key-123",
                "order": ["openai", "anthropic"]
            ]
        ],
        headers: ["x-custom": "custom-value"]
    ))

    #expect(result.batchID == "job_123")
    #expect(result.status.status == .pending)
    #expect(result.status.rawStatus == "queued")
    #expect(result.status.requestCounts == AIBatchRequestCounts(total: 1, pending: 1, completed: 0, failed: 0))
    #expect(result.status.providerMetadata["gateway"]?["upstreamProvider"]?.stringValue == "openai")
    #expect(result.warnings == [
        AIBatchWarning(
            requestID: "req-1",
            warning: AIWarning(type: "unsupported", feature: "temperature", message: "ignored")
        )
    ])

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://ai-gateway.vercel.sh/v4/ai/batch/start")
    #expect(request.headers["ai-model-id"] == "openai/gpt-4.1-mini")
    #expect(request.headers["idempotency-key"] == "batch-key-123")
    #expect(request.headers["x-custom"] == "custom-value")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["modelId"]?.stringValue == "openai/gpt-4.1-mini")
    #expect(body["requests"]?[0]?["id"]?.stringValue == "req-1")
    #expect(body["requests"]?[0]?["options"]?["prompt"]?[0]?["content"]?[0]?["text"]?.stringValue == "Hello")
    #expect(body["requests"]?[0]?["options"]?["maxOutputTokens"]?.intValue == 25)
    #expect(body["providerOptions"]?["gateway"]?["idempotencyKey"] == nil)
    #expect(body["providerOptions"]?["gateway"]?["order"]?[0]?.stringValue == "openai")
}

@Test func gatewayBatchStatusOmitsPartialCountsAndMapsNotFound() async throws {
    let partialTransport = RecordingTransport(response: jsonResponse("""
    {"status":"failed","requestCounts":{"total":3,"completed":2},"error":{"message":"upstream failed","type":"provider_error","code":"bad_gateway","statusCode":502}}
    """))
    let partialProvider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: partialTransport))
    let partialModel = try #require(try partialProvider.languageModel("openai/gpt-4.1-mini") as? any BatchLanguageModel)

    let status = try await partialModel.getBatchStatus(AIBatchOperationOptions(batchID: "job_123"))
    #expect(status.status == .failed)
    #expect(status.requestCounts == nil)
    #expect(status.error == AIBatchError(message: "upstream failed", type: "provider_error", code: "bad_gateway", statusCode: 502))

    let notFoundTransport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 404,
        headers: ["content-type": "application/json"],
        body: Data(#"{"error":{"message":"Async job not found.","type":"not_found"}}"#.utf8)
    ))
    let notFoundProvider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: notFoundTransport))
    let notFoundModel = try #require(try notFoundProvider.languageModel("openai/gpt-4.1-mini") as? any BatchLanguageModel)

    do {
        _ = try await notFoundModel.getBatchStatus(AIBatchOperationOptions(batchID: "missing-job"))
        Issue.record("Expected Gateway not_found error")
    } catch let error as AIError {
        guard case let .gateway(gatewayError) = error else {
            Issue.record("Expected AIError.gateway, got \(error)")
            return
        }
        #expect(gatewayError.type == .notFound)
        #expect(gatewayError.upstreamType == "not_found")
        #expect(gatewayError.isNotFound)
        #expect(gatewayError.name == "GatewayNotFoundError")
        #expect(gatewayError.name == "GatewayNotFoundError")
        #expect(gatewayError.statusCode == 404)
        #expect(gatewayError.message == "Async job not found.")
        #expect(!gatewayError.isRetryable)
    }
}

@Test func gatewayBatchResultsParsesChunkedNDJSONAndRevivesNestedV4Result() async throws {
    let succeeded = #"{"id":"req-1","status":"succeeded","result":{"content":[{"type":"text","text":"hello"}],"finishReason":{"unified":"stop","raw":"stop"},"response":{"id":"response-1","modelId":"openai/gpt-4.1-mini","timestamp":"2026-08-18T00:00:00.000Z"},"usage":{"inputTokens":{"total":4,"noCache":4},"outputTokens":{"total":2,"text":2}},"warnings":[]}}"#
    let failed = #"{"id":"req-2","status":"failed","error":{"message":"boom","code":"provider_error"}}"#
    let cancelled = #"{"id":"req-3","status":"cancelled"}"#
    let chunks = [
        Data(succeeded.prefix(30).utf8),
        Data("\(succeeded.dropFirst(30))\r\n\n\(failed.prefix(12))".utf8),
        Data("\(failed.dropFirst(12))\n\(cancelled)".utf8)
    ]
    let transport = GatewayBatchChunkTransport(chunks: chunks)
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try #require(try provider.languageModel("openai/gpt-4.1-mini") as? any BatchLanguageModel)

    let stream = try await model.getBatchResults(AIBatchOperationOptions(batchID: "job_123"))
    var items: [AIBatchItemResult<TextGenerationResult>] = []
    for try await item in stream { items.append(item) }

    #expect(items.count == 3)
    guard case let .succeeded(id, result) = items[0] else {
        Issue.record("Expected succeeded item")
        return
    }
    #expect(id == "req-1")
    #expect(result.text == "hello")
    #expect(result.finishReason == "stop")
    #expect(result.usage?.inputTokens == 4)
    #expect(result.usage?.inputTokensNoCache == 4)
    #expect(result.usage?.outputTokens == 2)
    #expect(result.usage?.outputTextTokens == 2)
    #expect(result.usage?.totalTokens == 6)
    #expect(result.responseMetadata.timestamp == Date(timeIntervalSince1970: 1_787_011_200))
    #expect(result.responseMetadata.modelID == "openai/gpt-4.1-mini")

    guard case let .failed(failedID, error, _) = items[1] else {
        Issue.record("Expected failed item")
        return
    }
    #expect(failedID == "req-2")
    #expect(error == AIBatchError(message: "boom", code: "provider_error"))
    guard case let .cancelled(cancelledID, nil, _) = items[2] else {
        Issue.record("Expected cancelled item")
        return
    }
    #expect(cancelledID == "req-3")

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://ai-gateway.vercel.sh/v4/ai/batch/results")
    #expect(try decodeJSONBody(try #require(request.body))["batchId"]?.stringValue == "job_123")
    #expect(request.headers["ai-model-id"] == "openai/gpt-4.1-mini")
}

@Test func gatewayBatchResultsPreservesMixedOrderedV4ContentAndPartMetadata() async throws {
    let succeeded = #"""
    {
      "id": "req-mixed",
      "status": "succeeded",
      "result": {
        "content": [
          {
            "type": "reasoning",
            "text": "think",
            "providerMetadata": {"gateway": {"signature": "sig_1"}}
          },
          {
            "type": "text",
            "text": "first",
            "providerMetadata": {"openai": {"itemId": "msg_1"}}
          },
          {
            "type": "file",
            "id": "file_1",
            "mediaType": "image/png",
            "filename": "chart.png",
            "data": {"type": "data", "data": "AQID"},
            "providerMetadata": {"files": {"kind": "generated"}}
          },
          {
            "type": "source",
            "sourceType": "document",
            "id": "source_1",
            "mediaType": "application/pdf",
            "title": "Quarterly report",
            "filename": "report.pdf",
            "providerMetadata": {"search": {"rank": 1}}
          },
          {
            "type": "custom",
            "kind": "openai.compaction",
            "providerMetadata": {"openai": {"itemId": "cmp_1"}}
          },
          {
            "type": "tool-call",
            "toolCallId": "call_1",
            "toolName": "lookup",
            "input": "{\"city\":\"Tokyo\"}",
            "providerExecuted": true,
            "dynamic": true,
            "providerMetadata": {"gateway": {"trace": "call"}}
          },
          {
            "type": "tool-result",
            "toolCallId": "call_1",
            "toolName": "lookup",
            "result": {"temperature": 29},
            "preliminary": true,
            "dynamic": true,
            "providerMetadata": {"gateway": {"trace": "result"}}
          },
          {
            "type": "tool-approval-request",
            "approvalId": "approval_1",
            "toolCallId": "call_1",
            "providerMetadata": {"gateway": {"trace": "approval"}}
          },
          {
            "type": "reasoning-file",
            "mediaType": "application/json",
            "data": {"type": "url", "url": "https://cdn.example.com/reasoning.json"},
            "providerMetadata": {"openai": {"containerId": "container_1"}}
          },
          {
            "type": "tool-approval-response",
            "approvalId": "approval_1",
            "approved": false,
            "reason": "not now",
            "providerExecuted": true,
            "providerMetadata": {"gateway": {"trace": "approval-response"}}
          },
          {
            "type": "text",
            "text": " second",
            "providerMetadata": {"openai": {"itemId": "msg_2"}}
          }
        ],
        "finishReason": {"unified": "stop", "raw": "stop"},
        "usage": {
          "inputTokens": {"total": 8},
          "outputTokens": {"total": 5, "reasoning": 2, "text": 3}
        },
        "providerMetadata": {"gateway": {"route": "batch"}},
        "warnings": []
      }
    }
    """#
    let succeededLine = try encodeJSONBody(secureJSONParse(succeeded))
    let transport = GatewayBatchChunkTransport(chunks: [succeededLine])
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(
        apiKey: "gateway-key",
        transport: transport
    ))
    let model = try #require(
        try provider.languageModel("openai/gpt-4.1-mini") as? any BatchLanguageModel
    )

    let stream = try await model.getBatchResults(AIBatchOperationOptions(batchID: "job_mixed"))
    var items: [AIBatchItemResult<TextGenerationResult>] = []
    for try await item in stream { items.append(item) }

    let item = try #require(items.first)
    guard case let .succeeded(id, result) = item else {
        Issue.record("Expected succeeded mixed-content Gateway batch result")
        return
    }
    #expect(id == "req-mixed")
    #expect(result.content.count == 11)
    #expect(result.text == "first second")
    #expect(result.reasoning == "think")
    #expect(result.finishReason == "stop")
    #expect(result.providerMetadata["gateway"]?["route"]?.stringValue == "batch")

    guard case let .reasoning(reasoning, reasoningMetadata) = result.content[0] else {
        Issue.record("Expected ordered reasoning part")
        return
    }
    #expect(reasoning == "think")
    #expect(reasoningMetadata["gateway"]?["signature"]?.stringValue == "sig_1")

    guard case let .text(firstText, firstTextMetadata) = result.content[1] else {
        Issue.record("Expected first ordered text part")
        return
    }
    #expect(firstText == "first")
    #expect(firstTextMetadata["openai"]?["itemId"]?.stringValue == "msg_1")

    guard case let .file(file) = result.content[2] else {
        Issue.record("Expected ordered generated file part")
        return
    }
    #expect(file.id == "file_1")
    #expect(file.mediaType == "image/png")
    #expect(file.filename == "chart.png")
    #expect(file.data == Data([1, 2, 3]))
    #expect(file.providerMetadata["files"]?["kind"]?.stringValue == "generated")
    #expect(file.rawValue?["data"]?["type"]?.stringValue == "data")

    guard case let .source(source) = result.content[3] else {
        Issue.record("Expected ordered source part")
        return
    }
    #expect(source.id == "source_1")
    #expect(source.sourceType == "document")
    #expect(source.mediaType == "application/pdf")
    #expect(source.filename == "report.pdf")
    #expect(source.providerMetadata["search"]?["rank"]?.intValue == 1)

    guard case let .custom(custom, customMetadata) = result.content[4] else {
        Issue.record("Expected ordered custom part")
        return
    }
    #expect(custom == ["kind": "openai.compaction"])
    #expect(customMetadata["openai"]?["itemId"]?.stringValue == "cmp_1")

    guard case let .toolCall(toolCall) = result.content[5] else {
        Issue.record("Expected ordered tool call part")
        return
    }
    #expect(toolCall.id == "call_1")
    #expect(toolCall.name == "lookup")
    #expect(toolCall.arguments == #"{"city":"Tokyo"}"#)
    #expect(toolCall.providerExecuted)
    #expect(toolCall.dynamic)
    #expect(toolCall.providerMetadata["gateway"]?["trace"]?.stringValue == "call")

    guard case let .toolResult(toolResult) = result.content[6] else {
        Issue.record("Expected ordered tool result part")
        return
    }
    #expect(toolResult.toolCallID == "call_1")
    #expect(toolResult.toolName == "lookup")
    #expect(toolResult.result["temperature"]?.intValue == 29)
    #expect(toolResult.preliminary)
    #expect(toolResult.dynamic)
    #expect(toolResult.providerExecuted)
    #expect(toolResult.providerMetadata["gateway"]?["trace"]?.stringValue == "result")

    guard case let .toolApprovalRequest(approvalRequest) = result.content[7] else {
        Issue.record("Expected ordered tool approval request")
        return
    }
    #expect(approvalRequest.id == "approval_1")
    #expect(approvalRequest.toolCallID == "call_1")
    #expect(approvalRequest.toolName == "lookup")
    #expect(approvalRequest.arguments == #"{"city":"Tokyo"}"#)
    #expect(approvalRequest.providerMetadata["gateway"]?["trace"]?.stringValue == "approval")

    guard case let .reasoningFile(reasoningFile) = result.content[8] else {
        Issue.record("Expected ordered reasoning file part")
        return
    }
    #expect(reasoningFile.mediaType == "application/json")
    #expect(reasoningFile.url == "https://cdn.example.com/reasoning.json")
    #expect(reasoningFile.providerMetadata["openai"]?["containerId"]?.stringValue == "container_1")

    guard case let .toolApprovalResponse(approvalResponse) = result.content[9] else {
        Issue.record("Expected ordered tool approval response")
        return
    }
    #expect(approvalResponse.id == "approval_1")
    #expect(!approvalResponse.approved)
    #expect(approvalResponse.reason == "not now")
    #expect(approvalResponse.providerExecuted)
    #expect(approvalResponse.providerMetadata["gateway"]?["trace"]?.stringValue == "approval-response")

    guard case let .text(secondText, secondTextMetadata) = result.content[10] else {
        Issue.record("Expected second ordered text part")
        return
    }
    #expect(secondText == " second")
    #expect(secondTextMetadata["openai"]?["itemId"]?.stringValue == "msg_2")

    #expect(result.files == [file])
    #expect(result.sources == [source])
    #expect(result.toolCalls == [toolCall])
    #expect(result.toolResults == [toolResult])
    #expect(result.toolApprovalRequests == [approvalRequest])
    #expect(result.toolApprovalResponses == [approvalResponse])
}

@Test func gatewayTakoSearchBuildsPublishedProviderToolConfiguration() {
    let tool = GatewayTools.takoSearch(GatewayTakoSearchConfig(
        effort: "deep",
        dataSource: GatewayTakoDataSourceConfig(
            count: 4,
            includeContents: true,
            mode: "inline",
            contentFormat: "json_records",
            maxRows: 50,
            nodeIDs: ["metric:revenue"],
            strict: true
        ),
        webSource: GatewayTakoWebSourceConfig(
            count: 5,
            includeContents: true,
            category: "finance",
            includeDomains: ["sec.gov"],
            snippetMaxCharacters: 800,
            highlights: false,
            articleContentMaxCharacters: 4_000,
            publishedAfter: "2026-01-01"
        ),
        latitude: 35.6762,
        longitude: 139.6503,
        countryCode: "JP",
        locale: "en-US",
        timezone: "Asia/Tokyo",
        imageDarkMode: true,
        forceRefresh: true,
        includeRelated: 3
    ))

    #expect(tool["type"]?.stringValue == "provider")
    #expect(tool["id"]?.stringValue == "gateway.tako_search")
    #expect(tool["name"]?.stringValue == "tako_search")
    #expect(tool["args"]?["effort"]?.stringValue == "deep")
    #expect(tool["args"]?["sources"]?["data"]?["nodeIds"]?[0]?.stringValue == "metric:revenue")
    #expect(tool["args"]?["sources"]?["data"]?["contentFormat"]?.stringValue == "json_records")
    #expect(tool["args"]?["sources"]?["web"]?["snippetMaxChars"]?.intValue == 800)
    #expect(tool["args"]?["sources"]?["web"]?["publishedAfter"]?.stringValue == "2026-01-01")
    #expect(tool["args"]?["location"]?["latitude"]?.doubleValue == 35.6762)
    #expect(tool["args"]?["countryCode"]?.stringValue == "JP")
    #expect(tool["args"]?["outputSettings"]?["imageDarkMode"]?.boolValue == true)
    #expect(tool["args"]?["outputSettings"]?["forceRefresh"]?.boolValue == true)
    #expect(tool["args"]?["includeRelated"]?.intValue == 3)
}

@Test func gatewayAsyncVideoMapsWebhookStartCompletedAndCancelledOperations() async throws {
    let transport = RecordingTransport(responses: [
        jsonResponse("""
        {"operation":{"gatewayJobId":"job_123"},"warnings":[{"type":"other","message":"queued"}],"providerMetadata":{"gateway":{"asyncJob":{"jobId":"job_123","status":"queued"}}}}
        """, headers: ["x-start": "accepted"]),
        jsonResponse("""
        {"status":"completed","videos":[{"type":"url","url":"https://cdn.example.com/video.mp4","mediaType":"video/mp4"},{"type":"base64","data":"YmFzZTY0","mediaType":"video/mp4"}],"warnings":[{"type":"other","message":"complete"}],"providerMetadata":{"gateway":{"asyncJob":{"jobId":"job_123","status":"completed"}}}}
        """, headers: ["x-status": "complete"]),
        jsonResponse("""
        {"status":"cancelled","providerMetadata":{"gateway":{"asyncJob":{"jobId":"job_123","status":"cancelled"}}}}
        """)
    ])
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try #require(try provider.videoModel("bytedance/seedance-2.0") as? any AsyncVideoModel)

    #expect(model.maxVideosPerCall == Int.max)
    #expect(model.supportsVideoGenerationWebhooks)
    let registration = try await model.handleVideoGenerationWebhookOption {
        VideoGenerationWebhookRegistration(url: "https://example.com/hook") { _ in
            VideoGenerationOperationWebhook(
                headers: ["x-ai-gateway-signature": "t=1,v1=abc"],
                body: ["type": "video.generation.completed"]
            )
        }
    }
    #expect(registration.url == "https://example.com/hook")

    let started = try await model.startVideoGeneration(VideoGenerationOperationStartRequest(
        request: VideoGenerationRequest(
            prompt: "A beautiful sunset over mountains",
            aspectRatio: "16:9",
            durationSeconds: 5,
            resolution: "1280x720",
            fps: 24,
            generateAudio: true,
            seed: 123,
            count: 1,
            providerOptions: ["gateway": ["tags": ["async"]]],
            headers: ["idempotency-key": "aisdk_vid_abc123"]
        ),
        webhookURL: registration.url
    ))
    #expect(started.operation == ["gatewayJobId": "job_123"])
    #expect(started.warnings == [AIWarning(type: "other", message: "queued")])
    #expect(started.providerMetadata["gateway"]?["asyncJob"]?["status"]?.stringValue == "queued")
    #expect(started.responseMetadata.headers["x-start"] == "accepted")

    let completed = try await model.videoGenerationStatus(VideoGenerationOperationStatusRequest(
        operation: started.operation,
        headers: ["x-poll": "poll-value"]
    ))
    guard case let .completed(result) = completed else {
        Issue.record("Expected completed Gateway video operation")
        return
    }
    #expect(result.urls == ["https://cdn.example.com/video.mp4"])
    #expect(result.base64Videos == ["YmFzZTY0"])
    #expect(result.operationID == "job_123")
    #expect(result.mediaType == "video/mp4")
    #expect(result.warnings == [AIWarning(type: "other", message: "complete")])
    #expect(result.responseMetadata.headers["x-status"] == "complete")

    let cancelled = try await model.videoGenerationStatus(VideoGenerationOperationStatusRequest(operation: started.operation))
    guard case let .failed(message, metadata, _) = cancelled else {
        Issue.record("Expected cancelled Gateway operation to map to terminal failure")
        return
    }
    #expect(message == "Video generation was cancelled.")
    #expect(metadata["gateway"]?["asyncJob"]?["status"]?.stringValue == "cancelled")

    let requests = await transport.requests()
    #expect(requests.map(\.url.absoluteString) == [
        "https://ai-gateway.vercel.sh/v4/ai/video-model/start",
        "https://ai-gateway.vercel.sh/v4/ai/video-model/status",
        "https://ai-gateway.vercel.sh/v4/ai/video-model/status"
    ])
    let startBody = try decodeJSONBody(try #require(requests[0].body))
    #expect(startBody["callbackUrl"]?.stringValue == "https://example.com/hook")
    #expect(startBody["duration"]?.doubleValue == 5)
    #expect(startBody["n"]?.intValue == 1)
    #expect(requests[0].headers["idempotency-key"] == "aisdk_vid_abc123")
    #expect(requests[0].headers["ai-video-model-specification-version"] == "4")
    #expect(requests[0].headers["ai-model-id"] == "bytedance/seedance-2.0")
    #expect(requests[1].headers["x-poll"] == "poll-value")
}

private actor GatewayBatchChunkTransport: AIStreamingTransport {
    private let chunks: [Data]
    private var recordedRequests: [AIHTTPRequest] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func requests() -> [AIHTTPRequest] { recordedRequests }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        recordedRequests.append(request)
        return AIHTTPResponse(statusCode: 500)
    }

    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse {
        recordedRequests.append(request)
        let chunks = chunks
        return AIHTTPStreamResponse(
            statusCode: 200,
            headers: ["content-type": "application/x-ndjson"],
            body: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }
}
