import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI

/// Native equivalents of caller AbortError/TimeoutError must retain identity.
func gatewayIsCallerCancellation(_ error: any Error) -> Bool {
    if error is AIAbortError || error is CancellationError { return true }
    let error = error as NSError
    if error.domain == NSURLErrorDomain, [NSURLErrorCancelled, NSURLErrorTimedOut].contains(error.code) { return true }
    let name = error.userInfo["name"] as? String ?? error.domain
    return name == "AbortError" || name == "TimeoutError"
}


public func gatewayErrorFromHTTPStatus(statusCode: Int, body: String, headers: [String: String]) -> GatewayError {
    gatewayErrorFromHTTPStatus(statusCode: statusCode, body: body, headers: headers, authMethod: nil)
}

/// Upstream `createGatewayErrorFromResponse` for a failed HTTP response.
/// `authMethod` is the request's `ai-gateway-auth-method` header and selects
/// the contextual authentication-error message.
func gatewayErrorFromHTTPStatus(
    statusCode: Int,
    body: String,
    headers: [String: String],
    authMethod: String?
) -> GatewayError {
    if let raw = try? secureJSONParse(body) {
        let cause = gatewayAPICallCause(statusCode: statusCode, response: raw, headers: headers)
        if let error = raw["error"],
           let message = error["message"]?.stringValue {
            let type = gatewayErrorType(error["type"]?.stringValue)
            return GatewayError(
                type: type,
                message: type == .authenticationError
                    ? gatewayAuthenticationErrorMessage(authMethod: authMethod)
                    : message,
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
        // Upstream still recovers a string `generationId` when the error
        // envelope fails validation.
        return GatewayError(
            type: .responseError,
            message: "Invalid error response format: Gateway request failed",
            statusCode: statusCode,
            generationID: raw["generationId"]?.stringValue,
            response: raw,
            headers: headers,
            cause: cause
        )
    }

    // A non-JSON body is kept as the raw string response while the message
    // stays upstream's fixed `defaultMessage`.
    return GatewayError(
        type: .responseError,
        message: "Invalid error response format: Gateway request failed",
        statusCode: statusCode,
        response: .string(body),
        headers: headers,
        cause: AIAPICallError(
            provider: "gateway",
            statusCode: statusCode,
            responseHeaders: headers,
            responseBody: body.isEmpty ? "unknown error" : body
        )
    )
}

/// The `ai-gateway-auth-method` request header, when it is `api-key` or `oidc`.
func gatewayAuthMethod(from headers: [String: String]) -> String? {
    let value = headers.first { $0.key.lowercased() == "ai-gateway-auth-method" }?.value
    return value == "api-key" || value == "oidc" ? value : nil
}

/// Upstream `GatewayAuthenticationError.createContextualError`.
func gatewayAuthenticationErrorMessage(authMethod: String?) -> String {
    switch authMethod {
    case "api-key":
        return """
        AI Gateway authentication failed: Invalid API key or token.

        Create a new API key: https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai%2Fapi-keys

        Provide an API key or Vercel access token via 'apiKey' option or 'AI_GATEWAY_API_KEY' environment variable.
        """
    case "oidc":
        return """
        AI Gateway authentication failed: Invalid OIDC token.

        Run 'npx vercel link' to link your project, then 'vc env pull' to fetch the token.

        Alternatively, use an API key: https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai%2Fapi-keys
        or pass a Vercel access token via the 'apiKey' option.
        """
    default:
        return """
        AI Gateway authentication failed: No authentication provided.

        Option 1 - API key:
        Create an API key: https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai%2Fapi-keys
        Provide via 'apiKey' option or 'AI_GATEWAY_API_KEY' environment variable.

        Option 2 - Vercel access token:
        Pass a Vercel personal access token or Vercel app access token via the 'apiKey' option.

        Option 3 - OIDC token:
        Run 'npx vercel link' to link your project, then 'vc env pull' to fetch the token.
        """
    }
}

/// Human-readable message of a thrown transport error (upstream `error.message`).
func gatewayThrownErrorMessage(_ error: any Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription {
        return description
    }
    let nsError = error as NSError
    if [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(nsError.domain) {
        return nsError.localizedDescription
    }
    return String(describing: error)
}

/// Upstream `asGatewayError` for a thrown request error. Returns nil for
/// caller cancellation and existing Gateway errors (which pass through
/// unchanged). Credential-resolution failures become upstream's contextual
/// "No authentication provided" `GatewayAuthenticationError`; any other error
/// becomes a `GatewayResponseError` (status 500) wrapping its message.
func gatewayErrorForThrownError(_ error: any Error) -> GatewayError? {
    if error is GatewayError || gatewayIsCallerCancellation(error) { return nil }
    if let error = error as? AIError {
        switch error {
        case .gateway:
            return nil
        case .missingAPIKey(provider: "gateway", _), .invalidArgument(argument: "apiKeyProvider", _):
            return GatewayError(
                type: .authenticationError,
                message: gatewayAuthenticationErrorMessage(authMethod: nil),
                statusCode: 401
            )
        default:
            break
        }
    }
    return GatewayError(
        type: .responseError,
        message: "Invalid error response format: Gateway request failed: \(gatewayThrownErrorMessage(error))",
        statusCode: 500,
        response: .object([:])
    )
}

/// ``gatewayErrorForThrownError(_:)`` wrapped as `AIError.gateway`, which
/// core retry handling recognizes.
func gatewayTransportError(_ error: any Error) -> any Error {
    gatewayErrorForThrownError(error).map(AIError.gateway) ?? error
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

func gatewayAPICallError(provider: String, response: AIHTTPResponse, authMethod: String?) -> AIError {
    gatewayAPICallError(provider: provider, statusCode: response.statusCode, body: response.bodyText, headers: response.headers, authMethod: authMethod)
}

func gatewayAPICallError(provider: String, statusCode: Int, body: String, headers: [String: String] = [:], authMethod: String? = nil) -> AIError {
    if provider.hasPrefix("gateway") {
        return .gateway(gatewayErrorFromHTTPStatus(statusCode: statusCode, body: body, headers: headers, authMethod: authMethod))
    }
    return SwiftAITransport.apiCallError(provider: provider, statusCode: statusCode, body: body, headers: headers)
}
