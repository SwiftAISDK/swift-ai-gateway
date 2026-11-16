import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI

// Gateway's `/language-model` endpoint receives the AI SDK's
// `LanguageModelV4CallOptions` (minus `abortSignal`) as its JSON body and
// returns `LanguageModelV4GenerateResult` / V4 stream parts. These helpers
// build that wire shape from Swift's provider-neutral request.

/// Upstream `getArgs`: the V4 call options sent as the request body.
func gatewayLanguageCallOptions(
    for request: LanguageModelRequest,
    streaming: Bool
) -> JSONValue {
    var body: [String: JSONValue] = [
        "prompt": .array(gatewayV4Prompt(request.messages))
    ]
    if let maxOutputTokens = request.maxOutputTokens { body["maxOutputTokens"] = .number(Double(maxOutputTokens)) }
    if let temperature = request.temperature { body["temperature"] = .number(temperature) }
    if !request.stopSequences.isEmpty { body["stopSequences"] = .array(request.stopSequences) }
    if let topP = request.topP { body["topP"] = .number(topP) }
    if let topK = request.topK { body["topK"] = .number(Double(topK)) }
    if let presencePenalty = request.presencePenalty { body["presencePenalty"] = .number(presencePenalty) }
    if let frequencyPenalty = request.frequencyPenalty { body["frequencyPenalty"] = .number(frequencyPenalty) }
    if let responseFormat = request.responseFormat { body["responseFormat"] = gatewayV4ResponseFormat(responseFormat) }
    if let seed = request.seed { body["seed"] = .number(Double(seed)) }
    if let reasoning = request.reasoning { body["reasoning"] = .string(reasoning) }
    let tools = gatewayV4Tools(from: request.tools)
    if !tools.isEmpty {
        body["tools"] = .array(tools)
        if let toolChoice = gatewayToolChoice(from: request.toolChoice ?? request.extraBody["toolChoice"]) {
            body["toolChoice"] = toolChoice
        }
    }
    if streaming { body["includeRawChunks"] = .bool(request.includeRawChunks) }
    if !request.headers.isEmpty { body["headers"] = .object(request.headers.mapValues(JSONValue.string)) }
    if !request.providerOptions.isEmpty { body["providerOptions"] = .object(request.providerOptions) }
    // Swift-only escape hatch for fields without a typed request property.
    body.merge(request.extraBody) { _, new in new }
    return .object(body)
}

func gatewayV4ResponseFormat(_ format: AIResponseFormat) -> JSONValue {
    switch format {
    case .text:
        return .object(["type": .string("text")])
    case let .json(schema, name, description):
        var object: [String: JSONValue] = ["type": .string("json")]
        if let schema { object["schema"] = schema }
        if let name { object["name"] = .string(name) }
        if let description { object["description"] = .string(description) }
        return .object(object)
    }
}


/// V4 tool definitions: provider tools keep `{type, id, name, args}`;
/// function tools lift description/inputExamples/providerOptions/strict out
/// of the schema like core `prepareTools`. Tools are ordered by name so the
/// request body is deterministic.
func gatewayV4Tools(from tools: [String: JSONValue]) -> [JSONValue] {
    tools.sorted { $0.key < $1.key }.map { name, schema in
        let object = schema.objectValue
        if object?["type"]?.stringValue == "provider" || object?["id"]?.stringValue?.hasPrefix("gateway.") == true {
            return .object([
                "type": .string("provider"),
                "id": .string(object?["id"]?.stringValue ?? name),
                "name": .string(object?["name"]?.stringValue ?? name),
                "args": .object(object?["args"]?.objectValue ?? [:])
            ])
        }
        var tool: [String: JSONValue] = [
            "type": .string("function"),
            "name": .string(name),
            "inputSchema": aiFunctionToolInputSchema(schema)
        ]
        for key in aiFunctionToolMetadataKeys {
            if let value = object?[key] { tool[key] = value }
        }
        return .object(tool)
    }
}

/// Upstream `convertToLanguageModelPrompt` output shape.
func gatewayV4Prompt(_ messages: [AIMessage]) -> [JSONValue] {
    messages.compactMap { message -> JSONValue? in
        var output: [String: JSONValue] = ["role": .string(message.role.rawValue)]
        switch message.role {
        case .system:
            // V4 system messages carry a plain string.
            output["content"] = .string(message.content.compactMap(\.text).joined(separator: "\n"))
        case .user:
            output["content"] = .array(message.content.compactMap { part in
                if case let .text(text, _) = part, text.isEmpty { return nil }
                return gatewayV4Part(part)
            })
        case .assistant:
            var parts: [JSONValue] = []
            let hasReasoningPart = message.content.contains { if case .reasoning = $0 { return true }; return false }
            if !hasReasoningPart, let reasoning = message.reasoning, !reasoning.isEmpty {
                parts.append(.object(["type": .string("reasoning"), "text": .string(reasoning)]))
            }
            parts += message.content.compactMap { part in
                switch part {
                case let .text(text, providerMetadata) where text.isEmpty && providerMetadata.isEmpty:
                    return nil
                case .toolApprovalRequest:
                    return nil
                default:
                    return gatewayV4Part(part)
                }
            }
            output["content"] = .array(parts)
        case .tool:
            let parts = message.content.compactMap { part -> JSONValue? in
                if case let .toolApprovalResponse(response) = part, !response.providerExecuted { return nil }
                return gatewayV4Part(part)
            }
            guard !parts.isEmpty else { return nil }
            output["content"] = .array(parts)
        }
        if !message.providerMetadata.isEmpty {
            output["providerOptions"] = .object(message.providerMetadata)
        }
        return .object(output)
    }
}

private func gatewayV4Part(_ part: AIContentPart) -> JSONValue? {
    var object: [String: JSONValue]
    switch part {
    case let .text(text, _):
        object = ["type": .string("text"), "text": .string(text)]
    case let .reasoning(text, _):
        object = ["type": .string("reasoning"), "text": .string(text)]
    case let .imageURL(url, _):
        if let inline = gatewayDataURL(url) {
            object = [
                "type": .string("file"),
                "mediaType": .string(inline.mediaType),
                "data": .object(["type": .string("data"), "data": .string(inline.base64)])
            ]
        } else {
            // Upstream converts image parts to file parts with the top-level
            // `image` media type.
            object = [
                "type": .string("file"),
                "mediaType": .string("image"),
                "data": .object(["type": .string("url"), "url": .string(url)])
            ]
        }
    case let .data(mimeType, data, _):
        object = [
            "type": .string("file"),
            "mediaType": .string(mimeType),
            "data": .object(["type": .string("data"), "data": .string(data.base64EncodedString())])
        ]
    case let .file(mimeType, data, filename, _):
        object = [
            "type": .string("file"),
            "mediaType": .string(mimeType),
            "data": .object(["type": .string("data"), "data": .string(data.base64EncodedString())])
        ]
        if let filename { object["filename"] = .string(filename) }
    case let .reasoningFile(file):
        object = ["type": .string("reasoning-file"), "mediaType": .string(file.mediaType)]
        if let data = file.data {
            object["data"] = .object(["type": .string("data"), "data": .string(data.base64EncodedString())])
        } else if let url = file.url {
            object["data"] = .object(["type": .string("url"), "url": .string(url)])
        } else {
            return nil
        }
    case let .custom(value, _):
        object = ["type": .string("custom")]
        if let kind = value["kind"]?.stringValue { object["kind"] = .string(kind) }
    case let .providerReference(mimeType, reference, filename, _):
        object = [
            "type": .string("file"),
            "mediaType": .string(mimeType),
            "data": .object(["type": .string("reference"), "reference": .object(reference.mapValues(JSONValue.string))])
        ]
        if let filename { object["filename"] = .string(filename) }
    case let .toolCall(call):
        object = [
            "type": .string("tool-call"),
            "toolCallId": .string(call.id),
            "toolName": .string(call.name),
            "input": gatewayV4ToolInput(call.arguments)
        ]
        if call.providerExecuted { object["providerExecuted"] = .bool(true) }
    case let .toolResult(result):
        object = [
            "type": .string("tool-result"),
            "toolCallId": .string(result.toolCallID),
            "toolName": .string(result.toolName),
            "output": gatewayV4ToolResultOutput(result)
        ]
    case let .toolApprovalResponse(response):
        object = [
            "type": .string("tool-approval-response"),
            "approvalId": .string(response.id),
            "approved": .bool(response.approved)
        ]
        if let reason = response.reason { object["reason"] = .string(reason) }
    case .toolApprovalRequest:
        return nil
    }
    if !part.providerMetadata.isEmpty {
        object["providerOptions"] = .object(part.providerMetadata)
    }
    return .object(object)
}

private func gatewayV4ToolInput(_ arguments: String) -> JSONValue {
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .object([:]) }
    return (try? decodeJSONBody(Data(trimmed.utf8))) ?? .string(arguments)
}

private let gatewayV4ToolOutputTypes: Set<String> = ["text", "json", "error-text", "error-json", "content", "execution-denied"]

/// Upstream `createToolModelOutput`: typed outputs pass through; otherwise a
/// string becomes `text`/`error-text` and any other value `json`/`error-json`.
func gatewayV4ToolResultOutput(_ result: AIToolResult) -> JSONValue {
    let value = result.modelOutput ?? result.result
    if let type = value["type"]?.stringValue, gatewayV4ToolOutputTypes.contains(type),
       type == "execution-denied" || value["value"] != nil {
        return value
    }
    if let string = value.stringValue {
        return .object(["type": .string(result.isError ? "error-text" : "text"), "value": .string(string)])
    }
    return .object(["type": .string(result.isError ? "error-json" : "json"), "value": value])
}

private func gatewayDataURL(_ url: String) -> (mediaType: String, base64: String)? {
    guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
    let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
    let payload = String(url[url.index(after: comma)...])
    let segments = header.split(separator: ";").map(String.init)
    let mediaType = segments.first.flatMap { $0.isEmpty ? nil : $0 } ?? "image"
    if segments.contains("base64") { return (mediaType, payload) }
    let decoded = payload.removingPercentEncoding ?? payload
    return (mediaType, Data(decoded.utf8).base64EncodedString())
}

// MARK: - Response parsing

/// V4 `finishReason` is `{unified, raw}`; older responses send a string.
func gatewayV4FinishReason(_ value: JSONValue?, hasToolCalls: Bool) -> String? {
    if let unified = value?["unified"]?.stringValue { return unified }
    return gatewayFinishReason(value?.stringValue, hasToolCalls: hasToolCalls)
}

/// V4 usage (`inputTokens.total`, ...) with a fallback to OpenAI-style usage.
func gatewayV4Usage(from raw: JSONValue) -> TokenUsage? {
    guard let usage = raw["usage"], usage != .null else { return nil }
    let input = usage["inputTokens"]
    let output = usage["outputTokens"]
    guard input?.objectValue != nil || output?.objectValue != nil else {
        return tokenUsage(from: raw)
    }
    let inputTotal = input?["total"]?.intValue
    let outputTotal = output?["total"]?.intValue
    return TokenUsage(
        inputTokens: inputTotal,
        outputTokens: outputTotal,
        totalTokens: inputTotal.flatMap { input in outputTotal.map { input + $0 } },
        inputTokensNoCache: input?["noCache"]?.intValue,
        inputTokensCacheRead: input?["cacheRead"]?.intValue,
        inputTokensCacheWrite: input?["cacheWrite"]?.intValue,
        outputTextTokens: output?["text"]?.intValue,
        outputReasoningTokens: output?["reasoning"]?.intValue,
        rawValue: usage
    )
}

func gatewayV4Timestamp(_ value: JSONValue?) -> Date? {
    if let number = value?.doubleValue { return Date(timeIntervalSince1970: number / 1000) }
    guard let string = value?.stringValue else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}

/// V4 `response: {id, timestamp, modelId}` with a fallback to top-level
/// OpenAI-style `id`/`created`/`model` fields.
func gatewayV4ResponseMetadata(
    from raw: JSONValue,
    response: AIHTTPResponse,
    modelID: String
) -> AIResponseMetadata {
    guard let metadata = raw["response"]?.objectValue else {
        return aiResponseMetadata(from: raw, response: response, modelID: modelID)
    }
    return AIResponseMetadata(
        id: metadata["id"]?.stringValue,
        timestamp: gatewayV4Timestamp(metadata["timestamp"]) ?? Date(),
        modelID: metadata["modelId"]?.stringValue ?? modelID,
        headers: response.headers,
        body: raw
    )
}

/// Message of a V4 `error` stream part payload.
func gatewayV4StreamErrorMessage(_ error: JSONValue?) -> String {
    guard let error else { return "unknown error" }
    if let message = error["message"]?.stringValue { return message }
    if let string = error.stringValue { return string }
    return getErrorMessage(error)
}
