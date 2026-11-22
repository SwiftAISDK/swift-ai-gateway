import Foundation
import Testing
import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport
@testable import SwiftAIGateway

@Suite struct Weekly20261108GatewayNativeSessionTests {
    @Test func serverConnectionComposesSetupInputUsageAndClosure() async throws {
        let socket = WeeklyRealtimeFixture()
        let model = try GatewayProvider(configuration: .init(apiKey: "key"), teamIDOrSlug: "team_native").realtimeModel("openai/gpt-realtime-2")
        #expect(model.providerID == "gateway.realtime")
        let session = try await AIRealtimeSession.connectServer(model: model, sessionConfiguration: .init(instructions: "native", inputAudioFormat: .init(type: "audio/pcm", rate: 24_000)), webSocketTransport: socket)
        #expect(session.providerID == "gateway.realtime")
        let recorded = WeeklyRealtimeEvents()
        let consumer = Task { for try await event in session { await recorded.record(event) } }
        socket.connection.open()
        try await socket.connection.waitForMessages(1)
        #expect(socket.connection.messages()[0]["type"] == "session-update")
        #expect(socket.connection.messages()[0]["config"]?["instructions"] == "native")
        let acknowledgement: JSONValue = ["type": "session-created", "sessionId": "session"]
        socket.connection.json(acknowledgement)
        try await session.appendAudio(Data([1, 2]))
        try await session.commitAudio()
        try await socket.connection.waitForMessages(3)
        #expect(socket.connection.messages()[1] == ["type": "input-audio-append", "audio": "AQI="])
        #expect(socket.connection.messages()[2] == ["type": "input-audio-commit"])
        let completion: JSONValue = ["type": "response-done", "responseId": "response", "status": "completed", "usage": ["inputTokens": 0, "outputTokens": 2], "raw": ["provider": "wire"]]
        socket.connection.json(completion)
        try await recorded.waitForUsage()
        await session.cancel(reason: "verified")
        try await consumer.value
        let events = await recorded.values
        #expect(events.contains(.server(.sessionCreated(sessionID: "session", raw: acknowledgement))))
        let usage = try #require(events.compactMap { if case let .server(event) = $0 { return event.usage }; return nil }.first)
        #expect(usage.inputTokens == 0 && usage.outputTokens == 2)
        #expect(events.contains(.closed(.init(code: 1000, reason: "verified"))))
        #expect(socket.connection.closes() == [1000])
        let request = try #require(socket.requests().first)
        #expect(normalizeHeaders(request.headers)["authorization"] == "Bearer key")
        #expect(request.headers["x-vercel-ai-gateway-team"] == "team_native")
    }
}

@Suite struct GatewayLiveNativeSessionTests {
    @Test func clientSecretSessionStartsStreamsAndClosesWithFinalUsage() async throws {
        let socket = WeeklyRealtimeFixture()
        let provider = try GatewayProvider(configuration: .init(apiKey: "server-key"), teamIDOrSlug: "team_native")
        let model = provider.experimentalRealtime("openai/gpt-live-1.1")
        let url = "wss://ai-gateway.vercel.sh/v4/ai/live-model?ai-model-id=openai%2Fgpt-live-1.1"
        let audio = AIRealtimeAudioFormat(type: "audio/pcm", rate: 24_000)
        let session = try await AIRealtimeSession.connect(
            model: model,
            clientSecret: .init(token: "vcst_client", url: url, expiresAt: 1_700_000_060),
            sessionConfiguration: .init(instructions: "Be brief.", inputAudioFormat: audio, outputAudioFormat: audio),
            webSocketTransport: socket
        )
        let recorded = WeeklyRealtimeEvents()
        let consumer = Task { for try await event in session { await recorded.record(event) } }
        defer { consumer.cancel() }

        socket.connection.open()
        try await socket.connection.waitForMessages(1)
        #expect(socket.connection.messages()[0] == [
            "type": "session-start", "modelId": "openai/gpt-live-1.1", "config": [
                "instructions": "Be brief.", "inputAudioFormat": ["type": "audio/pcm", "rate": 24000],
                "outputAudioFormat": ["type": "audio/pcm", "rate": 24000]
            ]
        ])
        socket.connection.json(["type": "session-started", "sessionId": "live_1", "delegationMode": "client"])
        try await recorded.waitForSessionStart()
        try await session.appendAudio(Data([1, 2]))
        try await session.appendContext("Checking", delegationID: "d1", eventID: "ctx-1", providerOptions: ["openai": ["channel": "thinking"]])
        try await socket.connection.waitForMessages(3)
        #expect(socket.connection.messages()[1] == ["type": "input-audio-append", "audio": "AQI="])
        #expect(socket.connection.messages()[2] == [
            "type": "context-append", "content": "Checking", "delegationId": "d1", "eventId": "ctx-1", "providerOptions": ["openai": ["channel": "thinking"]]
        ])

        let close = Task { await session.close(eventID: "close-1") }
        try await socket.connection.waitForMessages(4)
        #expect(socket.connection.messages()[3] == ["type": "session-close", "eventId": "close-1"])
        let raw: JSONValue = ["type": "session.closed"]
        socket.connection.json(["type": "session-closed", "sessionId": "live_1", "usage": ["seconds": 14], "reason": "close_requested", "raw": raw])
        await close.value
        try await consumer.value

        let events = await recorded.values
        #expect(events.contains(.server(.sessionClosed(sessionID: "live_1", usage: .init(seconds: 14), reason: "close_requested", raw: raw))))
        #expect(events.contains(.closed(.init(code: 1000))))
        let request = try #require(socket.requests().first)
        #expect(request.url.absoluteString == url)
        #expect(request.headers.isEmpty)
        #expect(request.protocols == GatewayRealtimeAuth.realtimeProtocols(token: "vcst_client", teamIDOrSlug: "team_native"))
    }
}

private final class WeeklyRealtimeFixture: AIDuplexWebSocketTransport, @unchecked Sendable {
    let connection = WeeklyRealtimeConnection()
    private let lock = NSLock()
    private var recorded: [AIDuplexWebSocketRequest] = []
    func connect(_ request: AIDuplexWebSocketRequest) async throws -> any AIDuplexWebSocketConnection { lock.withLock { recorded.append(request) }; return connection }
    func requests() -> [AIDuplexWebSocketRequest] { lock.withLock { recorded } }
}

private final class WeeklyRealtimeConnection: AIDuplexWebSocketConnection, @unchecked Sendable {
    let events: AsyncThrowingStream<AIDuplexWebSocketEvent, Error>
    private let continuation: AsyncThrowingStream<AIDuplexWebSocketEvent, Error>.Continuation
    private let lock = NSLock()
    private var sent: [JSONValue] = []
    private var closed: [Int] = []
    init() { let pair = AsyncThrowingStream<AIDuplexWebSocketEvent, Error>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func open() { continuation.yield(.opened(protocol: nil)) }
    func json(_ value: JSONValue) { continuation.yield(.message(.text(String(decoding: (try? encodeJSONBody(value)) ?? Data(), as: UTF8.self)))) }
    func send(_ message: AIDuplexWebSocketMessage) async throws { if case let .text(text) = message { let value = try secureJSONParse(text); lock.withLock { sent.append(value) } } }
    func close(code: Int, reason: Data?) async { lock.withLock { closed.append(code) }; continuation.finish() }
    func messages() -> [JSONValue] { lock.withLock { sent } }
    func closes() -> [Int] { lock.withLock { closed } }
    func waitForMessages(_ count: Int) async throws {
        for _ in 0..<1000 { if messages().count >= count { return }; try await Task.sleep(nanoseconds: 1_000_000) }
        throw AIError.invalidResponse(provider: "test", message: "Realtime send timeout")
    }
}

private actor WeeklyRealtimeEvents {
    var values: [AIRealtimeSessionEvent] = []
    func record(_ event: AIRealtimeSessionEvent) { values.append(event) }
    func waitForSessionStart() async throws {
        for _ in 0..<1000 {
            if values.contains(where: { if case .server(.sessionStarted) = $0 { return true }; return false }) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw AIError.invalidResponse(provider: "test", message: "Live session-started forwarding timeout")
    }
    func waitForUsage() async throws {
        for _ in 0..<1000 {
            if values.contains(where: { if case let .server(event) = $0 { return event.usage != nil }; return false }) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw AIError.invalidResponse(provider: "test", message: "Realtime usage forwarding timeout")
    }
}
