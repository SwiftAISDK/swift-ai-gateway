@testable import SwiftAIGateway
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func gatewayExperimentalTranscriptionFactoryCreatesModelAndMintsBoundToken() async throws {
    let transport = RecordingTransport(response: jsonResponse(
        #"{"token":"vcst_minted","expiresAt":1700000060}"#
    ))
    let webSocket = GatewayTranscriptionTestWebSocketTransport()
    let provider = try AIProviders.gateway(
        configuration: GatewayProviderSettings(
            apiKey: "vck_test-token",
            transport: transport
        ),
        webSocketTransport: webSocket
    )

    let model = provider.experimentalTranscription(
        "openai/gpt-realtime-whisper"
    )
    #expect(model.providerID == "gateway")
    #expect(model.modelID == "openai/gpt-realtime-whisper")

    let token = try await provider.experimentalTranscription.getToken(.init(
        model: "openai/gpt-realtime-whisper",
        expiresAfterSeconds: 120
    ))
    #expect(token == GatewayTranscriptionFactoryGetTokenResult(
        token: "vcst_minted",
        url: "wss://ai-gateway.vercel.sh/v4/ai/transcription-model?ai-model-id=openai%2Fgpt-realtime-whisper",
        expiresAt: 1_700_000_060
    ))

    let request = try #require(await transport.requests().first)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString == "https://ai-gateway.vercel.sh/v1/realtime/client-secrets")
    #expect(gatewayTranscriptionTestHeader(request, "authorization") == "Bearer vck_test-token")
    #expect(gatewayTranscriptionTestHeader(request, "content-type") == "application/json")
    #expect(try gatewayTranscriptionTestBody(request) == .object([
        "model": .string("openai/gpt-realtime-whisper"),
        "routeKind": .string("transcription"),
        "expiresIn": .number(120)
    ]))
}

@Test func gatewayStreamingTranscriptionUsesSharedEnvelopeAndRelaysParts() async throws {
    let webSocket = GatewayTranscriptionTestWebSocketTransport()
    let provider = try AIProviders.gateway(
        configuration: GatewayProviderSettings(
            apiKey: "test-token",
            baseURL: "https://api.test.com/v4/ai",
            headers: ["Custom-Provider": "provider-value"],
            transport: RecordingTransport(response: jsonResponse("{}"))
        ),
        teamIDOrSlug: "my-team",
        webSocketTransport: webSocket
    )
    let model = try provider.streamingTranscription(
        "openai/gpt-realtime-whisper"
    )
    let largeChunk = Data(repeating: 7, count: 150 * 1_024)
    let result = try await model.stream(StreamingTranscriptionRequest(
        audio: .chunks([Data([1, 2, 3]), largeChunk]),
        inputAudioFormat: AIStreamingAudioFormat(
            mediaType: "audio/pcm",
            sampleRate: 16_000
        ),
        providerOptions: [
            "openai": .object(["language": .string("en")])
        ],
        headers: ["Custom-Request": "request-value"],
        includeRawChunks: true
    ))

    let partsTask = Task { try await gatewayTranscriptionCollect(result.stream) }
    webSocket.connection.open()
    #expect(await gatewayTranscriptionWait {
        webSocket.connection.sentMessages().count >= 6
    })

    let socketRequest = try #require(webSocket.requests().first)
    #expect(socketRequest.url.absoluteString == "wss://api.test.com/v4/ai/transcription-model?ai-model-id=openai%2Fgpt-realtime-whisper")
    #expect(socketRequest.protocols == [
        "ai-gateway-transcription.v1",
        "ai-gateway-auth.test-token",
        "ai-gateway-team.bXktdGVhbQ"
    ])
    #expect(gatewayTranscriptionTestHeader(socketRequest.headers, "custom-provider") == "provider-value")
    #expect(gatewayTranscriptionTestHeader(socketRequest.headers, "custom-request") == "request-value")
    #expect(gatewayTranscriptionTestHeader(socketRequest.headers, "ai-transcription-model-specification-version") == "4")
    #expect(gatewayTranscriptionTestHeader(socketRequest.headers, "ai-model-id") == "openai/gpt-realtime-whisper")

    let messages = webSocket.connection.sentMessages()
    let startFrame = try gatewayTranscriptionTestJSON(messages[0])
    #expect(startFrame == .object([
        "type": .string("transcription-stream.start"),
        "inputAudioFormat": .object([
            "type": .string("audio/pcm"),
            "rate": .number(16_000)
        ]),
        "providerOptions": .object([
            "openai": .object(["language": .string("en")])
        ]),
        "includeRawChunks": .bool(true)
    ]))
    #expect(result.requestMetadata.body == startFrame)
    #expect(result.responseMetadata.modelID == "openai/gpt-realtime-whisper")
    #expect(result.responseMetadata.timestamp != nil)

    let binarySizes = messages.compactMap { message -> Int? in
        guard case let .binary(data) = message else { return nil }
        return data.count
    }
    #expect(binarySizes == [3, 64 * 1_024, 64 * 1_024, 22 * 1_024])
    #expect(try gatewayTranscriptionTestJSON(messages.last) == .object([
        "type": .string("transcription-stream.audio-done")
    ]))

    webSocket.connection.sendJSON([
        "type": "some-future-part",
        "payload": 42
    ])
    webSocket.connection.sendJSON([
        "type": "stream-start",
        "warnings": [[
            "type": "other",
            "message": "test warning"
        ]]
    ])
    webSocket.connection.sendJSON([
        "type": "transcript-delta",
        "id": "seg-1",
        "delta": "Hel"
    ])
    webSocket.connection.sendJSON([
        "type": "transcript-partial",
        "id": "seg-1",
        "text": "Hel",
        "startSecond": 0,
        "durationInSeconds": 0.5,
        "channelIndex": 0
    ])
    webSocket.connection.sendJSON([
        "type": "transcript-final",
        "id": "seg-1",
        "text": "Hello",
        "startSecond": 0,
        "endSecond": 1,
        "channelIndex": 0,
        "providerMetadata": ["gateway": ["region": "iad1"]]
    ])
    webSocket.connection.sendJSON([
        "type": "raw",
        "rawValue": ["some": "chunk"]
    ])
    webSocket.connection.sendJSON([
        "type": "response-metadata",
        "timestamp": "2026-01-01T00:00:00.000Z",
        "modelId": "openai/gpt-realtime-whisper",
        "headers": ["x-request-id": "request-1"]
    ])
    webSocket.connection.sendJSON([
        "type": "finish",
        "text": "Hello",
        "segments": [[
            "text": "Hello",
            "startSecond": 0,
            "endSecond": 1
        ]],
        "language": "en",
        "durationInSeconds": 1,
        "providerMetadata": ["gateway": ["billed": true]]
    ])

    let parts = try await partsTask.value
    let expectedDate = try #require(ISO8601DateFormatter().date(
        from: "2026-01-01T00:00:00Z"
    ))
    #expect(parts == [
        .streamStart(warnings: [AIWarning(
            type: "other",
            message: "test warning"
        )]),
        .transcriptDelta(id: "seg-1", delta: "Hel"),
        .transcriptPartial(
            id: "seg-1",
            text: "Hel",
            startSecond: 0,
            durationInSeconds: 0.5,
            channelIndex: 0
        ),
        .transcriptFinal(
            id: "seg-1",
            text: "Hello",
            startSecond: 0,
            endSecond: 1,
            channelIndex: 0,
            providerMetadata: [
                "gateway": .object(["region": .string("iad1")])
            ]
        ),
        .raw(.object(["some": .string("chunk")])),
        .responseMetadata(AIResponseMetadata(
            timestamp: expectedDate,
            modelID: "openai/gpt-realtime-whisper",
            headers: ["x-request-id": "request-1"]
        )),
        .finish(StreamingTranscriptionFinish(
            text: "Hello",
            segments: [TranscriptionSegment(
                text: "Hello",
                startSecond: 0,
                endSecond: 1
            )],
            language: "en",
            durationInSeconds: 1,
            providerMetadata: [
                "gateway": .object(["billed": .bool(true)])
            ]
        ))
    ])
    #expect(await gatewayTranscriptionWait {
        webSocket.connection.closeCalls().contains { $0.code == 1_000 }
    })
}

@Test func gatewayStreamingTranscriptionRelaysErrorThenMapsTerminalClose() async throws {
    let webSocket = GatewayTranscriptionTestWebSocketTransport()
    let provider = try AIProviders.gateway(
        configuration: GatewayProviderSettings(
            apiKey: "test-token",
            transport: RecordingTransport(response: jsonResponse("{}"))
        ),
        webSocketTransport: webSocket
    )
    let model = try provider.streamingTranscriptionModel(
        "openai/gpt-realtime-whisper"
    )
    let pipe = AIStreamingAudioInput.makeStream()
    #expect(pipe.writer.send(Data([1, 2, 3])) == .enqueued)
    let result = try await model.stream(StreamingTranscriptionRequest(
        audio: pipe.input,
        inputAudioFormat: AIStreamingAudioFormat(
            mediaType: "audio/pcm",
            sampleRate: 16_000
        )
    ))

    var iterator = result.stream.makeAsyncIterator()
    webSocket.connection.open()
    #expect(await gatewayTranscriptionWait {
        webSocket.connection.sentMessages().count >= 2
    })
    let serverError: JSONValue = [
        "message": "request rejected",
        "type": "rate_limit_exceeded"
    ]
    webSocket.connection.sendJSON([
        "type": "error",
        "error": serverError
    ])
    #expect(try await iterator.next() == .error(
        message: "request rejected",
        rawValue: serverError
    ))
    #expect(await gatewayTranscriptionWait {
        pipe.writer.send(Data([4])) == .terminated
    })
    #expect(!webSocket.connection.sentMessages().contains(
        .text(#"{"type":"transcription-stream.audio-done"}"#)
    ))

    webSocket.connection.serverClose(code: 1_011, reason: "rejected")
    do {
        _ = try await iterator.next()
        Issue.record("Expected the terminal close to throw GatewayError")
    } catch let error as GatewayError {
        #expect(error.type == .rateLimitExceeded)
        #expect(error.statusCode == 429)
        #expect(error.message == "request rejected")
    }
}

@Test func gatewayStreamingTranscriptionMapsNotFoundTerminalError() async throws {
    let webSocket = GatewayTranscriptionTestWebSocketTransport()
    let provider = try AIProviders.gateway(
        configuration: GatewayProviderSettings(
            apiKey: "test-token",
            transport: RecordingTransport(response: jsonResponse("{}"))
        ),
        webSocketTransport: webSocket
    )
    let model = try provider.streamingTranscriptionModel(
        "openai/gpt-realtime-whisper"
    )
    let pipe = AIStreamingAudioInput.makeStream()
    #expect(pipe.writer.send(Data([1, 2, 3])) == .enqueued)
    let result = try await model.stream(StreamingTranscriptionRequest(
        audio: pipe.input,
        inputAudioFormat: AIStreamingAudioFormat(
            mediaType: "audio/pcm",
            sampleRate: 16_000
        )
    ))

    var iterator = result.stream.makeAsyncIterator()
    webSocket.connection.open()
    #expect(await gatewayTranscriptionWait {
        webSocket.connection.sentMessages().count >= 2
    })
    let serverError: JSONValue = [
        "message": "stream not found",
        "type": "not_found"
    ]
    webSocket.connection.sendJSON([
        "type": "error",
        "error": serverError
    ])
    #expect(try await iterator.next() == .error(
        message: "stream not found",
        rawValue: serverError
    ))
    #expect(await gatewayTranscriptionWait {
        pipe.writer.send(Data([4])) == .terminated
    })

    webSocket.connection.serverClose(code: 1_011, reason: "not found")
    do {
        _ = try await iterator.next()
        Issue.record("Expected the terminal close to throw GatewayError")
    } catch let error as GatewayError {
        #expect(error.type == .notFound)
        #expect(error.statusCode == 404)
        #expect(error.upstreamType == "not_found")
        #expect(error.isNotFound)
        #expect(!error.isRetryable)
    }
}

@Test(arguments: [JSONValue.null, JSONValue.number(1), JSONValue.array([JSONValue]())])
func gatewayStreamingTranscriptionIgnoresMalformedUsageAndPreservesNativeUsage(usage: JSONValue) async throws {
    let webSocket = GatewayTranscriptionTestWebSocketTransport()
    let provider = try AIProviders.gateway(configuration: .init(apiKey: "test-token"), webSocketTransport: webSocket)
    let model = try provider.streamingTranscription("openai/gpt-realtime-whisper")
    let result = try await model.stream(.init(audio: .chunks([]), inputAudioFormat: .init(mediaType: "audio/pcm", sampleRate: 16_000)))
    let partsTask = Task { try await gatewayTranscriptionCollect(result.stream) }
    webSocket.connection.open()
    webSocket.connection.sendJSON(["type": "finish", "text": "invalid", "segments": [], "usage": usage])
    webSocket.connection.sendJSON(["type": "finish", "text": "valid", "segments": [], "usage": ["seconds": 1]])
    let parts = try await partsTask.value
    #expect(parts == [.finish(.init(text: "valid", usage: ["seconds": 1]))])
}

private func gatewayTranscriptionCollect(
    _ stream: AsyncThrowingStream<StreamingTranscriptionPart, Error>
) async throws -> [StreamingTranscriptionPart] {
    var parts: [StreamingTranscriptionPart] = []
    for try await part in stream {
        parts.append(part)
    }
    return parts
}

private func gatewayTranscriptionWait(
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func gatewayTranscriptionTestHeader(
    _ request: AIHTTPRequest,
    _ name: String
) -> String? {
    gatewayTranscriptionTestHeader(request.headers, name)
}

private func gatewayTranscriptionTestHeader(
    _ headers: [String: String],
    _ name: String
) -> String? {
    headers.first {
        $0.key.caseInsensitiveCompare(name) == .orderedSame
    }?.value
}

private func gatewayTranscriptionTestBody(
    _ request: AIHTTPRequest
) throws -> JSONValue {
    try decodeJSONBody(try #require(request.body))
}

private func gatewayTranscriptionTestJSON(
    _ message: AIDuplexWebSocketMessage?
) throws -> JSONValue {
    guard case let .text(text) = try #require(message) else {
        throw AIError.invalidArgument(
            argument: "message",
            message: "Expected a text WebSocket frame."
        )
    }
    return try secureJSONParse(text)
}

private final class GatewayTranscriptionTestWebSocketTransport:
    AIDuplexWebSocketTransport,
    @unchecked Sendable {
    let connection = GatewayTranscriptionTestWebSocketConnection()

    private let lock = NSLock()
    private var recordedRequests: [AIDuplexWebSocketRequest] = []

    func connect(
        _ request: AIDuplexWebSocketRequest
    ) async throws -> any AIDuplexWebSocketConnection {
        record(request)
        return connection
    }

    private func record(_ request: AIDuplexWebSocketRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    func requests() -> [AIDuplexWebSocketRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

private final class GatewayTranscriptionTestWebSocketConnection:
    AIDuplexWebSocketConnection,
    @unchecked Sendable {
    let events: AsyncThrowingStream<AIDuplexWebSocketEvent, Error>

    private let continuation:
        AsyncThrowingStream<AIDuplexWebSocketEvent, Error>.Continuation
    private let lock = NSLock()
    private var sent: [AIDuplexWebSocketMessage] = []
    private var closes: [(code: Int, reason: Data?)] = []

    init() {
        let pair = AsyncThrowingStream<AIDuplexWebSocketEvent, Error>
            .makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func send(_ message: AIDuplexWebSocketMessage) async throws {
        record(message)
    }

    func close(code: Int, reason: Data?) async {
        recordClose(code: code, reason: reason)
        continuation.finish()
    }

    private func record(_ message: AIDuplexWebSocketMessage) {
        lock.lock()
        sent.append(message)
        lock.unlock()
    }

    private func recordClose(code: Int, reason: Data?) {
        lock.lock()
        closes.append((code, reason))
        lock.unlock()
    }

    func open() {
        continuation.yield(.opened(protocol: nil))
    }

    func sendJSON(_ value: JSONValue) {
        guard let data = try? encodeJSONBody(value),
              let text = String(data: data, encoding: .utf8) else {
            Issue.record("Could not encode fake Gateway WebSocket JSON")
            return
        }
        continuation.yield(.message(.text(text)))
    }

    func serverClose(code: Int, reason: String? = nil) {
        continuation.yield(.closed(AIDuplexWebSocketCloseMetadata(
            code: code,
            reason: reason
        )))
        continuation.finish()
    }

    func sentMessages() -> [AIDuplexWebSocketMessage] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func closeCalls() -> [(code: Int, reason: Data?)] {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }
}
