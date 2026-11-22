import Foundation
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport

/// The Gateway WebSocket route used by a realtime model.
public enum GatewayRealtimeAPI: String, Sendable {
    case live
    case realtime
}

public struct GatewayRealtimeFactoryGetTokenOptions: Equatable, Sendable {
    public var model: String
    public var api: GatewayRealtimeAPI?
    public var expiresAfterSeconds: Int?

    public init(model: String, api: GatewayRealtimeAPI? = nil, expiresAfterSeconds: Int? = nil) {
        self.model = model
        self.api = api
        self.expiresAfterSeconds = expiresAfterSeconds
    }
}

/// Routes known Live IDs to continuous conversation and other IDs to realtime.
public struct GatewayRealtimeFactory: Sendable {
    let config: GatewayModelConfiguration

    public func callAsFunction(_ modelID: String, api: GatewayRealtimeAPI? = nil) -> any AIRealtimeModelV4 {
        switch api ?? Self.defaultAPI(for: modelID) {
        case .live: GatewayRealtimeModelLive(modelID: modelID, config: config)
        case .realtime: GatewayRealtimeModel(modelID: modelID, config: config)
        }
    }

    /// Mints a short-lived, model- and route-bound token from a trusted process.
    public func getToken(_ options: GatewayRealtimeFactoryGetTokenOptions) async throws -> AIRealtimeClientSecretResult {
        try await self(options.model, api: options.api).doCreateClientSecret(.init(expiresAfterSeconds: options.expiresAfterSeconds))
    }

    private static func defaultAPI(for modelID: String) -> GatewayRealtimeAPI {
        switch modelID {
        case "openai/gpt-live-1", "openai/gpt-live-1.1": .live
        default: .realtime
        }
    }
}

func gatewayRealtimeClientSecret(
    config: GatewayModelConfiguration,
    modelID: String,
    api: GatewayRealtimeAPI,
    options: AIRealtimeClientSecretOptions
) async throws -> AIRealtimeClientSecretResult {
    var body: [String: JSONValue] = ["model": .string(modelID)]
    if api == .live { body["routeKind"] = "live" }
    if let expires = options.expiresAfterSeconds { body["expiresIn"] = .number(Double(expires)) }
    let request = AIHTTPRequest(
        method: "POST",
        url: try gatewayOriginURL(baseURL: config.baseURL, path: "/v1/realtime/client-secrets"),
        headers: config.headers.mergingHeaders(["content-type": "application/json"]),
        body: try encodeJSONBody(.object(body)),
        abortSignal: options.abortSignal
    )
    let response: AIHTTPResponse
    do {
        response = try await config.transport.send(request)
    } catch where api == .live {
        throw gatewayTransportError(error)
    }
    guard (200..<300).contains(response.statusCode) else { throw config.httpStatusError(response) }
    let raw = try response.jsonValue()
    guard let token = raw["token"]?.stringValue, !token.isEmpty else {
        throw AIError.invalidResponse(
            provider: "gateway.\(api.rawValue)",
            message: "Gateway realtime client-secret response did not contain a non-empty token."
        )
    }
    return .init(
        token: token,
        url: try gatewayRealtimeWebSocketURL(baseURL: config.baseURL, modelID: modelID, api: api),
        expiresAt: raw["expiresAt"]?.intValue
    )
}

func gatewayRealtimeWebSocketURL(baseURL: String, modelID: String, api: GatewayRealtimeAPI) throws -> String {
    guard var components = URLComponents(string: baseURL),
          let scheme = components.scheme, ["http", "https"].contains(scheme),
          components.host != nil else { throw AIError.invalidURL(baseURL) }
    components.scheme = scheme == "https" ? "wss" : "ws"
    components.path = withoutTrailingSlash(components.path) + "/\(api.rawValue)-model"
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "/?&=+")
    guard let encodedModelID = modelID.addingPercentEncoding(withAllowedCharacters: allowed) else {
        throw AIError.invalidURL(baseURL)
    }
    components.percentEncodedQuery = "ai-model-id=" + encodedModelID
    guard let url = components.url else { throw AIError.invalidURL(baseURL) }
    return url.absoluteString
}

func gatewayRealtimeClientWebSocketConfig(
    config: GatewayModelConfiguration,
    token: String,
    url: String
) -> AIRealtimeWebSocketConfiguration {
    let team = normalizeHeaders(config.headers)["x-vercel-ai-gateway-team"]
    return .init(url: url, protocols: GatewayRealtimeAuth.realtimeProtocols(token: token, teamIDOrSlug: team))
}
