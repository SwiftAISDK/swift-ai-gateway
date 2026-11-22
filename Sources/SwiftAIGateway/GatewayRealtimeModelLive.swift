import SwiftAIProvider
import SwiftAITransport

/// A setting or event that Gateway Live cannot send to the service.
public struct GatewayLiveUnsupportedFunctionalityError: Error, Equatable, CustomStringConvertible, Sendable {
    public let functionality: String

    public init(functionality: String) { self.functionality = functionality }
    public var description: String { "Unsupported functionality: \(functionality)" }
}

/// Continuous conversation over the Gateway's normalized Live WebSocket route.
public struct GatewayRealtimeModelLive: AIRealtimeModelV4, AIRealtimeModelV4ValidationHooks {
    public let providerID = "gateway.live"
    public let modelID: String
    public let capabilities: AIRealtimeModelCapabilities? = .init(
        conversation: .continuous,
        transports: [.webSocket],
        connections: [.clientSecretWebSocket, .serverWebSocket],
        startup: .sessionStart,
        finalization: .sessionClose
    )
    private let config: GatewayModelConfiguration

    init(modelID: String, config: GatewayModelConfiguration) {
        self.modelID = modelID
        self.config = config
    }

    public func doCreateClientSecret(
        _ options: AIRealtimeClientSecretOptions
    ) async throws -> AIRealtimeClientSecretResult {
        try options.abortSignal?.throwIfAborted()
        try Task.checkCancellation()
        return try await gatewayRealtimeClientSecret(config: config, modelID: modelID, api: .live, options: options)
    }

    public func getWebSocketConfig(token: String, url: String) -> AIRealtimeWebSocketConfiguration {
        gatewayRealtimeClientWebSocketConfig(config: config, token: token, url: url)
    }

    public func getValidatedWebSocketConfig(token: String, url: String) throws -> AIRealtimeWebSocketConfiguration {
        getWebSocketConfig(token: token, url: url)
    }

    public func getServerWebSocketConfig() throws -> AIRealtimeWebSocketConfiguration {
        .init(url: try websocketURL(), headers: config.headers)
    }

    public func getServerWebSocketConfig(intent: AIRealtimeSessionIntent) throws -> AIRealtimeWebSocketConfiguration {
        try validateIntent(intent)
        return try getServerWebSocketConfig()
    }

    public func getResolvedServerWebSocketConfig() async throws -> AIRealtimeWebSocketConfiguration {
        let url = try websocketURL()
        var client = config.http
        client.dynamicHeaders = nil
        do {
            return .init(url: url, headers: try await client.resolvedHeaders())
        } catch {
            throw gatewayTransportError(error)
        }
    }

    public func getResolvedServerWebSocketConfig(intent: AIRealtimeSessionIntent) async throws -> AIRealtimeWebSocketConfiguration {
        try validateIntent(intent)
        return try await getResolvedServerWebSocketConfig()
    }

    private func websocketURL() throws -> String {
        try gatewayRealtimeWebSocketURL(baseURL: config.baseURL, modelID: modelID, api: .live)
    }

    public func parseServerEvent(_ raw: JSONValue) -> [AIRealtimeServerEvent] {
        guard raw["type"]?.stringValue != nil else {
            return [.error(message: "Invalid AI Gateway Live server event.", code: "invalid_server_event", raw: raw)]
        }
        return GatewayRealtimeModel.normalizedServerEvents(raw, providerPayload: raw["raw"] ?? raw)
    }

    public func serializeClientEvent(_ event: AIRealtimeClientEvent) async throws -> AIRealtimeWireMessage? {
        try await serializeClientEvent(event, intent: .conversation)
    }

    public func serializeClientEvent(
        _ event: AIRealtimeClientEvent,
        intent: AIRealtimeSessionIntent
    ) async throws -> AIRealtimeWireMessage? {
        try validateIntent(intent)
        var fields: [String: JSONValue]
        let eventID: String?
        switch event {
        case let .sessionStart(config, id):
            fields = [
                "type": "session-start",
                "modelId": .string(modelID),
                "config": try buildValidatedSessionConfig(config)
            ]
            eventID = id
        case let .sessionClose(id):
            fields = ["type": "session-close"]
            eventID = id
        case let .inputAudioMute(id):
            fields = ["type": "input-audio-mute"]
            eventID = id
        case let .inputAudioUnmute(id):
            fields = ["type": "input-audio-unmute"]
            eventID = id
        case let .inputAudioAppend(audio):
            fields = ["type": "input-audio-append", "audio": .string(audio)]
            eventID = nil
        case let .inputAudioAppendWithEventID(audio, id):
            fields = ["type": "input-audio-append", "audio": .string(audio)]
            eventID = id
        case let .contextAppend(content, delegationID, id, options):
            try validateGatewayLiveContextOptions(options)
            fields = [
                "type": "context-append",
                "content": .string(content),
                "delegationId": delegationID.map(JSONValue.string) ?? .null
            ]
            fields["providerOptions"] = options.map(JSONValue.object)
            eventID = id
        case .sessionUpdate, .sessionUpdateWithEventID:
            throw unsupportedLiveEvent("session-update")
        case .inputAudioCommit:
            throw unsupportedLiveEvent("input-audio-commit")
        case .inputAudioClear:
            throw unsupportedLiveEvent("input-audio-clear")
        case .conversationItemCreate:
            throw unsupportedLiveEvent("conversation-item-create")
        case .conversationItemTruncate:
            throw unsupportedLiveEvent("conversation-item-truncate")
        case .responseCreate:
            throw unsupportedLiveEvent("response-create")
        case .responseCancel:
            throw unsupportedLiveEvent("response-cancel")
        }
        fields["eventId"] = eventID.map(JSONValue.string)
        return .json(.object(fields))
    }

    public func buildSessionConfig(_ config: AIRealtimeSessionConfiguration) -> JSONValue {
        (try? buildValidatedSessionConfig(config)) ?? [:]
    }

    public func buildSessionConfig(
        _ config: AIRealtimeSessionConfiguration,
        intent: AIRealtimeSessionIntent
    ) throws -> JSONValue {
        try validateIntent(intent)
        return try buildValidatedSessionConfig(config)
    }

    public func buildValidatedSessionConfig(_ config: AIRealtimeSessionConfiguration) throws -> JSONValue {
        let settings = gatewayRealtimeSessionJSON(config)
        let supportedSettings: Set<String> = ["instructions", "voice", "inputAudioFormat", "outputAudioFormat", "providerOptions"]
        if let setting = settings.objectValue?.keys.sorted().first(where: { !supportedSettings.contains($0) }) {
            throw GatewayLiveUnsupportedFunctionalityError(functionality: "AI Gateway Live session setting: \(setting)")
        }
        try validateGatewayLiveSessionOptions(config.providerOptions)
        let input = config.inputAudioFormat
        let output = config.outputAudioFormat
        try validateGatewayLiveAudioFormat(input, argument: "inputAudioFormat")
        try validateGatewayLiveAudioFormat(output, argument: "outputAudioFormat")
        if let input, let output, input != output {
            throw AIError.invalidArgument(
                argument: "outputAudioFormat",
                message: "AI Gateway Live requires the same input and output audio format."
            )
        }
        return settings
    }

    private func validateIntent(_ intent: AIRealtimeSessionIntent) throws {
        guard intent == .conversation else {
            throw AIError.invalidArgument(
                argument: "intent",
                message: "AI Gateway Live does not support the '\(intent.rawValue)' session intent."
            )
        }
    }
}

private func unsupportedLiveEvent(_ type: String) -> GatewayLiveUnsupportedFunctionalityError {
    .init(functionality: "AI Gateway Live client event: \(type)")
}

private func validateGatewayLiveSessionOptions(_ options: [String: JSONValue]?) throws {
    guard let options else { return }
    for (namespace, value) in options {
        guard namespace == "gateway" || namespace == "openai" else {
            throw GatewayLiveUnsupportedFunctionalityError(functionality: "AI Gateway Live provider options namespace: \(namespace)")
        }
        guard let settings = value.objectValue else {
            throw AIError.invalidArgument(argument: "providerOptions.\(namespace)", message: "providerOptions.\(namespace) must be an object.")
        }
        if namespace == "openai" { try validateGatewayOpenAILiveOptions(settings) }
    }
}

private func validateGatewayOpenAILiveOptions(_ options: [String: JSONValue]) throws {
    for (key, value) in options {
        switch key {
        case "delegation":
            guard value == .null || value == ["type": "client"] else {
                throw GatewayLiveUnsupportedFunctionalityError(functionality: "AI Gateway Live delegation other than { type: \"client\" } or null")
            }
        case "input":
            guard let messages = value.arrayValue, messages.count <= 128, messages.allSatisfy(isGatewayLiveInputMessage) else {
                throw AIError.invalidArgument(
                    argument: "providerOptions.openai.input",
                    message: "input must be at most 128 messages, each { type: \"message\", role, content: [{ type, text }] }."
                )
            }
        case "store":
            guard value.boolValue != nil else {
                throw AIError.invalidArgument(argument: "providerOptions.openai.store", message: "store must be a boolean.")
            }
        case "voice":
            guard value.objectValue?.count == 1, let id = value["id"]?.stringValue, !id.isEmpty else {
                throw AIError.invalidArgument(argument: "providerOptions.openai.voice", message: "voice must be { id: string } with a nonempty id.")
            }
        default:
            throw GatewayLiveUnsupportedFunctionalityError(functionality: "AI Gateway Live OpenAI option: \(key)")
        }
    }
}

private func isGatewayLiveInputMessage(_ value: JSONValue) -> Bool {
    guard value.objectValue?.count == 3, value["type"] == "message",
          let content = value["content"]?.arrayValue, content.count == 1,
          let part = content.first, part.objectValue?.count == 2, part["text"]?.stringValue != nil else { return false }
    switch value["role"]?.stringValue {
    case "assistant": return part["type"] == "text" || part["type"] == "output_text"
    case "developer", "user": return part["type"] == "input_text"
    default: return false
    }
}

private func validateGatewayLiveContextOptions(_ options: [String: JSONValue]?) throws {
    guard let options else { return }
    let channels: Set<String> = ["commentary", "instructions", "thinking"]
    guard options.allSatisfy({ namespace, value in
        guard namespace == "openai", let settings = value.objectValue else { return false }
        return settings.allSatisfy { key, setting in
            key == "channel" && setting.stringValue.map(channels.contains) == true
        }
    }) else {
        throw GatewayLiveUnsupportedFunctionalityError(
            functionality: "AI Gateway Live context options other than openai.channel commentary, instructions, or thinking"
        )
    }
}

private func validateGatewayLiveAudioFormat(_ format: AIRealtimeAudioFormat?, argument: String) throws {
    guard let format else { return }
    switch (format.type, format.rate) {
    case ("audio/pcm", 16_000), ("audio/pcm", 24_000), ("audio/pcma", 8_000), ("audio/pcmu", 8_000):
        return
    default:
        let rate = format.rate.map(String.init) ?? "an unspecified"
        throw GatewayLiveUnsupportedFunctionalityError(
            functionality: "AI Gateway Live \(argument) \(format.type) at \(rate) Hz; "
                + "use audio/pcm at 16000 or 24000 Hz, or audio/pcma or audio/pcmu at 8000 Hz"
        )
    }
}
