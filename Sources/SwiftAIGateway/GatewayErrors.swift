import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public func gatewayErrorFromHTTPStatus(statusCode: Int, body: String, headers: [String: String]) -> GatewayError {
    if let raw = try? secureJSONParse(body) {
        let cause = gatewayAPICallCause(statusCode: statusCode, response: raw, headers: headers)
        if let error = raw["error"],
           let message = error["message"]?.stringValue {
            return GatewayError(
                type: gatewayErrorType(error["type"]?.stringValue),
                message: message,
                statusCode: statusCode,
                generationID: raw["generationId"]?.stringValue,
                modelID: error["param"]?["modelId"]?.stringValue,
                response: raw,
                headers: headers,
                cause: cause
            )
        }
        if raw["type"]?.stringValue == "error", let message = raw["message"]?.stringValue {
            return GatewayError(
                type: gatewayErrorType(raw["errorType"]?.stringValue),
                message: message,
                statusCode: raw["statusCode"]?.intValue ?? statusCode,
                response: raw,
                headers: headers,
                cause: cause
            )
        }
        return GatewayError(
            type: .responseError,
            message: "Invalid error response format: Gateway request failed",
            statusCode: statusCode,
            response: raw,
            headers: headers,
            cause: cause
        )
    }

    return GatewayError(
        type: .responseError,
        message: "Invalid error response format: \(body.isEmpty ? "Gateway request failed" : body)",
        statusCode: statusCode,
        response: body.isEmpty ? nil : .string(body),
        headers: headers,
        cause: AIAPICallError(
            provider: "gateway",
            statusCode: statusCode,
            responseHeaders: headers,
            responseBody: body.isEmpty ? "unknown error" : body
        )
    )
}

private func gatewayAPICallCause(
    statusCode: Int,
    response: JSONValue,
    headers: [String: String]
) -> AIAPICallError {
    AIAPICallError(
        provider: "gateway",
        statusCode: statusCode,
        responseHeaders: headers,
        responseBody: getErrorMessage(response)
    )
}

private func gatewayErrorType(_ raw: String?) -> GatewayErrorType {
    switch raw {
    case GatewayErrorType.authenticationError.rawValue:
        return .authenticationError
    case GatewayErrorType.invalidRequestError.rawValue:
        return .invalidRequestError
    case GatewayErrorType.rateLimitExceeded.rawValue:
        return .rateLimitExceeded
    case GatewayErrorType.modelNotFound.rawValue:
        return .modelNotFound
    case "not_found":
        return .notFound
    case GatewayErrorType.failedDependency.rawValue:
        return .failedDependency
    case GatewayErrorType.forbidden.rawValue:
        return .forbidden
    case GatewayErrorType.internalServerError.rawValue:
        return .internalServerError
    case GatewayErrorType.timeoutError.rawValue:
        return .timeoutError
    default:
        return .internalServerError
    }
}


// The compatibility aggregate retains provider-specific error selection.
// Core transport only constructs provider-neutral HTTP errors.
func gatewayAPICallError(provider: String, response: AIHTTPResponse) -> AIError {
    gatewayAPICallError(provider: provider, statusCode: response.statusCode, body: response.bodyText, headers: response.headers)
}

func gatewayAPICallError(provider: String, statusCode: Int, body: String, headers: [String: String] = [:]) -> AIError {
    if provider == "gateway" {
        return .gateway(gatewayErrorFromHTTPStatus(statusCode: statusCode, body: body, headers: headers))
    }
    return SwiftAITransport.apiCallError(provider: provider, statusCode: statusCode, body: body, headers: headers)
}
