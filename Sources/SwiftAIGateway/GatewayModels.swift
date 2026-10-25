import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public struct GatewayTakoDataSourceConfig: Equatable, Sendable {
    public var count: Int?
    public var includeContents: Bool?
    public var mode: String?
    public var contentFormat: String?
    public var maxRows: Int?
    public var nodeIDs: [String]
    public var strict: Bool?

    public init(
        count: Int? = nil,
        includeContents: Bool? = nil,
        mode: String? = nil,
        contentFormat: String? = nil,
        maxRows: Int? = nil,
        nodeIDs: [String] = [],
        strict: Bool? = nil
    ) {
        self.count = count
        self.includeContents = includeContents
        self.mode = mode
        self.contentFormat = contentFormat
        self.maxRows = maxRows
        self.nodeIDs = nodeIDs
        self.strict = strict
    }
}

public struct GatewayTakoWebSourceConfig: Equatable, Sendable {
    public var count: Int?
    public var includeContents: Bool?
    public var category: String?
    public var includeDomains: [String]
    public var excludeDomains: [String]
    public var snippetMaxCharacters: Int?
    public var highlights: Bool?
    public var articleContentMaxCharacters: Int?
    public var publishedAfter: String?
    public var publishedBefore: String?

    public init(
        count: Int? = nil,
        includeContents: Bool? = nil,
        category: String? = nil,
        includeDomains: [String] = [],
        excludeDomains: [String] = [],
        snippetMaxCharacters: Int? = nil,
        highlights: Bool? = nil,
        articleContentMaxCharacters: Int? = nil,
        publishedAfter: String? = nil,
        publishedBefore: String? = nil
    ) {
        self.count = count
        self.includeContents = includeContents
        self.category = category
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
        self.snippetMaxCharacters = snippetMaxCharacters
        self.highlights = highlights
        self.articleContentMaxCharacters = articleContentMaxCharacters
        self.publishedAfter = publishedAfter
        self.publishedBefore = publishedBefore
    }
}

public struct GatewayTakoSearchConfig: Equatable, Sendable {
    public var effort: String?
    public var dataSource: GatewayTakoDataSourceConfig?
    public var webSource: GatewayTakoWebSourceConfig?
    public var latitude: Double?
    public var longitude: Double?
    public var countryCode: String?
    public var locale: String?
    public var timezone: String?
    public var imageDarkMode: Bool?
    public var forceRefresh: Bool?
    public var includeRelated: Int?

    public init(
        effort: String? = nil,
        dataSource: GatewayTakoDataSourceConfig? = nil,
        webSource: GatewayTakoWebSourceConfig? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        countryCode: String? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        imageDarkMode: Bool? = nil,
        forceRefresh: Bool? = nil,
        includeRelated: Int? = nil
    ) {
        self.effort = effort
        self.dataSource = dataSource
        self.webSource = webSource
        self.latitude = latitude
        self.longitude = longitude
        self.countryCode = countryCode
        self.locale = locale
        self.timezone = timezone
        self.imageDarkMode = imageDarkMode
        self.forceRefresh = forceRefresh
        self.includeRelated = includeRelated
    }
}

public struct GatewayBrowserbaseFetchConfig: Equatable, Sendable {
    public var allowRedirects: Bool?
    public var allowInsecureSSL: Bool?
    public var proxies: Bool?
    public var format: String?
    public var schema: JSONValue?

    public init(
        allowRedirects: Bool? = nil,
        allowInsecureSSL: Bool? = nil,
        proxies: Bool? = nil,
        format: String? = nil,
        schema: JSONValue? = nil
    ) {
        self.allowRedirects = allowRedirects
        self.allowInsecureSSL = allowInsecureSSL
        self.proxies = proxies
        self.format = format
        self.schema = schema
    }
}

public struct GatewayBrowserbaseSearchConfig: Equatable, Sendable {
    public var numResults: Int?

    public init(numResults: Int? = nil) {
        self.numResults = numResults
    }
}

public enum GatewayTools {

    public static func perplexitySearch(
        maxResults: Int? = nil,
        maxTokensPerPage: Int? = nil,
        maxTokens: Int? = nil,
        country: String? = nil,
        searchDomainFilter: [String] = [],
        searchLanguageFilter: [String] = [],
        searchRecencyFilter: String? = nil
    ) -> JSONValue {
        var args: [String: JSONValue] = [:]
        if let maxResults { args["maxResults"] = .number(Double(maxResults)) }
        if let maxTokensPerPage { args["maxTokensPerPage"] = .number(Double(maxTokensPerPage)) }
        if let maxTokens { args["maxTokens"] = .number(Double(maxTokens)) }
        if let country { args["country"] = .string(country) }
        if !searchDomainFilter.isEmpty { args["searchDomainFilter"] = .array(searchDomainFilter) }
        if !searchLanguageFilter.isEmpty { args["searchLanguageFilter"] = .array(searchLanguageFilter) }
        if let searchRecencyFilter { args["searchRecencyFilter"] = .string(searchRecencyFilter) }
        return providerTool(id: "gateway.perplexity_search", name: "perplexity_search", args: args)
    }

    public static func parallelSearch(
        mode: String? = nil,
        maxResults: Int? = nil,
        includeDomains: [String] = [],
        excludeDomains: [String] = [],
        afterDate: String? = nil,
        maxCharsPerResult: Int? = nil,
        maxCharsTotal: Int? = nil,
        maxAgeSeconds: Int? = nil,
        timeoutSeconds: Int? = nil,
        disableCacheFallback: Bool? = nil,
        location: String? = nil
    ) -> JSONValue {
        var args: [String: JSONValue] = [:]
        if let mode { args["mode"] = .string(mode) }
        if let maxResults { args["maxResults"] = .number(Double(maxResults)) }
        let sourcePolicy = JSONValue.object([
            "includeDomains": includeDomains.isEmpty ? nil : .array(includeDomains),
            "excludeDomains": excludeDomains.isEmpty ? nil : .array(excludeDomains),
            "afterDate": afterDate.map(JSONValue.string)
        ])
        if sourcePolicy.objectValue?.isEmpty == false {
            args["sourcePolicy"] = sourcePolicy
        }
        let excerpts = JSONValue.object([
            "maxCharsPerResult": maxCharsPerResult.map { .number(Double($0)) }
        ])
        if excerpts.objectValue?.isEmpty == false {
            args["excerpts"] = excerpts
        }
        let fetchPolicy = JSONValue.object([
            "maxAgeSeconds": maxAgeSeconds.map { .number(Double($0)) },
            "timeoutSeconds": timeoutSeconds.map { .number(Double($0)) },
            "disableCacheFallback": disableCacheFallback.map(JSONValue.bool)
        ])
        if fetchPolicy.objectValue?.isEmpty == false {
            args["fetchPolicy"] = fetchPolicy
        }
        if let maxCharsTotal { args["maxCharsTotal"] = .number(Double(maxCharsTotal)) }
        if let location { args["location"] = .string(location) }
        return providerTool(id: "gateway.parallel_search", name: "parallel_search", args: args)
    }

    public static func takoSearch(_ config: GatewayTakoSearchConfig = GatewayTakoSearchConfig()) -> JSONValue {
        var args: [String: JSONValue] = [:]
        if let effort = config.effort { args["effort"] = .string(effort) }

        var sources: [String: JSONValue] = [:]
        if let data = config.dataSource {
            var value: [String: JSONValue] = [:]
            if let count = data.count { value["count"] = .number(Double(count)) }
            if let includeContents = data.includeContents { value["includeContents"] = .bool(includeContents) }
            if let mode = data.mode { value["mode"] = .string(mode) }
            if let contentFormat = data.contentFormat { value["contentFormat"] = .string(contentFormat) }
            if let maxRows = data.maxRows { value["maxRows"] = .number(Double(maxRows)) }
            if !data.nodeIDs.isEmpty { value["nodeIds"] = .array(data.nodeIDs) }
            if let strict = data.strict { value["strict"] = .bool(strict) }
            sources["data"] = .object(value)
        }
        if let web = config.webSource {
            var value: [String: JSONValue] = [:]
            if let count = web.count { value["count"] = .number(Double(count)) }
            if let includeContents = web.includeContents { value["includeContents"] = .bool(includeContents) }
            if let category = web.category { value["category"] = .string(category) }
            if !web.includeDomains.isEmpty { value["includeDomains"] = .array(web.includeDomains) }
            if !web.excludeDomains.isEmpty { value["excludeDomains"] = .array(web.excludeDomains) }
            if let snippetMaxCharacters = web.snippetMaxCharacters { value["snippetMaxChars"] = .number(Double(snippetMaxCharacters)) }
            if let highlights = web.highlights { value["highlights"] = .bool(highlights) }
            if let articleContentMaxCharacters = web.articleContentMaxCharacters { value["articleContentMaxChars"] = .number(Double(articleContentMaxCharacters)) }
            if let publishedAfter = web.publishedAfter { value["publishedAfter"] = .string(publishedAfter) }
            if let publishedBefore = web.publishedBefore { value["publishedBefore"] = .string(publishedBefore) }
            sources["web"] = .object(value)
        }
        if !sources.isEmpty { args["sources"] = .object(sources) }

        if let latitude = config.latitude, let longitude = config.longitude {
            args["location"] = .object([
                "latitude": .number(latitude),
                "longitude": .number(longitude)
            ])
        }
        if let countryCode = config.countryCode { args["countryCode"] = .string(countryCode) }
        if let locale = config.locale { args["locale"] = .string(locale) }
        if let timezone = config.timezone { args["timezone"] = .string(timezone) }
        var outputSettings: [String: JSONValue] = [:]
        if let imageDarkMode = config.imageDarkMode { outputSettings["imageDarkMode"] = .bool(imageDarkMode) }
        if let forceRefresh = config.forceRefresh { outputSettings["forceRefresh"] = .bool(forceRefresh) }
        if !outputSettings.isEmpty { args["outputSettings"] = .object(outputSettings) }
        if let includeRelated = config.includeRelated { args["includeRelated"] = .number(Double(includeRelated)) }

        return providerTool(id: "gateway.tako_search", name: "tako_search", args: args)
    }
    public static func browserbaseSearch(
        _ config: GatewayBrowserbaseSearchConfig = GatewayBrowserbaseSearchConfig()
    ) -> JSONValue {
        var args: [String: JSONValue] = [:]
        if let numResults = config.numResults { args["numResults"] = .number(Double(numResults)) }
        return providerTool(id: "gateway.browserbase_search", name: "browserbase_search", args: args)
    }

    public static func browserbaseFetch(
        _ config: GatewayBrowserbaseFetchConfig = GatewayBrowserbaseFetchConfig()
    ) -> JSONValue {
        var args: [String: JSONValue] = [:]
        if let allowRedirects = config.allowRedirects { args["allowRedirects"] = .bool(allowRedirects) }
        if let allowInsecureSSL = config.allowInsecureSSL { args["allowInsecureSsl"] = .bool(allowInsecureSSL) }
        if let proxies = config.proxies { args["proxies"] = .bool(proxies) }
        if let format = config.format { args["format"] = .string(format) }
        if let schema = config.schema { args["schema"] = schema }
        return providerTool(id: "gateway.browserbase_fetch", name: "browserbase_fetch", args: args)
    }


    private static func providerTool(id: String, name: String, args: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("provider"),
            "id": .string(id),
            "name": .string(name),
            "args": .object(args)
        ])
    }
}

public final class GatewayLanguageModel: LanguageModel, @unchecked Sendable {
    public let providerID: String
    public let modelID: String
    fileprivate let config: GatewayModelConfiguration

    init(modelID: String, config: GatewayModelConfiguration) {
        self.providerID = config.providerID
        self.modelID = modelID
        self.config = config
    }

    public func generate(_ request: LanguageModelRequest) async throws -> TextGenerationResult {
        let body = gatewayLanguageBody(for: request)
        let response = try await config.sendJSONResponse(path: "/language-model", modelID: modelID, body: body, headers: request.headers.mergingHeaders(modelHeaders(streaming: false)))
        let raw = response.json
        let text = parseGatewayText(from: raw)
        let toolCalls = gatewayToolCalls(from: raw["content"])
        let sources = gatewaySources(from: raw["content"])
        guard text != nil || !toolCalls.isEmpty else {
            throw AIError.invalidResponse(provider: providerID, message: "No text content found in Gateway language response.")
        }
        return TextGenerationResult(
            text: text ?? "",
            structuredOutputText: raw["structuredOutputText"]?.stringValue,
            finishReason: gatewayFinishReason(raw["finishReason"]?.stringValue ?? raw["finish_reason"]?.stringValue, hasToolCalls: !toolCalls.isEmpty),
            usage: tokenUsage(from: raw),
            toolCalls: toolCalls,
            sources: sources,
            rawValue: raw,
            warnings: gatewayLanguageWarnings(from: raw["warnings"]),
            responseMetadata: aiResponseMetadata(from: raw, response: response.response, modelID: modelID)
        )
    }

    public func stream(_ request: LanguageModelRequest) -> AsyncThrowingStream<LanguageStreamPart, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let httpRequest = try config.request(
                        path: "/language-model",
                        modelID: modelID,
                        body: gatewayLanguageBody(for: request),
                        headers: request.headers.mergingHeaders(modelHeaders(streaming: true)),
                        abortSignal: request.abortSignal
                    )
                    let response = try await config.streamRequest(httpRequest)
                    guard (200..<300).contains(response.statusCode) else {
                        throw gatewayAPICallError(provider: providerID, response: try await bufferedHTTPResponse(from: response, request: httpRequest))
                    }
                    let responseHead = httpResponseHead(from: response, request: httpRequest)
                    continuation.yield(.responseMetadata(aiResponseMetadata(response: responseHead, modelID: modelID)))
                    var toolBuffers: [String: GatewayStreamingToolCall] = [:]
                    var sawToolCalls = false
                    var activeTextID: String?
                    var activeReasoningID: String?
                    var finishReason: String? = "other"
                    var finishUsage: TokenUsage?
                    var finishProviderMetadata: [String: JSONValue] = [:]
                    var emittedStreamStart = false
                    for try await event in serverSentEvents(from: response.body) {
                        if event.data == "[DONE]" { break }
                        let raw = try decodeJSONBody(Data(event.data.utf8))
                        if request.includeRawChunks {
                            continuation.yield(.raw(raw))
                        }
                        let type = raw["type"]?.stringValue
                        if type == "stream-start", !emittedStreamStart {
                            emittedStreamStart = true
                            continuation.yield(.streamStart(warnings: gatewayLanguageWarnings(from: raw["warnings"])))
                        }
                        if request.includeRawChunks, type == "raw", let rawValue = raw["rawValue"] {
                            continuation.yield(.raw(rawValue))
                        }
                        if let delta = raw["delta"]?.stringValue
                            ?? raw["textDelta"]?.stringValue
                            ?? raw["text"]?.stringValue,
                           type == nil || type == "text-delta" || type == "delta" {
                            if let reasoningID = activeReasoningID {
                                continuation.yield(.reasoningEnd(id: reasoningID))
                                activeReasoningID = nil
                            }
                            let id = raw["id"]?.stringValue ?? activeTextID ?? "txt-0"
                            if activeTextID != id {
                                if let previousTextID = activeTextID {
                                    continuation.yield(.textEnd(id: previousTextID))
                                }
                                activeTextID = id
                                continuation.yield(.textStart(id: id, providerMetadata: gatewayProviderMetadata(raw["providerMetadata"])))
                            }
                            continuation.yield(.textDeltaPart(id: id, delta: delta, providerMetadata: gatewayProviderMetadata(raw["providerMetadata"])))
                        }
                        if type == "reasoning-delta", let delta = raw["delta"]?.stringValue ?? raw["textDelta"]?.stringValue {
                            if let textID = activeTextID {
                                continuation.yield(.textEnd(id: textID))
                                activeTextID = nil
                            }
                            let id = raw["id"]?.stringValue ?? activeReasoningID ?? "reasoning-0"
                            if activeReasoningID != id {
                                if let previousReasoningID = activeReasoningID {
                                    continuation.yield(.reasoningEnd(id: previousReasoningID))
                                }
                                activeReasoningID = id
                                continuation.yield(.reasoningStart(id: id, providerMetadata: gatewayProviderMetadata(raw["providerMetadata"])))
                            }
                            continuation.yield(.reasoningDeltaPart(id: id, delta: delta, providerMetadata: gatewayProviderMetadata(raw["providerMetadata"])))
                        }
                        if type == "source", let source = gatewaySource(from: raw, fallbackIndex: 0) {
                            continuation.yield(.source(source))
                        } else if type == "tool-input-start" {
                            let id = raw["id"]?.stringValue ?? raw["toolCallId"]?.stringValue ?? "tool-call-\(toolBuffers.count)"
                            let name = raw["toolName"]?.stringValue ?? raw["tool_name"]?.stringValue ?? raw["name"]?.stringValue ?? ""
                            toolBuffers[id] = GatewayStreamingToolCall(
                                id: id,
                                name: name,
                                arguments: "",
                                providerExecuted: raw["providerExecuted"]?.boolValue ?? false,
                                rawValue: raw
                            )
                            continuation.yield(.toolInputStart(
                                id: id,
                                name: name,
                                providerExecuted: raw["providerExecuted"]?.boolValue ?? false,
                                providerMetadata: gatewayProviderMetadata(raw["providerMetadata"])
                            ))
                        } else if type == "tool-input-delta" {
                            let id = raw["id"]?.stringValue ?? raw["toolCallId"]?.stringValue
                            let delta = raw["delta"]?.stringValue ?? raw["inputDelta"]?.stringValue ?? ""
                            if let id {
                                if var buffer = toolBuffers[id] {
                                    buffer.arguments += delta
                                    toolBuffers[id] = buffer
                                } else {
                                    toolBuffers[id] = GatewayStreamingToolCall(id: id, name: "", arguments: delta, providerExecuted: false, rawValue: raw)
                                }
                            }
                            continuation.yield(.toolCallDelta(id: id, name: toolBuffers[id ?? ""]?.name, argumentsDelta: delta, index: nil))
                            if let id, !delta.isEmpty {
                                continuation.yield(.toolInputDelta(id: id, delta: delta, providerMetadata: gatewayProviderMetadata(raw["providerMetadata"])))
                            }
                        } else if type == "tool-input-end" {
                            let id = raw["id"]?.stringValue ?? raw["toolCallId"]?.stringValue
                            if let id, let buffer = toolBuffers.removeValue(forKey: id), !buffer.name.isEmpty {
                                sawToolCalls = true
                                continuation.yield(.toolInputEnd(id: id, providerMetadata: gatewayProviderMetadata(raw["providerMetadata"])))
                                continuation.yield(.toolCall(buffer.toolCall))
                            }
                        } else if type == "tool-call", let toolCall = gatewayToolCall(from: raw, fallbackIndex: toolBuffers.count) {
                            sawToolCalls = true
                            continuation.yield(.toolInputStart(id: toolCall.id, name: toolCall.name, providerExecuted: toolCall.providerExecuted, providerMetadata: toolCall.providerMetadata))
                            continuation.yield(.toolCallDelta(id: toolCall.id, name: toolCall.name, argumentsDelta: toolCall.arguments, index: nil))
                            if !toolCall.arguments.isEmpty {
                                continuation.yield(.toolInputDelta(id: toolCall.id, delta: toolCall.arguments, providerMetadata: toolCall.providerMetadata))
                            }
                            continuation.yield(.toolInputEnd(id: toolCall.id, providerMetadata: toolCall.providerMetadata))
                            continuation.yield(.toolCall(toolCall))
                        }
                        if type == "finish" || type == "finish-step" {
                            let hasToolCalls = sawToolCalls || !toolBuffers.isEmpty
                            for buffer in toolBuffers.values where !buffer.name.isEmpty {
                                continuation.yield(.toolInputEnd(id: buffer.id))
                                continuation.yield(.toolCall(buffer.toolCall))
                            }
                            toolBuffers.removeAll()
                            if let textID = activeTextID {
                                continuation.yield(.textEnd(id: textID))
                                activeTextID = nil
                            }
                            if let reasoningID = activeReasoningID {
                                continuation.yield(.reasoningEnd(id: reasoningID))
                                activeReasoningID = nil
                            }
                            if type == "finish" {
                                finishReason = gatewayFinishReason(
                                    raw["finishReason"]?.stringValue ?? raw["finish_reason"]?.stringValue,
                                    hasToolCalls: hasToolCalls
                                )
                                finishUsage = tokenUsage(from: raw)
                                finishProviderMetadata = gatewayProviderMetadata(raw["providerMetadata"])
                                break
                            }
                        }
                    }
                    if let textID = activeTextID {
                        continuation.yield(.textEnd(id: textID))
                    }
                    if let reasoningID = activeReasoningID {
                        continuation.yield(.reasoningEnd(id: reasoningID))
                    }
                    continuation.yield(.finishMetadata(
                        reason: finishReason,
                        usage: finishUsage,
                        providerMetadata: finishProviderMetadata
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    fileprivate func gatewayLanguageBody(for request: LanguageModelRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "prompt": .array(request.messages.map { message in
                .object([
                    "role": .string(message.role.rawValue),
                    "content": .array(message.content.map { part in
                        switch part {
                        case let .text(text, _):
                            return .object(["type": .string("text"), "text": .string(text)])
                        case let .reasoning(text, providerMetadata):
                            return .object(["type": .string("reasoning"), "text": .string(text), "providerMetadata": .object(providerMetadata)])
                        case let .imageURL(url, _):
                            return .object([
                                "type": .string("file"),
                                "data": .object(["type": .string("url"), "url": .string(url)])
                            ])
                        case let .data(mimeType, data, _):
                            return .object([
                                "type": .string("file"),
                                "mediaType": .string(mimeType),
                                "data": .object(["type": .string("data"), "data": .string(data.base64EncodedString())])
                            ])
                        case let .file(mimeType, data, filename, _):
                            var file: [String: JSONValue] = [
                                "type": .string("file"),
                                "mediaType": .string(mimeType),
                                "data": .object(["type": .string("data"), "data": .string(data.base64EncodedString())])
                            ]
                            if let filename { file["filename"] = .string(filename) }
                            return .object(file)
                        case let .reasoningFile(file):
                            var output: [String: JSONValue] = [
                                "type": .string("reasoning-file"),
                                "mediaType": .string(file.mediaType)
                            ]
                            if let id = file.id { output["id"] = .string(id) }
                            if let filename = file.filename { output["filename"] = .string(filename) }
                            if let data = file.data {
                                output["data"] = .object(["type": .string("data"), "data": .string(data.base64EncodedString())])
                            } else if let url = file.url {
                                output["data"] = .object(["type": .string("url"), "url": .string(url)])
                            }
                            return .object(output)
                        case let .custom(value, providerMetadata):
                            return .object(["type": .string("custom"), "value": value, "providerMetadata": .object(providerMetadata)])
                        case let .providerReference(mimeType, reference, _, _):
                            return .object([
                                "type": .string("file"),
                                "mediaType": .string(mimeType),
                                "data": .object(["type": .string("reference"), "reference": .object(reference.mapValues(JSONValue.string))])
                            ])
                        case let .toolCall(call):
                            return .object([
                                "type": .string("tool-call"),
                                "toolCallId": .string(call.id),
                                "toolName": .string(call.name),
                                "args": gatewayToolArguments(call.arguments)
                            ])
                        case let .toolResult(result):
                            return .object([
                                "type": .string("tool-result"),
                                "toolCallId": .string(result.toolCallID),
                                "toolName": .string(result.toolName),
                                "result": result.modelOutput ?? result.result
                            ])
                        case .toolApprovalRequest, .toolApprovalResponse:
                            return .object(["type": .string("text"), "text": .string("")])
                        }
                    })
                ])
            })
        ]
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if let topP = request.topP { body["topP"] = .number(topP) }
        if let topK = request.topK { body["topK"] = .number(Double(topK)) }
        if let presencePenalty = request.presencePenalty { body["presencePenalty"] = .number(presencePenalty) }
        if let frequencyPenalty = request.frequencyPenalty { body["frequencyPenalty"] = .number(frequencyPenalty) }
        if let seed = request.seed { body["seed"] = .number(Double(seed)) }
        if let maxOutputTokens = request.maxOutputTokens { body["maxOutputTokens"] = .number(Double(maxOutputTokens)) }
        if !request.stopSequences.isEmpty { body["stopSequences"] = .array(request.stopSequences) }
        if let reasoning = request.reasoning { body["reasoning"] = .string(reasoning) }
        if !request.providerOptions.isEmpty { body["providerOptions"] = .object(request.providerOptions) }
        let tools = gatewayTools(from: request.tools)
        if !tools.isEmpty {
            body["tools"] = .array(tools)
            if let toolChoice = gatewayToolChoice(
                from: request.toolChoice ?? request.extraBody["toolChoice"]
            ) {
                body["toolChoice"] = toolChoice
            }
        }
        body.merge(request.extraBody) { _, new in new }
        return .object(body)
    }

    private func modelHeaders(streaming: Bool) -> [String: String] {
        [
            "ai-language-model-specification-version": "4",
            "ai-language-model-id": modelID,
            "ai-language-model-streaming": String(streaming)
        ]
    }
}

extension GatewayLanguageModel: BatchLanguageModel {
    public func startBatch(
        _ options: AIBatchStartOptions<AILanguageModelBatchRequest>
    ) async throws -> AIBatchStartResult {
        try options.abortSignal?.throwIfAborted()
        let requestModelIDs = Set(options.requests.map { $0.modelID ?? modelID })
        guard requestModelIDs.count <= 1 else {
            let values = Array(requestModelIDs).sorted()
            throw AIError.invalidArgument(
                argument: "requests",
                message: "The AI Gateway Batch API requires all requests in a batch to use the same model. Found \"\(values[0])\" and \"\(values[1])\"."
            )
        }
        let forwardedProviderOptions = gatewayBatchProviderOptionsWithoutIdempotencyKey(options.providerOptions)
        var body: [String: JSONValue] = [
            // Keep the model-bound compatibility field while also emitting
            // the provider-owned per-request discriminator expected by V4.
            "modelId": .string(modelID),
            "requests": .array(options.requests.map { request in
                .object([
                    "id": .string(request.id),
                    "type": "text",
                    "modelId": .string(request.modelID ?? modelID),
                    "options": gatewayLanguageBody(for: request.request)
                ])
            })
        ]
        if !forwardedProviderOptions.isEmpty {
            body["providerOptions"] = .object(forwardedProviderOptions)
        }
        if let webhookURL = options.webhookURL {
            body["callbackUrl"] = .string(webhookURL)
        }

        let request = try config.request(
            path: "/batch/start",
            modelID: modelID,
            body: .object(body),
            headers: gatewayBatchHeaders(
                options.headers,
                modelID: modelID,
                explicitIdempotencyKey: options.idempotencyKey,
                providerOptions: options.providerOptions
            ),
            abortSignal: options.abortSignal
        )
        let response = try await config.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        guard let batchID = raw["batchId"]?.stringValue else {
            throw AIError.invalidResponse(provider: providerID, message: "Gateway batch start response is missing batchId.")
        }
        return AIBatchStartResult(
            batchID: batchID,
            status: try gatewayBatchStatus(from: raw, providerID: providerID),
            warnings: gatewayBatchWarnings(from: raw["warnings"])
        )
    }

    public func getBatchStatus(_ options: AIBatchOperationOptions) async throws -> AIBatchStatus {
        try options.abortSignal?.throwIfAborted()
        let request = try config.request(
            path: "/batch/status",
            modelID: modelID,
            body: .object(["batchId": .string(options.batchID)]),
            headers: gatewayBatchHeaders(options.headers, modelID: modelID),
            abortSignal: options.abortSignal
        )
        let response = try await config.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(provider: providerID, response: response)
        }
        return try gatewayBatchStatus(from: response.jsonValue(), providerID: providerID)
    }

    public func getBatchResults(
        _ options: AIBatchOperationOptions
    ) async throws -> AsyncThrowingStream<AIBatchItemResult<TextGenerationResult>, Error> {
        try options.abortSignal?.throwIfAborted()
        let maxLineBytes = try aiBatchResultLineLimit(config.batchResultMaxLineBytes)
        let request = try config.request(
            path: "/batch/results",
            modelID: modelID,
            body: .object(["batchId": .string(options.batchID)]),
            headers: gatewayBatchHeaders(options.headers, modelID: modelID),
            abortSignal: options.abortSignal
        )
        let transport = try requireStreamingTransport(config.transport, providerID: providerID)
        let response = try await transport.stream(request)
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(
                provider: providerID,
                response: try await bufferedHTTPResponse(from: response, request: request)
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await yieldGatewayBatchResultLines(
                        response.body,
                        providerID: providerID,
                        abortSignal: options.abortSignal,
                        url: request.url.absoluteString,
                        maxLineBytes: maxLineBytes,
                        cancelBody: response.cancelBody,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                response.cancelBody()
                task.cancel()
            }
        }
    }
}


/// Provider-owned, text-only Gateway Batch V4 service.
public final class GatewayBatchProvider: AIBatchProvider, @unchecked Sendable {
    public let providerID: String
    public let supportedURLs: [String: [AISupportedURLPattern]] = [
        "*/*": [AISupportedURLPattern { _ in true }]
    ]
    private let config: GatewayModelConfiguration

    init(config: GatewayModelConfiguration) {
        self.providerID = "\(config.providerID).batch"
        self.config = config
    }

    public func startBatch(
        _ options: AIBatchStartOptions<AIBatchRequest>
    ) async throws -> AIBatchStartResult {
        var requests: [TextBatchRequest] = []
        requests.reserveCapacity(options.requests.count)
        for request in options.requests {
            guard case let .text(text) = request else {
                throw AIError.invalidArgument(
                    argument: "requests",
                    message: "The AI Gateway Batch API does not support batch requests with type \"image\"."
                )
            }
            guard let modelID = text.modelID, !modelID.isEmpty else {
                throw AIError.invalidArgument(
                    argument: "requests",
                    message: "Gateway text batch request \"\(text.id)\" must specify a modelID."
                )
            }
            requests.append(text)
        }
        guard let modelID = requests.first?.modelID else {
            throw AIError.invalidArgument(
                argument: "requests",
                message: "The AI Gateway Batch API requires at least one request."
            )
        }
        if let different = requests.first(where: { $0.modelID != modelID })?.modelID {
            throw AIError.invalidArgument(
                argument: "requests",
                message: "The AI Gateway Batch API requires all requests in a batch to use the same model. Found \"\(modelID)\" and \"\(different)\"."
            )
        }
        let model = GatewayLanguageModel(modelID: modelID, config: config)
        let forwardedOptions = gatewayBatchProviderOptionsWithoutIdempotencyKey(options.providerOptions)
        var body: [String: JSONValue] = [
            "requests": .array(requests.map { request in
                .object([
                    "id": .string(request.id),
                    "type": "text",
                    "modelId": .string(request.modelID ?? modelID),
                    "options": model.gatewayLanguageBody(for: request.request)
                ])
            })
        ]
        if !forwardedOptions.isEmpty { body["providerOptions"] = .object(forwardedOptions) }
        if let webhookURL = options.webhookURL { body["callbackUrl"] = .string(webhookURL) }
        let request = try config.request(
            path: "/batch/start",
            modelID: modelID,
            body: .object(body),
            headers: gatewayBatchHeaders(
                options.headers,
                modelID: modelID,
                explicitIdempotencyKey: options.idempotencyKey,
                providerOptions: options.providerOptions
            ),
            abortSignal: options.abortSignal
        )
        let response = try await config.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        guard let batchID = raw["batchId"]?.stringValue else {
            throw AIError.invalidResponse(provider: providerID, message: "Gateway batch start response is missing batchId.")
        }
        return AIBatchStartResult(
            batchID: batchID,
            status: try gatewayBatchStatus(from: raw, providerID: providerID),
            warnings: gatewayBatchWarnings(from: raw["warnings"])
        )
    }

    public func getBatchStatus(_ options: AIBatchOperationOptions) async throws -> AIBatchStatus {
        try options.abortSignal?.throwIfAborted()
        let request = try config.request(
            path: "/batch/status",
            modelID: "batch",
            body: .object(["batchId": .string(options.batchID)]),
            headers: options.headers,
            abortSignal: options.abortSignal
        )
        let response = try await config.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(provider: providerID, response: response)
        }
        return try gatewayBatchStatus(from: response.jsonValue(), providerID: providerID)
    }

    public func getBatchResults(
        _ options: AIBatchOperationOptions
    ) async throws -> AsyncThrowingStream<AIBatchV4ItemResult, Error> {
        try options.abortSignal?.throwIfAborted()
        let maxLineBytes = try aiBatchResultLineLimit(config.batchResultMaxLineBytes)
        let request = try config.request(
            path: "/batch/results",
            modelID: "batch",
            body: .object(["batchId": .string(options.batchID)]),
            headers: options.headers,
            abortSignal: options.abortSignal
        )
        let transport = try requireStreamingTransport(config.transport, providerID: providerID)
        let response = try await transport.stream(request)
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(
                provider: providerID,
                response: try await bufferedHTTPResponse(from: response, request: request)
            )
        }
        let providerID = self.providerID
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await aiForEachBatchResultLine(response.body,
                        url: request.url.absoluteString,
                        maxLineBytes: maxLineBytes,
                        abortSignal: options.abortSignal,
                        cancelBody: response.cancelBody
                    ) { line in
                        if let item = try gatewayBatchResultItem(from: line, providerID: providerID) {
                            continuation.yield(.text(item))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                response.cancelBody()
                task.cancel()
            }
        }
    }

    public func cancelBatch(_ options: AIBatchOperationOptions) async throws -> AIBatchCancelResult {
        try options.abortSignal?.throwIfAborted()
        let request = try config.request(
            path: "/batch/cancel",
            modelID: "batch",
            body: .object(["batchId": .string(options.batchID)]),
            headers: options.headers,
            abortSignal: options.abortSignal
        )
        let response = try await config.transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayAPICallError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        _ = try gatewayBatchStatus(from: raw, providerID: providerID)
        return AIBatchCancelResult(providerMetadata: gatewayProviderMetadata(raw["providerMetadata"]))
    }
}

private func gatewayBatchHeaders(
    _ headers: [String: String],
    modelID: String,
    explicitIdempotencyKey: String? = nil,
    providerOptions: [String: JSONValue] = [:]
) -> [String: String] {
    var output = headers
    output["ai-model-id"] = modelID
    if normalizeHeaders(output)["idempotency-key"] == nil,
       let key = explicitIdempotencyKey ?? gatewayBatchProviderIdempotencyKey(providerOptions) {
        output["idempotency-key"] = key
    }
    return output
}

private func gatewayBatchProviderIdempotencyKey(_ providerOptions: [String: JSONValue]) -> String? {
    guard let key = providerOptions["gateway"]?["idempotencyKey"]?.stringValue,
          !key.isEmpty else {
        return nil
    }
    return key
}

private func gatewayBatchProviderOptionsWithoutIdempotencyKey(
    _ providerOptions: [String: JSONValue]
) -> [String: JSONValue] {
    guard let gatewayOptions = providerOptions["gateway"]?.objectValue,
          gatewayOptions["idempotencyKey"] != nil else {
        return providerOptions
    }
    var output = providerOptions
    var forwardedGatewayOptions = gatewayOptions
    forwardedGatewayOptions.removeValue(forKey: "idempotencyKey")
    if forwardedGatewayOptions.isEmpty {
        output.removeValue(forKey: "gateway")
    } else {
        output["gateway"] = .object(forwardedGatewayOptions)
    }
    return output
}

private func gatewayBatchStatus(from raw: JSONValue, providerID: String) throws -> AIBatchStatus {
    guard let statusString = raw["status"]?.stringValue,
          let status = AIBatchLifecycleStatus(rawValue: statusString) else {
        throw AIError.invalidResponse(provider: providerID, message: "Gateway batch response has an invalid status.")
    }

    let counts: AIBatchRequestCounts?
    if let value = raw["requestCounts"], value != .null {
        counts = normalizedBatchRequestCounts(
            total: normalizedBatchJSONInteger(value["total"]),
            pending: normalizedBatchJSONInteger(value["pending"]),
            completed: normalizedBatchJSONInteger(value["completed"]),
            failed: normalizedBatchJSONInteger(value["failed"])
        )
    } else {
        counts = nil
    }

    let error: AIBatchError?
    if let value = raw["error"], value != .null {
        guard let message = value["message"]?.stringValue else {
            throw AIError.invalidResponse(provider: providerID, message: "Gateway batch error is missing message.")
        }
        error = AIBatchError(
            message: message,
            type: value["type"]?.stringValue,
            code: value["code"]?.stringValue,
            statusCode: value["statusCode"]?.intValue
        )
    } else {
        error = nil
    }

    return AIBatchStatus(
        status: status,
        rawStatus: raw["rawStatus"]?.stringValue,
        requestCounts: counts,
        error: error,
        createdAt: raw["createdAt"]?.stringValue,
        expiresAt: raw["expiresAt"]?.stringValue,
        providerMetadata: gatewayProviderMetadata(raw["providerMetadata"])
    )
}

private func gatewayBatchWarnings(from value: JSONValue?) -> [AIBatchWarning] {
    value?.arrayValue?.map { item in
        AIBatchWarning(
            requestID: item["requestId"]?.stringValue,
            warning: gatewayBatchWarning(from: item["warning"] ?? .null)
        )
    } ?? []
}

private func gatewayLanguageWarnings(from value: JSONValue?) -> [AIWarning] {
    value?.arrayValue?.map(gatewayBatchWarning) ?? []
}

private func gatewayBatchWarning(from value: JSONValue) -> AIWarning {
    if let object = value.objectValue {
        return AIWarning(
            type: object["type"]?.stringValue ?? "other",
            feature: object["feature"]?.stringValue,
            setting: object["setting"]?.stringValue,
            message: object["message"]?.stringValue ?? object["details"]?.stringValue
        )
    }
    return AIWarning(type: "other", message: getErrorMessage(value))
}

private func yieldGatewayBatchResultLines(
    _ body: AsyncThrowingStream<Data, Error>,
    providerID: String,
    abortSignal: AIAbortSignal?,
    url: String,
    maxLineBytes: Int,
    cancelBody: @Sendable () -> Void,
    continuation: AsyncThrowingStream<AIBatchItemResult<TextGenerationResult>, Error>.Continuation
) async throws {
    try await aiForEachBatchResultLine(body, url: url, maxLineBytes: maxLineBytes, abortSignal: abortSignal, cancelBody: cancelBody) { line in
        if let item = try gatewayBatchResultItem(from: line, providerID: providerID) {
            continuation.yield(item)
        }
    }
}

private func gatewayBatchResultItem(
    from data: Data,
    providerID: String
) throws -> AIBatchItemResult<TextGenerationResult>? {
    var line = data
    if line.last == 0x0D { line.removeLast() }
    guard let text = String(data: line, encoding: .utf8) else {
        throw AIError.invalidResponse(provider: providerID, message: "Gateway batch result line is not valid UTF-8.")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let raw = try secureJSONParse(text)
    guard let id = raw["id"]?.stringValue,
          let status = raw["status"]?.stringValue else {
        throw AIError.invalidResponse(provider: providerID, message: "Gateway batch result line is missing id or status.")
    }
    let providerMetadata = gatewayProviderMetadata(raw["providerMetadata"])
    let error = gatewayBatchItemError(raw["error"])

    switch status {
    case "succeeded":
        guard let result = raw["result"], result.objectValue != nil else {
            throw AIError.invalidResponse(provider: providerID, message: "Gateway succeeded batch item is missing result.")
        }
        return .succeeded(id: id, result: gatewayBatchTextResult(from: result))
    case "failed":
        return .failed(
            id: id,
            error: error ?? AIBatchError(message: "Gateway batch item failed."),
            providerMetadata: providerMetadata
        )
    case "cancelled":
        return .cancelled(id: id, error: error, providerMetadata: providerMetadata)
    case "expired":
        return .expired(id: id, error: error, providerMetadata: providerMetadata)
    default:
        throw AIError.invalidResponse(provider: providerID, message: "Gateway batch result has invalid status \"\(status)\".")
    }
}

private func gatewayBatchItemError(_ value: JSONValue?) -> AIBatchError? {
    guard let value, value != .null else { return nil }
    return AIBatchError(
        message: value["message"]?.stringValue ?? "Gateway batch item failed.",
        type: value["type"]?.stringValue,
        code: value["code"]?.stringValue,
        statusCode: value["statusCode"]?.intValue
    )
}

private func gatewayBatchTextResult(from raw: JSONValue) -> TextGenerationResult {
    let content = gatewayBatchResultContent(from: raw["content"])
    let text = content.compactMap { part -> String? in
        guard case let .text(text, _) = part else { return nil }
        return text
    }.joined()
    let reasoning = content.compactMap { part -> String? in
        guard case let .reasoning(text, _) = part else { return nil }
        return text
    }.joined()
    let hasToolCalls = content.contains { part in
        if case .toolCall = part { return true }
        return false
    }
    let finishReason = raw["finishReason"]?.stringValue
        ?? raw["finishReason"]?["unified"]?.stringValue
    let response = raw["response"]
    return TextGenerationResult(
        text: text,
        content: content,
        reasoning: reasoning,
        // Gateway Batch V4 results are already normalized server-side. Keep an
        // explicit unified finish reason even when the ordered content includes
        // tool calls; only infer it for older responses that omit the field.
        finishReason: finishReason.map { $0 == "tool_calls" ? "tool-calls" : $0 }
            ?? (hasToolCalls ? "tool-calls" : nil),
        usage: gatewayBatchUsage(from: raw),
        providerMetadata: gatewayProviderMetadata(raw["providerMetadata"]),
        rawValue: raw,
        warnings: (raw["warnings"]?.arrayValue ?? []).map(gatewayBatchWarning),
        responseMetadata: AIResponseMetadata(
            id: response?["id"]?.stringValue,
            timestamp: response?["timestamp"]?.stringValue.flatMap(gatewayBatchDate),
            modelID: response?["modelId"]?.stringValue ?? response?["modelID"]?.stringValue,
            headers: response?["headers"]?.objectValue?.compactMapValues(\.stringValue) ?? [:],
            body: response
        )
    )
}

private func gatewayBatchResultContent(from value: JSONValue?) -> [AIResultContentPart] {
    let parts = gatewayContentParts(value)
    var toolCallsByID: [String: AIToolCall] = [:]
    for part in parts {
        guard let call = gatewayBatchToolCall(from: part), toolCallsByID[call.id] == nil else { continue }
        toolCallsByID[call.id] = call
    }

    return parts.map { part in
        gatewayBatchResultContentPart(part, toolCallsByID: toolCallsByID)
    }
}

private func gatewayBatchResultContentPart(
    _ part: JSONValue,
    toolCallsByID: [String: AIToolCall]
) -> AIResultContentPart {
    let providerMetadata = gatewayProviderMetadata(
        part["providerMetadata"] ?? part["provider_metadata"]
    )
    switch part["type"]?.stringValue {
    case "text":
        guard let text = part["text"]?.stringValue else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .text(text, providerMetadata: providerMetadata)
    case "reasoning":
        guard let text = part["text"]?.stringValue else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .reasoning(text, providerMetadata: providerMetadata)
    case "file":
        guard let file = gatewayBatchFile(from: part) else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .file(file)
    case "reasoning-file":
        guard let file = gatewayBatchFile(from: part) else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .reasoningFile(file)
    case "source":
        guard let source = gatewaySource(from: part, fallbackIndex: 0) else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .source(source)
    case "custom":
        guard let kind = part["kind"]?.stringValue else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .custom(
            .object(["kind": .string(kind)]),
            providerMetadata: providerMetadata
        )
    case "tool-call":
        guard let call = gatewayBatchToolCall(from: part) else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .toolCall(call)
    case "tool-result":
        guard let result = gatewayBatchToolResult(from: part) else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .toolResult(result)
    case "tool-approval-request":
        guard let request = gatewayBatchToolApprovalRequest(
            from: part,
            toolCallsByID: toolCallsByID
        ) else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .toolApprovalRequest(request)
    case "tool-approval-response":
        guard let response = gatewayBatchToolApprovalResponse(from: part) else {
            return .custom(part, providerMetadata: providerMetadata)
        }
        return .toolApprovalResponse(response)
    default:
        // Gateway validates only the batch item envelope and otherwise passes
        // provider output through. Preserve future content parts losslessly in
        // Swift's provider-specific escape hatch instead of dropping them.
        return .custom(part, providerMetadata: providerMetadata)
    }
}

private func gatewayBatchToolCall(from part: JSONValue) -> AIToolCall? {
    guard part["type"]?.stringValue == "tool-call",
          let id = part["toolCallId"]?.stringValue ?? part["tool_call_id"]?.stringValue,
          let name = part["toolName"]?.stringValue ?? part["tool_name"]?.stringValue,
          let input = part["input"]?.stringValue else {
        return nil
    }
    return AIToolCall(
        id: id,
        name: name,
        arguments: input,
        providerExecuted: part["providerExecuted"]?.boolValue ?? false,
        dynamic: part["dynamic"]?.boolValue ?? false,
        title: part["title"]?.stringValue,
        providerMetadata: gatewayProviderMetadata(
            part["providerMetadata"] ?? part["provider_metadata"]
        ),
        rawValue: part
    )
}

private func gatewayBatchToolResult(from part: JSONValue) -> AIToolResult? {
    guard part["type"]?.stringValue == "tool-result",
          let toolCallID = part["toolCallId"]?.stringValue ?? part["tool_call_id"]?.stringValue,
          let toolName = part["toolName"]?.stringValue ?? part["tool_name"]?.stringValue,
          let result = part["result"], result != .null else {
        return nil
    }
    return AIToolResult(
        toolCallID: toolCallID,
        toolName: toolName,
        result: result,
        modelOutput: part["modelOutput"] ?? part["model_output"],
        isError: part["isError"]?.boolValue ?? part["is_error"]?.boolValue ?? false,
        preliminary: part["preliminary"]?.boolValue ?? false,
        dynamic: part["dynamic"]?.boolValue ?? false,
        providerExecuted: part["providerExecuted"]?.boolValue ?? true,
        providerMetadata: gatewayProviderMetadata(
            part["providerMetadata"] ?? part["provider_metadata"]
        )
    )
}

private func gatewayBatchToolApprovalRequest(
    from part: JSONValue,
    toolCallsByID: [String: AIToolCall]
) -> AIToolApprovalRequest? {
    guard part["type"]?.stringValue == "tool-approval-request",
          let approvalID = part["approvalId"]?.stringValue ?? part["approval_id"]?.stringValue,
          let toolCallID = part["toolCallId"]?.stringValue ?? part["tool_call_id"]?.stringValue else {
        return nil
    }
    let call = toolCallsByID[toolCallID]
    guard let toolName = part["toolName"]?.stringValue
        ?? part["tool_name"]?.stringValue
        ?? call?.name else {
        return nil
    }
    let arguments = part["input"]?.stringValue
        ?? part["arguments"]?.stringValue
        ?? call?.arguments
        ?? "{}"
    return AIToolApprovalRequest(
        id: approvalID,
        toolName: toolName,
        arguments: arguments,
        toolCallID: toolCallID,
        isAutomatic: part["isAutomatic"]?.boolValue ?? part["is_automatic"]?.boolValue ?? false,
        providerMetadata: gatewayProviderMetadata(
            part["providerMetadata"] ?? part["provider_metadata"]
        )
    )
}

private func gatewayBatchToolApprovalResponse(from part: JSONValue) -> AIToolApprovalResponse? {
    guard part["type"]?.stringValue == "tool-approval-response",
          let approvalID = part["approvalId"]?.stringValue ?? part["approval_id"]?.stringValue,
          let approved = part["approved"]?.boolValue else {
        return nil
    }
    return AIToolApprovalResponse(
        id: approvalID,
        approved: approved,
        reason: part["reason"]?.stringValue,
        providerExecuted: part["providerExecuted"]?.boolValue ?? false,
        providerMetadata: gatewayProviderMetadata(
            part["providerMetadata"] ?? part["provider_metadata"]
        )
    )
}

private func gatewayBatchFile(from part: JSONValue) -> AIStreamFile? {
    guard let mediaType = part["mediaType"]?.stringValue ?? part["media_type"]?.stringValue else {
        return nil
    }
    let payload = part["data"]
    var data: Data?
    var url: String?
    var providerReference: AIProviderReference?

    switch payload?["type"]?.stringValue {
    case "data":
        data = gatewayBatchFileData(payload?["data"])
    case "url":
        url = payload?["url"]?.stringValue
    case "reference":
        if let reference = payload?["reference"]?.objectValue {
            let stringReference = reference.compactMapValues(\.stringValue)
            if stringReference.count == reference.count {
                providerReference = stringReference
            }
        }
    case "text":
        data = payload?["text"]?.stringValue.map { Data($0.utf8) }
    default:
        if let directURL = payload?.stringValue, URL(string: directURL)?.scheme != nil {
            url = directURL
        } else {
            data = gatewayBatchFileData(payload)
        }
    }

    return AIStreamFile(
        id: part["id"]?.stringValue,
        mediaType: mediaType,
        data: data,
        url: url,
        filename: part["filename"]?.stringValue,
        providerReference: providerReference,
        providerMetadata: gatewayProviderMetadata(
            part["providerMetadata"] ?? part["provider_metadata"]
        ),
        rawValue: part
    )
}

private func gatewayBatchFileData(_ value: JSONValue?) -> Data? {
    if let base64 = value?.stringValue {
        return Data(base64Encoded: base64)
    }
    guard let values = value?.arrayValue else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(values.count)
    for value in values {
        guard let number = value.doubleValue,
              number.isFinite,
              number.rounded(.towardZero) == number,
              (0...255).contains(number) else {
            return nil
        }
        bytes.append(UInt8(number))
    }
    return Data(bytes)
}

private func gatewayBatchUsage(from raw: JSONValue) -> TokenUsage? {
    guard let usage = raw["usage"] else { return nil }
    let input = usage["inputTokens"]
    let output = usage["outputTokens"]
    guard input?.objectValue != nil || output?.objectValue != nil else {
        return tokenUsage(from: raw)
    }
    let inputTotal = input?["total"]?.intValue
    let outputTotal = output?["total"]?.intValue
    let totalTokens = inputTotal.flatMap { input in outputTotal.map { input + $0 } }
    return TokenUsage(
        inputTokens: inputTotal,
        outputTokens: outputTotal,
        totalTokens: totalTokens,
        inputTokensNoCache: input?["noCache"]?.intValue,
        inputTokensCacheRead: input?["cacheRead"]?.intValue,
        inputTokensCacheWrite: input?["cacheWrite"]?.intValue,
        outputTextTokens: output?["text"]?.intValue,
        outputReasoningTokens: output?["reasoning"]?.intValue,
        rawValue: usage
    )
}

private func gatewayBatchDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func gatewayToolArguments(_ arguments: String) -> JSONValue {
    (try? decodeJSONBody(Data(arguments.utf8))) ?? .object([:])
}