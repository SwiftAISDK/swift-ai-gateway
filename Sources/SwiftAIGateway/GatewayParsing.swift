import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


struct GatewayStreamingToolCall {
    var id: String
    var name: String
    var arguments: String
    var providerExecuted: Bool
    var rawValue: JSONValue

    var toolCall: AIToolCall {
        AIToolCall(
            id: id,
            name: name,
            arguments: arguments.isEmpty ? "{}" : arguments,
            providerExecuted: providerExecuted,
            rawValue: rawValue
        )
    }
}

func parseGatewayText(from raw: JSONValue) -> String? {
    if let text = raw["text"]?.stringValue ?? raw["output_text"]?.stringValue {
        return text
    }
    let contentText = gatewayContentParts(raw["content"]).compactMap { part in
        part["text"]?.stringValue
    }.joined()
    if !contentText.isEmpty {
        return contentText
    }
    return raw["choices"]?[0]?["message"]?["content"]?.stringValue
}

func gatewayTools(from tools: [String: JSONValue]) -> [JSONValue] {
    tools.map { name, schema in
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
            "inputSchema": schema
        ]
        if let description = object?["description"]?.stringValue {
            tool["description"] = .string(description)
        }
        return .object(tool)
    }
}

func gatewayToolChoice(from value: JSONValue?) -> JSONValue? {
    if let string = value?.stringValue {
        switch string {
        case "auto", "none", "required":
            return .object(["type": .string(string)])
        default:
            return nil
        }
    }
    guard let object = value?.objectValue else { return nil }
    switch object["type"]?.stringValue {
    case "auto", "none", "required":
        return .object(["type": object["type"] ?? .string("auto")])
    case "tool":
        guard let toolName = object["toolName"]?.stringValue ?? object["tool_name"]?.stringValue else { return nil }
        return .object(["type": .string("tool"), "toolName": .string(toolName)])
    default:
        return nil
    }
}

func gatewayContentParts(_ content: JSONValue?) -> [JSONValue] {
    if let array = content?.arrayValue { return array }
    if let content { return [content] }
    return []
}

func gatewayToolCalls(from content: JSONValue?) -> [AIToolCall] {
    gatewayContentParts(content).enumerated().compactMap { index, part in
        gatewayToolCall(from: part, fallbackIndex: index)
    }
}

func gatewaySources(from content: JSONValue?) -> [AISource] {
    gatewayContentParts(content).enumerated().compactMap { index, part in
        gatewaySource(from: part, fallbackIndex: index)
    }
}

func gatewaySource(from value: JSONValue, fallbackIndex: Int) -> AISource? {
    guard value["type"]?.stringValue == "source" else { return nil }
    let sourceType = value["sourceType"]?.stringValue ?? value["source_type"]?.stringValue ?? "url"
    let id = value["id"]?.stringValue ?? "source-\(fallbackIndex)"
    return AISource(
        id: id,
        sourceType: sourceType,
        url: value["url"]?.stringValue,
        title: value["title"]?.stringValue,
        mediaType: value["mediaType"]?.stringValue ?? value["media_type"]?.stringValue,
        filename: value["filename"]?.stringValue,
        providerMetadata: value["providerMetadata"]?.objectValue ?? value["provider_metadata"]?.objectValue ?? [:],
        rawValue: value
    )
}

func gatewayToolCall(from value: JSONValue, fallbackIndex: Int) -> AIToolCall? {
    guard value["type"]?.stringValue == "tool-call" else { return nil }
    let name = value["toolName"]?.stringValue ?? value["tool_name"]?.stringValue ?? value["name"]?.stringValue
    guard let name else { return nil }
    let id = value["toolCallId"]?.stringValue ?? value["tool_call_id"]?.stringValue ?? value["id"]?.stringValue ?? "tool-call-\(fallbackIndex)"
    return AIToolCall(
        id: id,
        name: name,
        arguments: gatewayToolArguments(value["input"] ?? value["arguments"]),
        providerExecuted: value["providerExecuted"]?.boolValue ?? false,
        providerMetadata: gatewayProviderMetadata(value["providerMetadata"] ?? value["provider_metadata"]),
        rawValue: value
    )
}

func gatewayProviderMetadata(_ value: JSONValue?) -> [String: JSONValue] {
    value?.objectValue ?? [:]
}

func gatewayToolArguments(_ value: JSONValue?) -> String {
    guard let value else { return "{}" }
    if let string = value.stringValue { return string }
    guard let data = try? encodeJSONBody(value), let text = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return text
}

func gatewayFinishReason(_ value: String?, hasToolCalls: Bool) -> String? {
    guard let value else {
        return hasToolCalls ? "tool-calls" : nil
    }
    if value == "tool_calls" {
        return "tool-calls"
    }
    return hasToolCalls && value == "stop" ? "tool-calls" : value
}