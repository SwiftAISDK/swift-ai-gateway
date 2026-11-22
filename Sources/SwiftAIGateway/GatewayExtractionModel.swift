import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport

/// Gateway's native Extraction Model V4 endpoint.
public struct GatewayExtractionModel: AIExtractionModelV4 {
    public let providerID: String
    public let modelID: String

    /// Individual models can reject field types that the Gateway can send.
    public let supportedFieldTypes = AIExtractionFieldType.allCases
    private let config: GatewayModelConfiguration

    init(modelID: String, config: GatewayModelConfiguration) {
        self.providerID = config.providerID
        self.modelID = modelID
        self.config = config
    }

    public func doExtract(_ options: AIExtractionModelV4CallOptions) async throws -> AIExtractionModelV4Result {
        let stateParts = try options.state.map { try gatewayStatePart($0, model: .extraction) }
        let body = JSONValue.object([
            "stateParts": .array(stateParts),
            "fields": .object(options.fields.mapValues(gatewayExtractionField)),
            "referenceDate": options.referenceDate.map(JSONValue.string),
            "maxOutputTokens": options.maxOutputTokens.map { .number(Double($0)) },
            "reasoning": options.reasoning.map(JSONValue.string),
            "providerOptions": options.providerOptions.isEmpty ? nil : .object(options.providerOptions)
        ])
        var requestConfig = config
        let observabilityHeaders = normalizeHeaders(requestConfig.http.dynamicHeaders?() ?? [:])
        requestConfig.http.dynamicHeaders = nil
        let request = try requestConfig.request(
            path: "/extraction-model",
            modelID: modelID,
            body: body,
            headers: normalizeHeaders(options.headers).mergingHeaders([
                "ai-extraction-model-specification-version": "4",
                "ai-model-id": modelID
            ]).mergingHeaders(observabilityHeaders),
            abortSignal: options.abortSignal
        )

        let response: AIHTTPResponse
        do {
            try options.abortSignal?.throwIfAborted()
            try Task.checkCancellation()
            response = try await config.transport.send(request)
        } catch {
            throw gatewayErrorForThrownError(error) ?? error
        }
        guard (200..<300).contains(response.statusCode) else {
            let error = gatewayErrorFromHTTPStatus(
                statusCode: response.statusCode,
                body: response.bodyText,
                headers: response.headers,
                authMethod: config.authMethod
            )
            if error.upstreamType == "invalid_request_error",
               let parameter = error.response?["error"]?["param"],
               parameter["name"]?.stringValue == "AI_ExtractionUnsupportedFieldTypeError",
               let fieldID = parameter["fieldId"]?.stringValue,
               let fieldTypeLabel = parameter["fieldType"]?.stringValue {
                let type = fieldTypeLabel.hasPrefix("list<") ? .list : AIExtractionFieldType(rawValue: fieldTypeLabel)
                throw AIExtractionUnsupportedFieldTypeError(
                    fieldID: fieldID,
                    fieldType: type ?? options.fields[fieldID]?.type ?? .text,
                    providerID: providerID,
                    modelID: modelID,
                    fieldTypeLabel: fieldTypeLabel
                )
            }
            throw error
        }

        let raw = try? response.jsonValue()
        do {
            guard let raw, let answers = raw["answers"]?.objectValue else {
                throw GatewayExtractionSchemaError()
            }
            let returnedModel = try gatewayExtractionOptional(raw["model"], read: \.stringValue)
            let usage = try gatewayExtractionOptional(raw["usage"], read: \.objectValue).map {
                try AIDecisionModelUsage(
                    inputTokens: gatewayExtractionOptional($0["inputTokens"], read: gatewayExtractionInteger),
                    outputTokens: gatewayExtractionOptional($0["outputTokens"], read: gatewayExtractionInteger)
                )
            }
            let warnings = try gatewayExtractionOptional(raw["warnings"], read: \.arrayValue)
            let metadata = try gatewayExtractionOptional(raw["providerMetadata"], read: \.objectValue) ?? [:]
            guard metadata.values.allSatisfy({ $0.objectValue != nil }) else { throw GatewayExtractionSchemaError() }
            return try AIExtractionModelV4Result(
                answers: answers.mapValues(gatewayExtractionAnswer),
                usage: usage,
                warnings: (warnings ?? []).map(gatewayExtractionWarning),
                providerMetadata: metadata,
                response: AIResponseMetadata(modelID: returnedModel ?? modelID, headers: response.headers, body: raw)
            )
        } catch {
            throw GatewayError(
                type: .responseError,
                message: "Invalid error response format: Gateway request failed",
                statusCode: response.statusCode,
                generationID: raw?["generationId"]?.stringValue,
                response: raw ?? .string(response.bodyText),
                headers: response.headers,
                isRetryable: true,
                cause: AIAPICallError(provider: providerID, statusCode: response.statusCode,
                                      responseHeaders: response.headers, responseBody: response.bodyText)
            )
        }
    }
}

private func gatewayExtractionField(_ field: AIExtractionField) -> JSONValue {
    .object([
        "type": .string(field.type.rawValue),
        "instructions": field.instructions,
        "unit": field.unit.map(JSONValue.string),
        "integer": field.integer.map(JSONValue.bool),
        "decimals": field.decimals.map { .number(Double($0)) },
        "items": field.items.map { .string($0.rawValue) }
    ])
}

private struct GatewayExtractionSchemaError: Error {}

private func gatewayExtractionOptional<T>(_ value: JSONValue?, read: (JSONValue) -> T?) throws -> T? {
    guard let value, value != .null else { return nil }
    guard let result = read(value) else { throw GatewayExtractionSchemaError() }
    return result
}

private func gatewayExtractionInteger(_ value: JSONValue) -> Int? {
    value.doubleValue.flatMap(Int.init(exactly:))
}

private func gatewayExtractionAnswer(_ raw: JSONValue) throws -> AIExtractionAnswer {
    guard let type = raw["type"]?.stringValue.flatMap(AIExtractionAnswerType.init(rawValue:)) else {
        throw GatewayExtractionSchemaError()
    }
    if type == .refusal { return .init(type: .refusal) }
    guard let value = raw["value"] else { throw GatewayExtractionSchemaError() }
    let confidence = try gatewayExtractionOptional(raw["confidence"], read: \.doubleValue)
    let pNull = try gatewayExtractionOptional(raw["pNull"], read: \.doubleValue)

    if type == .list {
        let list = try gatewayExtractionOptional(value, read: \.arrayValue)
        if let list, !list.allSatisfy({ $0.stringValue != nil }), !list.allSatisfy({ $0.doubleValue != nil }) {
            throw GatewayExtractionSchemaError()
        }
        let items = try gatewayExtractionOptional(raw["items"], read: \.arrayValue)?.map { item in
            guard item.objectValue != nil else { throw GatewayExtractionSchemaError() }
            return try AIExtractionItem(
                confidence: gatewayExtractionOptional(item["confidence"], read: \.doubleValue),
                source: gatewayExtractionSource(item["source"])
            )
        }
        return .init(type: type, value: list.map(JSONValue.array), pNull: pNull, confidence: confidence, items: items)
    }

    let read: (JSONValue) -> JSONValue? = switch type {
    case .number, .duration: { $0.doubleValue.map(JSONValue.number) }
    default: { $0.stringValue.map(JSONValue.string) }
    }
    return try AIExtractionAnswer(
        type: type,
        value: gatewayExtractionOptional(value, read: read),
        guess: gatewayExtractionOptional(raw["guess"], read: read),
        pNull: pNull,
        confidence: confidence,
        source: gatewayExtractionSource(raw["source"])
    )
}

private func gatewayExtractionSource(_ raw: JSONValue?) throws -> AIExtractionSource? {
    guard let raw, raw != .null else { return nil }
    guard let part = raw["part"].flatMap(gatewayExtractionInteger) else { throw GatewayExtractionSchemaError() }
    switch raw["type"]?.stringValue {
    case "text":
        guard let start = raw["start"].flatMap(gatewayExtractionInteger),
              let end = raw["end"].flatMap(gatewayExtractionInteger) else { throw GatewayExtractionSchemaError() }
        return .text(part: part, start: start, end: end)
    case "file":
        return .file(part: part)
    default:
        throw GatewayExtractionSchemaError()
    }
}

private func gatewayExtractionWarning(_ raw: JSONValue) -> AIWarning {
    if let warning = try? gatewayModelWarning(raw) { return warning }
    // JSONValue does not retain object key order. Put the discriminator first
    // and use stable JSON for the remaining fields.
    let description: String
    if var fields = raw.objectValue, let type = fields.removeValue(forKey: "type"),
       let typeJSON = try? decisionJSONText(type), let fieldsJSON = try? decisionJSONText(.object(fields)) {
        description = "{\"type\":\(typeJSON)" + (fields.isEmpty ? "}" : ",\(fieldsJSON.dropFirst())")
    } else {
        description = (try? decisionJSONText(raw)) ?? "null"
    }
    return AIWarning(type: "other", message: "Unknown warning: \(description)")
}
