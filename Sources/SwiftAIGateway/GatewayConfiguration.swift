import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

public struct GatewayProviderSettings: Sendable {
    public var apiKey: String?
    public var baseURL: String?
    public var headers: [String: String]
    public var queryParams: [String: String]
    public var transport: any AITransport
    public var batchResultDownloads: AIBatchResultDownloadSettings?

    public init(apiKey: String? = nil, baseURL: String? = nil, headers: [String: String] = [:],
                queryParams: [String: String] = [:], transport: any AITransport = URLSessionTransport.shared,
                batchResultDownloads: AIBatchResultDownloadSettings? = nil) {
        self.apiKey = apiKey; self.baseURL = baseURL; self.headers = headers
        self.queryParams = queryParams; self.transport = transport; self.batchResultDownloads = batchResultDownloads
    }
}

struct GatewayModelConfiguration: AIProviderHTTPConfiguration {
    var http: AIProviderHTTPClient
    var baseURL: String
    var batchResultMaxLineBytes: Int?

    func httpStatusError(_ response: AIHTTPResponse) -> AIError {
        gatewayAPICallError(provider: providerID, response: response)
    }
}
