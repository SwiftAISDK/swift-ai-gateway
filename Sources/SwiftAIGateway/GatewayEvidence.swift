import SwiftAIProvider
import SwiftAIProviderUtilities

enum GatewayEvidenceModel: String {
    case decision
    case extraction
}

/// Encodes ordered evidence for the Gateway decision and extraction endpoints.
func gatewayStatePart(_ part: AIDecisionStatePart, model: GatewayEvidenceModel) throws -> JSONValue {
    guard case let .file(mediaType, data, filename, providerOptions) = part else {
        return decisionStatePartJSON(part)
    }
    switch data {
    case .data, .base64:
        return decisionStatePartJSON(part)
    case let .reference(reference) where model == .extraction:
        return .object([
            "type": "file",
            "mediaType": .string(mediaType),
            "data": ["type": "reference", "reference": ["gateway": .string(reference)]],
            "filename": filename.map(JSONValue.string),
            "providerOptions": providerOptions.isEmpty ? nil : .object(providerOptions)
        ])
    case .url, .reference:
        let functionality: String
        switch model {
        case .decision: functionality = "Gateway decision file input requires data"
        case .extraction: functionality = "Gateway extraction file input: url data"
        }
        throw AIDecisionUnsupportedFunctionalityError(functionality: functionality)
    }
}

struct GatewayWarningSchemaError: Error {
    let reason: String
}

func gatewayModelWarning(_ raw: JSONValue, validateDetails: Bool = true) throws(GatewayWarningSchemaError) -> AIWarning {
    guard let type = raw["type"]?.stringValue else {
        throw .init(reason: "warning is invalid.")
    }
    switch type {
    case "unsupported", "compatibility":
        guard let feature = raw["feature"]?.stringValue else {
            throw .init(reason: "warning is missing feature.")
        }
        let details = raw["details"]
        if validateDetails, let details, details.stringValue == nil {
            throw .init(reason: "warning details are invalid.")
        }
        return AIWarning(type: type, feature: feature, message: details?.stringValue)
    case "deprecated":
        guard let setting = raw["setting"]?.stringValue,
              let message = raw["message"]?.stringValue else {
            throw .init(reason: "deprecation warning is invalid.")
        }
        return AIWarning(type: type, setting: setting, message: message)
    case "other":
        guard let message = raw["message"]?.stringValue else {
            throw .init(reason: "warning is missing message.")
        }
        return AIWarning(type: type, message: message)
    default:
        throw .init(reason: "warning has unknown type \"\(type)\".")
    }
}
