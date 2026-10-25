import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


private let gatewayTranscriptionStartFrameType =
    "transcription-stream.start"
private let gatewayTranscriptionAudioDoneFrameType =
    "transcription-stream.audio-done"
private let gatewayTranscriptionSubprotocol =
    "ai-gateway-transcription.v1"
private let gatewayAuthSubprotocolPrefix = "ai-gateway-auth."
private let gatewayTeamSubprotocolPrefix = "ai-gateway-team."
private let gatewayMaximumAudioFrameBytes = 64 * 1_024

extension GatewayTranscriptionModel {
    public func stream(
        _ request: StreamingTranscriptionRequest
    ) async throws -> StreamingTranscriptionResult {
        try request.abortSignal?.throwIfAborted()

        let startFrame = gatewayTranscriptionStartFrame(request)
        let headers = config.headers
            .mergingHeaders(request.headers)
            .mergingHeaders([
                "ai-transcription-model-specification-version": "4",
                "ai-model-id": modelID
            ])
        let connection: any AIDuplexWebSocketConnection
        do {
            connection = try await webSocketTransport.connect(
                AIDuplexWebSocketRequest(
                    url: try gatewayTranscriptionWebSocketURL(
                        baseURL: config.baseURL,
                        modelID: modelID
                    ),
                    headers: headers,
                    protocols: gatewayTranscriptionProtocols(headers: headers),
                    abortSignal: request.abortSignal
                )
            )
        } catch {
            request.audio.cancelFromConsumer()
            throw gatewayTranscriptionConnectionError(error)
        }

        let session = GatewayStreamingTranscriptionSession(
            connection: connection,
            audio: request.audio,
            abortSignal: request.abortSignal,
            startFrame: startFrame
        )
        return StreamingTranscriptionResult(
            stream: session.makeStream(),
            requestMetadata: AIRequestMetadata(
                body: startFrame,
                headers: request.headers
            ),
            responseMetadata: AIResponseMetadata(
                timestamp: Date(),
                modelID: modelID
            ),
            cancel: { session.cancel() }
        )
    }
}


func gatewayTranscriptionWebSocketURL(
    baseURL: String,
    modelID: String
) throws -> URL {
    guard var components = URLComponents(string: baseURL) else {
        throw AIError.invalidURL(baseURL)
    }
    switch components.scheme?.lowercased() {
    case "https":
        components.scheme = "wss"
    case "http":
        components.scheme = "ws"
    case "ws", "wss":
        break
    default:
        throw AIError.invalidURL(baseURL)
    }

    let path = components.path.hasSuffix("/")
        ? String(components.path.dropLast())
        : components.path
    components.path = "\(path)/transcription-model"
    var allowedModelCharacters = CharacterSet.urlQueryAllowed
    allowedModelCharacters.remove(charactersIn: "/?&=+")
    guard let encodedModelID = modelID.addingPercentEncoding(
        withAllowedCharacters: allowedModelCharacters
    ) else {
        throw AIError.invalidURL(modelID)
    }
    components.percentEncodedQuery = "ai-model-id=\(encodedModelID)"
    guard let url = components.url else {
        throw AIError.invalidURL(baseURL)
    }
    return url
}

private func gatewayTranscriptionStartFrame(
    _ request: StreamingTranscriptionRequest
) -> JSONValue {
    var format: [String: JSONValue] = [
        "type": .string(request.inputAudioFormat.mediaType)
    ]
    if let sampleRate = request.inputAudioFormat.sampleRate {
        format["rate"] = .number(Double(sampleRate))
    }

    var frame: [String: JSONValue] = [
        "type": .string(gatewayTranscriptionStartFrameType),
        "inputAudioFormat": .object(format)
    ]
    if !request.providerOptions.isEmpty {
        frame["providerOptions"] = .object(request.providerOptions)
    }
    if request.includeRawChunks {
        frame["includeRawChunks"] = .bool(true)
    }
    return .object(frame)
}

private func gatewayTranscriptionProtocols(
    headers: [String: String]
) -> [String] {
    let normalized = normalizeHeaders(headers)
    guard let authorization = normalized["authorization"],
          authorization.hasPrefix("Bearer ") else {
        return [gatewayTranscriptionSubprotocol]
    }

    let token = String(authorization.dropFirst("Bearer ".count))
    var protocols = [
        gatewayTranscriptionSubprotocol,
        "\(gatewayAuthSubprotocolPrefix)\(token)"
    ]
    if let team = normalized["x-vercel-ai-gateway-team"], !team.isEmpty {
        protocols.append(
            "\(gatewayTeamSubprotocolPrefix)\(gatewayBase64URL(team))"
        )
    }
    return protocols
}

private func gatewayBase64URL(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private final class GatewayStreamingTranscriptionSession:
    @unchecked Sendable {
    private typealias Continuation =
        AsyncThrowingStream<StreamingTranscriptionPart, Error>.Continuation

    private let connection: any AIDuplexWebSocketConnection
    private let audio: AIStreamingAudioInput
    private let abortSignal: AIAbortSignal?
    private let startFrame: JSONValue

    private let lock = NSLock()
    private var continuation: Continuation?
    private var eventTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var abortRegistration: AIAbortHandlerRegistration?
    private var started = false
    private var completed = false
    private var audioStopped = false
    private var lastServerError: JSONValue?

    init(
        connection: any AIDuplexWebSocketConnection,
        audio: AIStreamingAudioInput,
        abortSignal: AIAbortSignal?,
        startFrame: JSONValue
    ) {
        self.connection = connection
        self.audio = audio
        self.abortSignal = abortSignal
        self.startFrame = startFrame
    }

    func makeStream()
        -> AsyncThrowingStream<StreamingTranscriptionPart, Error> {
        AsyncThrowingStream { continuation in
            start(continuation: continuation)
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    self?.cancel()
                }
            }
        }
    }

    func cancel() {
        complete(throwing: nil, closeCode: 1_000)
    }

    private func start(continuation: Continuation) {
        lock.lock()
        guard !started else {
            lock.unlock()
            continuation.finish(throwing: AIError.invalidArgument(
                argument: "stream",
                message: "A streaming transcription result can only be consumed once."
            ))
            return
        }
        started = true
        self.continuation = continuation
        lock.unlock()

        let registration = abortSignal?.addAbortHandler {
            [weak self, weak signal = abortSignal] reason in
            self?.complete(
                throwing: AIAbortError(
                    reason: reason,
                    reasonName: signal?.reasonName
                ),
                closeCode: 1_000
            )
        }
        setAbortRegistration(registration)

        let task = Task { [weak self] in
            guard let self else { return }
            await consumeEvents()
        }
        setEventTask(task)
    }

    private func consumeEvents() async {
        do {
            for try await event in connection.events {
                if isCompleted { return }
                switch event {
                case .opened:
                    do {
                        try await connection.send(
                            text: try gatewayJSONString(startFrame)
                        )
                        startSendingAudio()
                    } catch {
                        complete(
                            throwing: gatewayTranscriptionConnectionError(error),
                            closeCode: 1_000
                        )
                        return
                    }

                case let .message(.text(text)):
                    guard let raw = try? secureJSONParse(text),
                          let part = parseGatewayTranscriptionStreamPart(raw)
                    else {
                        continue
                    }

                    if case .error = part {
                        rememberServerError(raw["error"])
                        yield(part)
                        stopSendingAudio()
                        continue
                    }
                    if case .finish = part {
                        yield(part)
                        complete(throwing: nil, closeCode: 1_000)
                        return
                    }
                    yield(part)

                case .message(.binary):
                    continue

                case let .closed(metadata):
                    if let serverError = serverError {
                        complete(
                            throwing: gatewayErrorFromStreamPart(serverError),
                            closeCode: nil
                        )
                    } else {
                        complete(
                            throwing: GatewayError(
                                type: .internalServerError,
                                message: "AI Gateway transcription stream closed before a finish part was received",
                                statusCode: 500,
                                response: .object([
                                    "closeCode": .number(Double(metadata.code)),
                                    "closeReason": metadata.reason.map(JSONValue.string) ?? .null
                                ])
                            ),
                            closeCode: nil
                        )
                    }
                    return
                }
            }

            if !isCompleted {
                complete(
                    throwing: GatewayError(
                        type: .internalServerError,
                        message: "AI Gateway transcription stream closed before a finish part was received",
                        statusCode: 500
                    ),
                    closeCode: nil
                )
            }
        } catch {
            if let abortSignal, abortSignal.isAborted {
                complete(
                    throwing: AIAbortError(
                        reason: abortSignal.reason,
                        reasonName: abortSignal.reasonName
                    ),
                    closeCode: 1_000
                )
            } else if !(error is CancellationError), !isCompleted {
                complete(
                    throwing: gatewayTranscriptionConnectionError(error),
                    closeCode: 1_000
                )
            }
        }
    }

    private func startSendingAudio() {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in audio {
                    if isCompletedOrAudioStopped { return }
                    var offset = 0
                    while offset < chunk.count {
                        if isCompletedOrAudioStopped { return }
                        let end = min(
                            offset + gatewayMaximumAudioFrameBytes,
                            chunk.count
                        )
                        try await connection.send(
                            binary: chunk.subdata(in: offset..<end)
                        )
                        offset = end
                    }
                }
                if !isCompletedOrAudioStopped {
                    try await connection.send(text: gatewayAudioDoneFrame)
                }
            } catch {
                if !isCompletedOrAudioStopped,
                   !(error is CancellationError) {
                    complete(
                        throwing: gatewayTranscriptionConnectionError(error),
                        closeCode: 1_000
                    )
                }
            }
        }
        setAudioTask(task)
    }

    private func stopSendingAudio() {
        lock.lock()
        guard !audioStopped else {
            lock.unlock()
            return
        }
        audioStopped = true
        let task = audioTask
        audioTask = nil
        lock.unlock()

        task?.cancel()
        audio.cancelFromConsumer()
    }

    private var serverError: JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return lastServerError
    }

    private func rememberServerError(_ error: JSONValue?) {
        lock.lock()
        lastServerError = error ?? .null
        lock.unlock()
    }

    private var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    private var isCompletedOrAudioStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed || audioStopped
    }

    private func yield(_ part: StreamingTranscriptionPart) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        continuation.yield(part)
        lock.unlock()
    }

    private func complete(throwing error: Error?, closeCode: Int?) {
        let resources = takeResources()
        guard resources.didComplete else { return }

        if let error {
            resources.continuation?.finish(throwing: error)
        } else {
            resources.continuation?.finish()
        }
        resources.abortRegistration?.cancel()
        resources.eventTask?.cancel()
        resources.audioTask?.cancel()
        audio.cancelFromConsumer()
        if let closeCode {
            Task { [connection] in
                await connection.close(code: closeCode, reason: nil)
            }
        }
    }

    private func setAbortRegistration(
        _ registration: AIAbortHandlerRegistration?
    ) {
        guard let registration else { return }
        lock.lock()
        if completed {
            lock.unlock()
            registration.cancel()
            return
        }
        abortRegistration = registration
        lock.unlock()
    }

    private func setEventTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
            return
        }
        eventTask = task
        lock.unlock()
    }

    private func setAudioTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completed || audioStopped {
            lock.unlock()
            task.cancel()
            return
        }
        audioTask = task
        lock.unlock()
    }

    private func takeResources() -> (
        didComplete: Bool,
        continuation: Continuation?,
        abortRegistration: AIAbortHandlerRegistration?,
        eventTask: Task<Void, Never>?,
        audioTask: Task<Void, Never>?
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return (false, nil, nil, nil, nil)
        }
        completed = true
        audioStopped = true
        let resources = (
            true,
            continuation,
            abortRegistration,
            eventTask,
            audioTask
        )
        continuation = nil
        abortRegistration = nil
        eventTask = nil
        audioTask = nil
        lock.unlock()
        return resources
    }
}

private var gatewayAudioDoneFrame: String {
    #"{"type":"transcription-stream.audio-done"}"#
}

private func gatewayJSONString(_ value: JSONValue) throws -> String {
    let data = try encodeJSONBody(value)
    guard let text = String(data: data, encoding: .utf8) else {
        throw AIError.invalidResponse(
            provider: "gateway",
            message: "Gateway transcription stream frame could not be encoded."
        )
    }
    return text
}

private func parseGatewayTranscriptionStreamPart(
    _ raw: JSONValue
) -> StreamingTranscriptionPart? {
    guard raw.objectValue != nil, let type = raw["type"]?.stringValue else {
        return nil
    }
    switch type {
    case "stream-start":
        guard let values = raw["warnings"]?.arrayValue,
              values.allSatisfy({ $0.objectValue != nil && $0["type"]?.stringValue != nil })
        else {
            return nil
        }
        return .streamStart(warnings: values.map(gatewayStreamWarning))

    case "transcript-delta":
        guard let delta = raw["delta"]?.stringValue,
              gatewayOptionalStringIsValid(raw["id"]),
              let metadata = gatewayStreamProviderMetadata(raw["providerMetadata"])
        else {
            return nil
        }
        return .transcriptDelta(
            id: raw["id"]?.stringValue,
            delta: delta,
            providerMetadata: metadata
        )

    case "transcript-partial":
        guard let text = raw["text"]?.stringValue,
              gatewayOptionalStringIsValid(raw["id"]),
              gatewayOptionalNumberIsValid(raw["startSecond"]),
              gatewayOptionalNumberIsValid(raw["durationInSeconds"]),
              gatewayOptionalIntegerIsValid(raw["channelIndex"]),
              let metadata = gatewayStreamProviderMetadata(raw["providerMetadata"])
        else {
            return nil
        }
        return .transcriptPartial(
            id: raw["id"]?.stringValue,
            text: text,
            startSecond: raw["startSecond"]?.doubleValue,
            durationInSeconds: raw["durationInSeconds"]?.doubleValue,
            channelIndex: raw["channelIndex"]?.intValue,
            providerMetadata: metadata
        )

    case "transcript-final":
        guard let text = raw["text"]?.stringValue,
              gatewayOptionalStringIsValid(raw["id"]),
              gatewayOptionalNumberIsValid(raw["startSecond"]),
              gatewayOptionalNumberIsValid(raw["endSecond"]),
              gatewayOptionalIntegerIsValid(raw["channelIndex"]),
              let metadata = gatewayStreamProviderMetadata(raw["providerMetadata"])
        else {
            return nil
        }
        return .transcriptFinal(
            id: raw["id"]?.stringValue,
            text: text,
            startSecond: raw["startSecond"]?.doubleValue,
            endSecond: raw["endSecond"]?.doubleValue,
            channelIndex: raw["channelIndex"]?.intValue,
            providerMetadata: metadata
        )

    case "response-metadata":
        guard gatewayOptionalStringIsValid(raw["modelId"]),
              let headers = gatewayStreamHeaders(raw["headers"]),
              let timestamp = gatewayStreamTimestamp(raw["timestamp"])
        else {
            return nil
        }
        return .responseMetadata(AIResponseMetadata(
            timestamp: timestamp,
            modelID: raw["modelId"]?.stringValue,
            headers: headers
        ))

    case "finish":
        guard let text = raw["text"]?.stringValue,
              let segmentValues = raw["segments"]?.arrayValue,
              let segments = gatewayStreamSegments(segmentValues),
              gatewayOptionalStringIsValid(raw["language"]),
              gatewayOptionalNumberIsValid(raw["durationInSeconds"]),
              raw["usage"] == nil || raw["usage"]?.objectValue != nil,
              let metadata = gatewayStreamProviderMetadata(raw["providerMetadata"])
        else {
            return nil
        }
        return .finish(StreamingTranscriptionFinish(
            text: text,
            segments: segments,
            language: raw["language"]?.stringValue,
            durationInSeconds: raw["durationInSeconds"]?.doubleValue,
            providerMetadata: metadata,
            usage: raw["usage"]?.objectValue
        ))

    case "raw":
        guard let rawValue = raw["rawValue"] else { return nil }
        return .raw(rawValue)

    case "error":
        guard let error = raw["error"] else { return nil }
        return .error(
            message: gatewayStreamErrorMessage(error),
            rawValue: error
        )

    default:
        return nil
    }
}

private func gatewayStreamWarning(_ raw: JSONValue) -> AIWarning {
    AIWarning(
        type: raw["type"]?.stringValue ?? "other",
        feature: raw["feature"]?.stringValue,
        setting: raw["setting"]?.stringValue,
        message: raw["message"]?.stringValue ?? raw["details"]?.stringValue
    )
}

private func gatewayStreamProviderMetadata(
    _ value: JSONValue?
) -> [String: JSONValue]? {
    guard let value else { return [:] }
    return value.objectValue
}

private func gatewayStreamHeaders(
    _ value: JSONValue?
) -> [String: String]? {
    guard let value else { return [:] }
    guard let object = value.objectValue else { return nil }
    return object.compactMapValues(\.stringValue)
}

private func gatewayOptionalStringIsValid(_ value: JSONValue?) -> Bool {
    value == nil || value?.stringValue != nil
}

private func gatewayOptionalNumberIsValid(_ value: JSONValue?) -> Bool {
    value == nil || value?.doubleValue != nil
}

private func gatewayOptionalIntegerIsValid(_ value: JSONValue?) -> Bool {
    value == nil || value?.intValue != nil
}

private func gatewayStreamTimestamp(_ value: JSONValue?) -> Date?? {
    guard let value, value != .null else { return .some(nil) }
    guard let text = value.stringValue else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = fractional.date(from: text)
        ?? ISO8601DateFormatter().date(from: text) else {
        return nil
    }
    return .some(date)
}

private func gatewayStreamSegments(
    _ values: [JSONValue]
) -> [TranscriptionSegment]? {
    var segments: [TranscriptionSegment] = []
    segments.reserveCapacity(values.count)
    for value in values {
        guard let text = value["text"]?.stringValue,
              let start = value["startSecond"]?.doubleValue,
              let end = value["endSecond"]?.doubleValue else {
            return nil
        }
        segments.append(TranscriptionSegment(
            text: text,
            startSecond: start,
            endSecond: end
        ))
    }
    return segments
}

private func gatewayStreamErrorMessage(_ error: JSONValue) -> String {
    if let message = error["message"]?.stringValue {
        return message
    }
    if let message = error.stringValue {
        return message
    }
    return (try? gatewayJSONString(error)) ?? String(describing: error)
}

private func gatewayErrorFromStreamPart(_ error: JSONValue) -> GatewayError {
    let rawType = error["type"]?.stringValue
    let mapped: (GatewayErrorType, Int)
    switch rawType {
    case "authentication_error":
        mapped = (.authenticationError, 401)
    case "failed_dependency":
        mapped = (.failedDependency, 424)
    case "forbidden":
        mapped = (.forbidden, 403)
    case "invalid_request_error":
        mapped = (.invalidRequestError, 400)
    case "model_not_found":
        mapped = (.modelNotFound, 404)
    case "not_found":
        mapped = (.notFound, 404)
    case "rate_limit_exceeded":
        mapped = (.rateLimitExceeded, 429)
    case "internal_server_error":
        mapped = (.internalServerError, 500)
    default:
        mapped = (.internalServerError, 500)
    }
    return GatewayError(
        type: mapped.0,
        message: gatewayStreamErrorMessage(error),
        statusCode: mapped.1,
        response: .object(["error": error])
    )
}

private func gatewayTranscriptionConnectionError(_ error: Error) -> Error {
    if error is AIAbortError || error is GatewayError {
        return error
    }
    return GatewayError(
        type: .internalServerError,
        message: "Connection error on AI Gateway transcription stream: \(error)",
        statusCode: 500
    )
}