import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public struct GatewayModelEntry: Equatable, Sendable {
    public var id: String
    public var name: String?
    public var modelType: String?
    public var provider: String?
    public var modelID: String?

    public init(id: String, name: String? = nil, modelType: String? = nil, provider: String? = nil, modelID: String? = nil) {
        self.id = id
        self.name = name
        self.modelType = modelType
        self.provider = provider
        self.modelID = modelID
    }
}

public struct GatewayCredits: Equatable, Sendable {
    public var balance: String
    public var totalUsed: String

    public init(balance: String, totalUsed: String) {
        self.balance = balance
        self.totalUsed = totalUsed
    }
}

public struct GatewaySpendReportParams: Equatable, Sendable {
    public var startDate: String
    public var endDate: String
    public var groupBy: String?
    public var datePart: String?
    public var userID: String?
    public var model: String?
    public var provider: String?
    public var credentialType: String?
    public var tags: [String]

    public init(
        startDate: String,
        endDate: String,
        groupBy: String? = nil,
        datePart: String? = nil,
        userID: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        credentialType: String? = nil,
        tags: [String] = []
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.groupBy = groupBy
        self.datePart = datePart
        self.userID = userID
        self.model = model
        self.provider = provider
        self.credentialType = credentialType
        self.tags = tags
    }
}

public struct GatewaySpendReportRow: Equatable, Sendable {
    public var day: String?
    public var hour: String?
    public var user: String?
    public var model: String?
    public var tag: String?
    public var provider: String?
    public var credentialType: String?
    public var totalCost: Double
    public var marketCost: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var reasoningTokens: Int?
    public var requestCount: Int?
}

public struct GatewaySpendReportResponse: Equatable, Sendable {
    public var results: [GatewaySpendReportRow]
}

public struct GatewayGenerationInfo: Equatable, Sendable {
    public var id: String
    public var totalCost: Double
    public var upstreamInferenceCost: Double
    public var usage: Double
    public var createdAt: String
    public var model: String
    public var isByok: Bool
    public var providerName: String
    public var streamed: Bool
    public var finishReason: String
    public var latency: Double
    public var generationTime: Double
    public var promptTokens: Int
    public var completionTokens: Int
    public var reasoningTokens: Int
    public var cachedTokens: Int
    public var cacheCreationTokens: Int
    public var billableWebSearchCalls: Int
}

/// Options for minting a short-lived AI Gateway streaming-transcription
/// client secret.
public struct GatewayTranscriptionFactoryGetTokenOptions: Equatable, Sendable {
    public var model: String
    /// Token lifetime in seconds. AI Gateway defaults to 60 seconds and caps
    /// the lifetime at 300 seconds.
    public var expiresAfterSeconds: Int?

    public init(model: String, expiresAfterSeconds: Int? = nil) {
        self.model = model
        self.expiresAfterSeconds = expiresAfterSeconds
    }
}

/// A short-lived secret and WebSocket URL for browser-safe Gateway streaming
/// transcription.
public struct GatewayTranscriptionFactoryGetTokenResult: Equatable, Sendable {
    public var token: String
    public var url: String
    public var expiresAt: Int?

    public init(token: String, url: String, expiresAt: Int? = nil) {
        self.token = token
        self.url = url
        self.expiresAt = expiresAt
    }
}

/// Gateway's experimental streaming-transcription factory.
///
/// The factory is callable to create a model and also mints a short-lived
/// transcription-bound client secret through ``getToken(_:)``. Mint secrets
/// on a trusted server and pass only the returned `vcst_` token to clients.
public struct GatewayTranscriptionFactory: Sendable {
    private let config: GatewayModelConfiguration
    private let webSocketTransport: any AIDuplexWebSocketTransport

    init(
        config: GatewayModelConfiguration,
        webSocketTransport: any AIDuplexWebSocketTransport
    ) {
        self.config = config
        self.webSocketTransport = webSocketTransport
    }

    public func callAsFunction(_ modelID: String) -> GatewayTranscriptionModel {
        GatewayTranscriptionModel(
            modelID: modelID,
            config: config,
            webSocketTransport: webSocketTransport
        )
    }

    public func getToken(
        _ options: GatewayTranscriptionFactoryGetTokenOptions
    ) async throws -> GatewayTranscriptionFactoryGetTokenResult {
        var body: [String: JSONValue] = [
            "model": .string(options.model),
            "routeKind": .string("transcription")
        ]
        if let expiresAfterSeconds = options.expiresAfterSeconds {
            body["expiresIn"] = .number(Double(expiresAfterSeconds))
        }

        let response: AIHTTPResponse
        do {
            response = try await config.transport.send(AIHTTPRequest(
                method: "POST",
                url: try gatewayOriginURL(
                    baseURL: config.baseURL,
                    path: "/v1/realtime/client-secrets"
                ),
                headers: config.headers.mergingHeaders([
                    "content-type": "application/json"
                ]),
                body: try encodeJSONBody(.object(body))
            ))
        } catch let error as GatewayError {
            throw error
        } catch {
            throw GatewayError(
                type: .internalServerError,
                message: String(describing: error),
                statusCode: 500
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw gatewayErrorFromHTTPStatus(
                statusCode: response.statusCode,
                body: response.bodyText,
                headers: response.headers
            )
        }
        let raw = try response.jsonValue()
        guard let token = raw["token"]?.stringValue, !token.isEmpty else {
            throw AIError.invalidResponse(
                provider: "gateway",
                message: "Gateway transcription client-secret response did not contain a non-empty token."
            )
        }
        return GatewayTranscriptionFactoryGetTokenResult(
            token: token,
            url: try gatewayTranscriptionWebSocketURL(
                baseURL: config.baseURL,
                modelID: options.model
            ).absoluteString,
            expiresAt: raw["expiresAt"]?.intValue
        )
    }
}

public final class GatewayProvider: AIProvider, AIEvaluationProvider, AIDecisionProvider, @unchecked Sendable {
    public let providerID = "gateway"
    public let supportedCapabilities: Set<ModelCapability> = [.language, .embedding, .image, .transcription, .speech, .video, .reranking, .evaluation, .decision]
    private let config: GatewayModelConfiguration
    private let webSocketTransport: any AIDuplexWebSocketTransport

    public convenience init(
        configuration settings: GatewayProviderSettings,
        teamIDOrSlug: String? = nil
    ) throws {
        try self.init(
            configuration: settings,
            teamIDOrSlug: teamIDOrSlug,
            webSocketTransport: URLSessionDuplexWebSocketTransport.shared
        )
    }

    public init(
        configuration settings: GatewayProviderSettings,
        teamIDOrSlug: String? = nil,
        webSocketTransport: any AIDuplexWebSocketTransport
    ) throws {
        var settings = settings
        if let teamIDOrSlug {
            settings.headers["x-vercel-ai-gateway-team"] = teamIDOrSlug
        }
        let auth = try gatewayAuthToken(settings: settings)
        let normalizedHeaders = normalizeHeaders(settings.headers)
        if normalizedHeaders["authorization"] == nil {
            settings.headers["Authorization"] = "Bearer \(auth.token)"
        }
        if normalizedHeaders["ai-gateway-protocol-version"] == nil {
            settings.headers["ai-gateway-protocol-version"] = "0.0.1"
        }
        if normalizedHeaders["ai-gateway-auth-method"] == nil {
            settings.headers["ai-gateway-auth-method"] = auth.method
        }
        let headers = withUserAgentSuffix(settings.headers, "ai-sdk-gateway/4.0.126")
        let baseURL = withoutTrailingSlash(settings.baseURL ?? "https://ai-gateway.vercel.sh/v4/ai")
        let queryParams = settings.queryParams
        config = GatewayModelConfiguration(http: .init(providerID: providerID, headers: headers, transport: settings.transport,
            url: { _, path in try providerURL("\(baseURL)\(path)", queryParams: queryParams) }), baseURL: baseURL,
            batchResultMaxLineBytes: try aiBatchResultLineLimit(settings.batchResultDownloads?.maxLineBytes))
        self.webSocketTransport = webSocketTransport
    }

    public func languageModel(_ modelID: String) throws -> any LanguageModel {
        GatewayLanguageModel(modelID: modelID, config: config)
    }

    /// Provider-owned Batch V4 service. Gateway batches accept text requests
    /// only and validate a single common model before the first network call.
    public func experimentalBatch() -> any AIBatchProvider {
        GatewayBatchProvider(config: config)
    }

    public func embeddingModel(_ modelID: String) throws -> any EmbeddingModel {
        GatewayEmbeddingModel(modelID: modelID, config: config)
    }

    public func imageModel(_ modelID: String) throws -> any ImageModel {
        GatewayImageModel(modelID: modelID, config: config)
    }

    public func transcriptionModel(_ modelID: String) throws -> any TranscriptionModel {
        GatewayTranscriptionModel(
            modelID: modelID,
            config: config,
            webSocketTransport: webSocketTransport
        )
    }

    /// Creates a Gateway model for the shared streaming-transcription
    /// WebSocket envelope.
    public func streamingTranscriptionModel(
        _ modelID: String
    ) throws -> any StreamingTranscriptionModel {
        GatewayTranscriptionModel(
            modelID: modelID,
            config: config,
            webSocketTransport: webSocketTransport
        )
    }

    /// Alias for ``streamingTranscriptionModel(_:)``.
    public func streamingTranscription(
        _ modelID: String
    ) throws -> any StreamingTranscriptionModel {
        try streamingTranscriptionModel(modelID)
    }

    /// Callable experimental factory matching
    /// `gateway.experimental_transcription` upstream.
    public var experimentalTranscription: GatewayTranscriptionFactory {
        GatewayTranscriptionFactory(
            config: config,
            webSocketTransport: webSocketTransport
        )
    }

    public func speechModel(_ modelID: String) throws -> any SpeechModel {
        GatewaySpeechModel(modelID: modelID, config: config, webSocketTransport: webSocketTransport)
    }

    public func streamingSpeechModel(_ modelID: String) throws -> any StreamingSpeechModel {
        GatewaySpeechModel(modelID: modelID, config: config, webSocketTransport: webSocketTransport)
    }

    public var experimentalSpeech: GatewaySpeechFactory {
        GatewaySpeechFactory(config: config, webSocketTransport: webSocketTransport)
    }

    public func videoModel(_ modelID: String) throws -> any VideoModel {
        GatewayVideoModel(modelID: modelID, config: config)
    }

    public func rerankingModel(_ modelID: String) throws -> any RerankingModel {
        GatewayRerankingModel(modelID: modelID, config: config)
    }

    public func decisionModel(_ modelID: String) throws -> any AIDecisionModelV4 {
        GatewayDecisionModel(modelID: modelID, config: config)
    }

    public func decision(_ modelID: String) throws -> any AIDecisionModelV4 { try decisionModel(modelID) }

    public func evaluationModel(_ modelID: String) throws -> any AIEvaluationModelV4 {
        GatewayEvaluationModel(modelID: modelID, config: config)
    }

    public func evaluation(_ modelID: String) throws -> any AIEvaluationModelV4 {
        try evaluationModel(modelID)
    }

    public func availableModels() async throws -> [GatewayModelEntry] {
        let response = try await config.transport.send(AIHTTPRequest(method: "GET", url: try requireURL("\(config.baseURL)/config"), headers: config.headers))
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        return raw["models"]?.arrayValue?.compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            return GatewayModelEntry(
                id: id,
                name: item["name"]?.stringValue,
                modelType: item["modelType"]?.stringValue ?? item["model_type"]?.stringValue,
                provider: item["specification"]?["provider"]?.stringValue,
                modelID: item["specification"]?["modelId"]?.stringValue
            )
        } ?? []
    }

    public func getAvailableModels() async throws -> [GatewayModelEntry] {
        try await availableModels()
    }

    public func credits() async throws -> GatewayCredits {
        let originURL = try gatewayOriginURL(baseURL: config.baseURL, path: "/v1/credits")
        var components = URLComponents(url: originURL, resolvingAgainstBaseURL: false)!
        if let team = config.headers.first(where: { $0.key.lowercased() == "x-vercel-ai-gateway-team" })?.value.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty {
            components.queryItems = [URLQueryItem(name: team.hasPrefix("team_") ? "teamId" : "slug", value: team)]
        }
        let response = try await config.transport.send(AIHTTPRequest(method: "GET", url: components.url ?? originURL, headers: config.headers))
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        return GatewayCredits(balance: raw["balance"]?.stringValue ?? "", totalUsed: raw["total_used"]?.stringValue ?? raw["totalUsed"]?.stringValue ?? "")
    }

    public func getCredits() async throws -> GatewayCredits {
        try await credits()
    }

    public func getSpendReport(_ params: GatewaySpendReportParams) async throws -> GatewaySpendReportResponse {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "start_date", value: params.startDate),
            URLQueryItem(name: "end_date", value: params.endDate)
        ]
        appendQueryItem("group_by", params.groupBy, to: &queryItems)
        appendQueryItem("date_part", params.datePart, to: &queryItems)
        appendQueryItem("user_id", params.userID, to: &queryItems)
        appendQueryItem("model", params.model, to: &queryItems)
        appendQueryItem("provider", params.provider, to: &queryItems)
        appendQueryItem("credential_type", params.credentialType, to: &queryItems)
        if !params.tags.isEmpty {
            queryItems.append(URLQueryItem(name: "tags", value: params.tags.joined(separator: ",")))
        }

        let response = try await config.transport.send(AIHTTPRequest(
            method: "GET",
            url: try gatewayOriginURL(baseURL: config.baseURL, path: "/v1/report", queryItems: queryItems),
            headers: config.headers
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        return GatewaySpendReportResponse(results: raw["results"]?.arrayValue?.map(gatewaySpendReportRow) ?? [])
    }

    public func getGenerationInfo(id: String) async throws -> GatewayGenerationInfo {
        let response = try await config.transport.send(AIHTTPRequest(
            method: "GET",
            url: try gatewayOriginURL(baseURL: config.baseURL, path: "/v1/generation", queryItems: [URLQueryItem(name: "id", value: id)]),
            headers: config.headers
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(provider: providerID, response: response)
        }
        let data = try response.jsonValue()["data"] ?? .object([:])
        return GatewayGenerationInfo(
            id: data["id"]?.stringValue ?? "",
            totalCost: data["total_cost"]?.doubleValue ?? 0,
            upstreamInferenceCost: data["upstream_inference_cost"]?.doubleValue ?? 0,
            usage: data["usage"]?.doubleValue ?? 0,
            createdAt: data["created_at"]?.stringValue ?? "",
            model: data["model"]?.stringValue ?? "",
            isByok: data["is_byok"]?.boolValue ?? false,
            providerName: data["provider_name"]?.stringValue ?? "",
            streamed: data["streamed"]?.boolValue ?? false,
            finishReason: data["finish_reason"]?.stringValue ?? "",
            latency: data["latency"]?.doubleValue ?? 0,
            generationTime: data["generation_time"]?.doubleValue ?? 0,
            promptTokens: data["native_tokens_prompt"]?.intValue ?? 0,
            completionTokens: data["native_tokens_completion"]?.intValue ?? 0,
            reasoningTokens: data["native_tokens_reasoning"]?.intValue ?? 0,
            cachedTokens: data["native_tokens_cached"]?.intValue ?? 0,
            cacheCreationTokens: data["native_tokens_cache_creation"]?.intValue ?? 0,
            billableWebSearchCalls: data["billable_web_search_calls"]?.intValue ?? 0
        )
    }
}

private struct GatewayAuthToken {
    var token: String
    var method: String
}

private func gatewayAuthToken(settings: GatewayProviderSettings) throws -> GatewayAuthToken {
    if let apiKey = settings.apiKey ?? environmentValue(["AI_GATEWAY_API_KEY"]) {
        return GatewayAuthToken(token: apiKey, method: "api-key")
    }
    if let oidcToken = environmentValue(["VERCEL_OIDC_TOKEN"]) {
        return GatewayAuthToken(token: oidcToken, method: "oidc")
    }
    throw AIError.missingAPIKey(provider: "gateway", environmentVariables: ["AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN"])
}

private func gatewaySpendReportRow(_ raw: JSONValue) -> GatewaySpendReportRow {
    GatewaySpendReportRow(
        day: raw["day"]?.stringValue,
        hour: raw["hour"]?.stringValue,
        user: raw["user"]?.stringValue,
        model: raw["model"]?.stringValue,
        tag: raw["tag"]?.stringValue,
        provider: raw["provider"]?.stringValue,
        credentialType: raw["credential_type"]?.stringValue,
        totalCost: raw["total_cost"]?.doubleValue ?? raw["totalCost"]?.doubleValue ?? 0,
        marketCost: raw["market_cost"]?.doubleValue ?? raw["marketCost"]?.doubleValue,
        inputTokens: raw["input_tokens"]?.intValue ?? raw["inputTokens"]?.intValue,
        outputTokens: raw["output_tokens"]?.intValue ?? raw["outputTokens"]?.intValue,
        cachedInputTokens: raw["cached_input_tokens"]?.intValue ?? raw["cachedInputTokens"]?.intValue,
        cacheCreationInputTokens: raw["cache_creation_input_tokens"]?.intValue ?? raw["cacheCreationInputTokens"]?.intValue,
        reasoningTokens: raw["reasoning_tokens"]?.intValue ?? raw["reasoningTokens"]?.intValue,
        requestCount: raw["request_count"]?.intValue ?? raw["requestCount"]?.intValue
    )
}

private func gatewayOriginURL(baseURL: String, path: String, queryItems: [URLQueryItem] = []) throws -> URL {
    guard let base = URL(string: baseURL), let scheme = base.scheme, let host = base.host else {
        throw AIError.invalidURL(baseURL)
    }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = base.port
    components.path = path
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else {
        throw AIError.invalidURL("\(scheme)://\(host)\(path)")
    }
    return url
}

private func appendQueryItem(_ name: String, _ value: String?, to queryItems: inout [URLQueryItem]) {
    if let value {
        queryItems.append(URLQueryItem(name: name, value: value))
    }
}
public extension AIProviders {
    static func gateway(configuration: GatewayProviderSettings, teamIDOrSlug: String? = nil,
                        webSocketTransport: any AIDuplexWebSocketTransport = URLSessionDuplexWebSocketTransport.shared) throws -> GatewayProvider {
        try GatewayProvider(configuration: configuration, teamIDOrSlug: teamIDOrSlug, webSocketTransport: webSocketTransport)
    }
}
