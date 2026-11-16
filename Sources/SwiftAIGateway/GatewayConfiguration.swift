import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

public struct GatewayProviderSettings: Sendable {
    public var apiKey: String?
    /// Supplies a fresh API key before an authenticated request.
    public var apiKeyProvider: (@Sendable () async throws -> String)?
    public var baseURL: String?
    public var headers: [String: String]
    public var queryParams: [String: String]
    public var transport: any AITransport
    public var batchResultDownloads: AIBatchResultDownloadSettings?
    /// How long ``GatewayProvider/getAvailableModels()`` reuses its cached
    /// catalog, in milliseconds. Defaults to five minutes.
    public var metadataCacheRefreshMillis: Int? = nil
    /// Test clock for the metadata cache.
    var currentDate: (@Sendable () -> Date)? = nil

    public init(apiKey: String? = nil, apiKeyProvider: (@Sendable () async throws -> String)? = nil, baseURL: String? = nil, headers: [String: String] = [:],
                queryParams: [String: String] = [:], transport: any AITransport = URLSessionTransport.shared,
                batchResultDownloads: AIBatchResultDownloadSettings? = nil) {
        self.apiKey = apiKey; self.apiKeyProvider = apiKeyProvider; self.baseURL = baseURL; self.headers = headers
        self.queryParams = queryParams; self.transport = transport; self.batchResultDownloads = batchResultDownloads
    }
}

struct GatewayModelConfiguration: AIProviderHTTPConfiguration {
    var http: AIProviderHTTPClient
    var baseURL: String
    var batchResultMaxLineBytes: Int?

    func httpStatusError(_ response: AIHTTPResponse) -> AIError {
        gatewayAPICallError(provider: providerID, response: response, authMethod: authMethod)
    }

    /// The configured `ai-gateway-auth-method` header (`api-key` or `oidc`).
    var authMethod: String? { gatewayAuthMethod(from: headers) }
}

/// Upstream `createO11yHeaders`: Vercel deployment metadata forwarded with
/// model requests. Empty or missing environment values are omitted. The
/// per-request `ai-o11y-request-id` comes from Vercel's Node request context
/// (`x-vercel-id`), which has no Swift equivalent, so it is never sent.
func gatewayO11yHeaders(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var headers: [String: String] = [:]
    for (header, variable) in [
        ("ai-o11y-deployment-id", "VERCEL_DEPLOYMENT_ID"),
        ("ai-o11y-environment", "VERCEL_ENV"),
        ("ai-o11y-region", "VERCEL_REGION"),
        ("ai-o11y-project-id", "VERCEL_PROJECT_ID")
    ] {
        if let value = environment[variable], !value.isEmpty {
            headers[header] = value
        }
    }
    return headers
}
