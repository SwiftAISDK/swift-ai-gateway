@testable import SwiftAIGateway
import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
func weeklySpeechWait(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    for _ in 0..<500 { if predicate() { return true }; try? await Task.sleep(nanoseconds: 2_000_000) }; return predicate()
}
final class WeeklySpeechSocket: AIDuplexWebSocketConnection, @unchecked Sendable {
    let events: AsyncThrowingStream<AIDuplexWebSocketEvent, Error>
    let continuation: AsyncThrowingStream<AIDuplexWebSocketEvent, Error>.Continuation
    private let lock = NSLock(); private var messages: [JSONValue] = []; private var closes = 0
    init() { let pair = AsyncThrowingStream<AIDuplexWebSocketEvent, Error>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func send(_ message: AIDuplexWebSocketMessage) async throws {
        if case let .text(text) = message { let raw = try secureJSONParse(text); lock.withLock { messages.append(raw) } }
    }
    func close(code: Int, reason: Data?) async { lock.withLock { closes += 1 }; continuation.finish() }
    func open() { continuation.yield(.opened(protocol: nil)) }
    func receive(_ value: JSONValue) throws { continuation.yield(.message(.text(String(decoding: try encodeJSONBody(value), as: UTF8.self)))) }
    func closed(_ code: Int = 1000) { continuation.yield(.closed(.init(code: code))); continuation.finish() }
    var sent: [JSONValue] { lock.withLock { messages } }
    var closeCount: Int { lock.withLock { closes } }
}
final class WeeklySpeechSocketTransport: AIDuplexWebSocketTransport, @unchecked Sendable {
    let socket = WeeklySpeechSocket(); private let lock = NSLock(); private var stored: [AIDuplexWebSocketRequest] = []
    func connect(_ request: AIDuplexWebSocketRequest) async throws -> any AIDuplexWebSocketConnection { lock.withLock { stored.append(request) }; return socket }
    var requests: [AIDuplexWebSocketRequest] { lock.withLock { stored } }
}
