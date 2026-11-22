import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

/// Thin codec for the normalized AI SDK realtime route exposed by AI Gateway.
public struct GatewayRealtimeModel: AIRealtimeModelV4, Sendable {
    public let specificationVersion = "v4"
    public let providerID = "gateway.realtime"
    public let modelID: String
    public let capabilities: AIRealtimeModelCapabilities? = .init(conversation: .turnBased, transports: [.webSocket], connections: [.clientSecretWebSocket, .serverWebSocket])
    private let config: GatewayModelConfiguration
    init(modelID: String, config: GatewayModelConfiguration) { self.modelID = modelID; self.config = config }

    public func doCreateClientSecret(_ options: AIRealtimeClientSecretOptions) async throws -> AIRealtimeClientSecretResult {
        try await gatewayRealtimeClientSecret(config: config, modelID: modelID, api: .realtime, options: options)
    }

    public func getWebSocketConfig(token: String, url: String) -> AIRealtimeWebSocketConfiguration {
        gatewayRealtimeClientWebSocketConfig(config: config, token: token, url: url)
    }

    public func getServerWebSocketConfig() throws -> AIRealtimeWebSocketConfiguration {
        .init(url: try websocketURL(), headers: config.headers)
    }

    public func getResolvedServerWebSocketConfig() async throws -> AIRealtimeWebSocketConfiguration {
        .init(url: try websocketURL(), headers: try await config.http.resolvedHeaders())
    }

    private func websocketURL() throws -> String {
        try gatewayRealtimeWebSocketURL(baseURL: config.baseURL, modelID: modelID, api: .realtime)
    }

    public func buildSessionConfig(_ config: AIRealtimeSessionConfiguration) -> JSONValue {
        gatewayRealtimeSessionJSON(config)
    }

    public func serializeClientEvent(_ event: AIRealtimeClientEvent) async throws -> AIRealtimeWireMessage? {
        var value: [String: JSONValue] = [:]
        func eventID(_ id: String?) { value["eventId"] = id.map(JSONValue.string) }
        switch event {
        case let .sessionUpdate(config): value = ["type": "session-update", "config": buildSessionConfig(config)]
        case let .sessionUpdateWithEventID(config, id): value = ["type": "session-update", "config": buildSessionConfig(config)]; eventID(id)
        case let .sessionStart(config, id): value = ["type": "session-start", "config": buildSessionConfig(config)]; eventID(id)
        case let .sessionClose(id): value["type"] = "session-close"; eventID(id)
        case let .inputAudioMute(id): value["type"] = "input-audio-mute"; eventID(id)
        case let .inputAudioUnmute(id): value["type"] = "input-audio-unmute"; eventID(id)
        case let .contextAppend(content, delegation, id, options):
            value = ["type": "context-append", "content": .string(content), "delegationId": delegation.map(JSONValue.string) ?? .null]; value["providerOptions"] = options.map(JSONValue.object); eventID(id)
        case let .inputAudioAppend(audio): value = ["type": "input-audio-append", "audio": .string(audio)]
        case let .inputAudioAppendWithEventID(audio, id): value = ["type": "input-audio-append", "audio": .string(audio)]; eventID(id)
        case .inputAudioCommit: value["type"] = "input-audio-commit"
        case .inputAudioClear: value["type"] = "input-audio-clear"
        case let .conversationItemCreate(item):
            var object: [String: JSONValue]
            switch item {
            case let .textMessage(text): object = ["type": "text-message", "text": .string(text)]
            case let .audioMessage(audio): object = ["type": "audio-message", "audio": .string(audio)]
            case let .functionCallOutput(id, name, output): object = ["type": "function-call-output", "callId": .string(id), "output": .string(output)]; object["name"] = name.map(JSONValue.string)
            }
            value = ["type": "conversation-item-create", "item": .object(object)]
        case let .conversationItemTruncate(id, index, end): value = ["type": "conversation-item-truncate", "itemId": .string(id), "contentIndex": .number(Double(index)), "audioEndMs": .number(Double(end))]
        case let .responseCreate(options):
            value["type"] = "response-create"
            if let options { value["options"] = .object(["modalities": options.modalities.map(JSONValue.array), "instructions": options.instructions.map(JSONValue.string), "metadata": options.metadata.map(JSONValue.object)]) }
        case .responseCancel: value["type"] = "response-cancel"
        }
        return .json(.object(value))
    }

    public func parseServerEvent(_ raw: JSONValue) -> [AIRealtimeServerEvent] {
        Self.normalizedServerEvents(raw, providerPayload: raw)
    }

    static func normalizedServerEvents(_ raw: JSONValue, providerPayload: JSONValue) -> [AIRealtimeServerEvent] {
        func string(_ key: String) -> String { raw[key]?.stringValue ?? "" }
        let response = string("responseId"), item = string("itemId")
        let event: AIRealtimeServerEvent
        switch string("type") {
        case "session-started": event = .sessionStarted(sessionID: string("sessionId"), delegationMode: raw["delegationMode"]?.stringValue.flatMap(AIRealtimeDelegationMode.init(rawValue:)), raw: providerPayload)
        case "session-closed": event = .sessionClosed(sessionID: raw["sessionId"]?.stringValue, usage: .init(seconds: raw["usage"]?["seconds"]?.doubleValue ?? 0), reason: string("reason"), raw: providerPayload)
        case "session-usage": event = .sessionUsage(usage: .init(seconds: raw["usage"]?["seconds"]?.doubleValue ?? 0), contextWindowUsageRatio: raw["contextWindowUsageRatio"]?.doubleValue, raw: providerPayload)
        case "audio-chunk": event = .audioChunk(delta: string("delta"), raw: providerPayload)
        case "transcript-fragment": event = .transcriptFragment(speaker: raw["speaker"]?.stringValue.flatMap(AIRealtimeTranscriptSpeaker.init(rawValue:)) ?? .user, delta: string("delta"), startMilliseconds: raw["startMs"]?.doubleValue ?? 0, endMilliseconds: raw["endMs"]?.doubleValue ?? 0, raw: providerPayload)
        case "delegation-created": event = .delegationCreated(delegationID: string("delegationId"), target: raw["target"]?.stringValue.flatMap(AIRealtimeDelegationMode.init(rawValue:)), offsetMilliseconds: raw["offsetMs"]?.doubleValue, responseID: raw["responseId"]?.stringValue, raw: providerPayload)
        case "command-acknowledged": event = .commandAcknowledged(command: string("command"), clientEventID: raw["clientEventId"]?.stringValue, raw: providerPayload)
        case "session-created": event = .sessionCreated(sessionID: raw["sessionId"]?.stringValue, raw: providerPayload)
        case "session-updated": event = .sessionUpdated(raw: providerPayload)
        case "speech-started": event = .speechStarted(itemID: raw["itemId"]?.stringValue, raw: providerPayload)
        case "speech-stopped": event = .speechStopped(itemID: raw["itemId"]?.stringValue, raw: providerPayload)
        case "audio-committed": event = .audioCommitted(itemID: raw["itemId"]?.stringValue, previousItemID: raw["previousItemId"]?.stringValue, raw: providerPayload)
        case "conversation-item-added": event = .conversationItemAdded(itemID: item, item: raw["item"] ?? .null, raw: providerPayload)
        case "input-transcription-completed": event = .inputTranscriptionCompleted(itemID: item, transcript: string("transcript"), raw: providerPayload)
        case "response-created": event = .responseCreated(responseID: response, raw: providerPayload)
        case "response-done": event = .responseDone(responseID: response, status: string("status"), raw: providerPayload)
        case "output-item-added": event = .outputItemAdded(responseID: response, itemID: item, raw: providerPayload)
        case "output-item-done": event = .outputItemDone(responseID: response, itemID: item, raw: providerPayload)
        case "content-part-added": event = .contentPartAdded(responseID: response, itemID: item, raw: providerPayload)
        case "content-part-done": event = .contentPartDone(responseID: response, itemID: item, raw: providerPayload)
        case "audio-delta": event = .audioDelta(responseID: response, itemID: item, delta: string("delta"), raw: providerPayload)
        case "audio-done": event = .audioDone(responseID: response, itemID: item, raw: providerPayload)
        case "audio-transcript-delta": event = .audioTranscriptDelta(responseID: response, itemID: item, delta: string("delta"), raw: providerPayload)
        case "audio-transcript-done": event = .audioTranscriptDone(responseID: response, itemID: item, transcript: raw["transcript"]?.stringValue, raw: providerPayload)
        case "text-delta": event = .textDelta(responseID: response, itemID: item, delta: string("delta"), raw: providerPayload)
        case "text-done": event = .textDone(responseID: response, itemID: item, text: raw["text"]?.stringValue, raw: providerPayload)
        case "function-call-arguments-delta": event = .functionCallArgumentsDelta(responseID: response, itemID: item, callID: string("callId"), delta: string("delta"), raw: providerPayload)
        case "function-call-arguments-done": event = .functionCallArgumentsDone(responseID: response, itemID: item, callID: string("callId"), name: string("name"), arguments: string("arguments"), raw: providerPayload)
        case "error":
            if let id = raw["clientEventId"]?.stringValue { event = .correlatedError(message: string("message"), code: raw["code"]?.stringValue, clientEventID: id, raw: providerPayload) }
            else { event = .error(message: string("message"), code: raw["code"]?.stringValue, raw: providerPayload) }
        case "custom": event = .custom(rawType: string("rawType"), raw: providerPayload)
        default: event = .custom(rawType: string("type"), raw: raw)
        }
        return [event]
    }
}

func gatewayRealtimeSessionJSON(_ config: AIRealtimeSessionConfiguration) -> JSONValue {
    var value: [String: JSONValue] = [:]
    value["instructions"] = config.instructions.map(JSONValue.string)
    value["voice"] = config.voice.map(JSONValue.string)
    value["outputModalities"] = config.outputModalities.map { .array($0.map { .string($0.rawValue) }) }
    func format(_ value: AIRealtimeAudioFormat?) -> JSONValue? {
        value.map { .object(["type": .string($0.type), "rate": $0.rate.map { .number(Double($0)) }]) }
    }
    value["inputAudioFormat"] = format(config.inputAudioFormat)
    value["outputAudioFormat"] = format(config.outputAudioFormat)
    func transcription(_ value: AIRealtimeAudioTranscriptionConfiguration?) -> JSONValue? {
        value.map { .object(["model": $0.model.map(JSONValue.string), "language": $0.language.map(JSONValue.string), "prompt": $0.prompt.map(JSONValue.string)]) }
    }
    value["inputAudioTranscription"] = transcription(config.inputAudioTranscription)
    value["outputAudioTranscription"] = transcription(config.outputAudioTranscription)
    if let detection = config.turnDetection {
        value["turnDetection"] = .object(["type": .string(detection.type.rawValue), "threshold": detection.threshold.map(JSONValue.number), "silenceDurationMs": detection.silenceDurationMilliseconds.map { .number(Double($0)) }, "prefixPaddingMs": detection.prefixPaddingMilliseconds.map { .number(Double($0)) }])
    }
    value["tools"] = config.tools.map { .array($0.map { .object(["type": .string($0.type), "name": .string($0.name), "description": $0.description.map(JSONValue.string), "parameters": $0.parameters]) }) }
    value["providerOptions"] = config.providerOptions.map(JSONValue.object)
    return .object(value)
}
