@testable import SwiftAIGateway
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Test func gatewayLanguageUsesGatewayEndpointAndModelHeaders() async throws {
    let transport = RecordingTransport(response: jsonResponse("""
    {"content":[{"type":"text","text":"via gateway"}],"finishReason":"stop"}
    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport), teamIDOrSlug: "team_123")
    let model = try provider.languageModel("openai/gpt-4.1-mini")

    let result = try await model.generate(LanguageModelRequest(messages: [.user("Hi")]))

    #expect(result.text == "via gateway")
    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://ai-gateway.vercel.sh/v4/ai/language-model")
    #expect(request.headers["authorization"] == "Bearer gateway-key")
    #expect(request.headers["x-vercel-ai-gateway-team"] == "team_123")
    #expect(request.headers["user-agent"] == "ai-sdk-gateway/4.0.126")
    #expect(request.headers["ai-language-model-id"] == "openai/gpt-4.1-mini")
    #expect(request.headers["ai-language-model-streaming"] == "false")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["prompt"]?[0]?["content"]?[0]?["text"]?.stringValue == "Hi")
}

@Test func gatewayAppendsVersionedUserAgentToCustomHeader() async throws {
    let transport = RecordingTransport(response: jsonResponse("""
    {"content":[{"type":"text","text":"custom gateway"}],"finishReason":"stop"}
    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(
        apiKey: "gateway-key",
        headers: ["User-Agent": "CustomApp/1.0", "X-Client": "swift"],
        transport: transport
    ))
    let model = try provider.languageModel("openai/gpt-4.1-mini")

    _ = try await model.generate(LanguageModelRequest(messages: [.user("Hi")]))

    let request = try #require(await transport.requests().first)
    #expect(request.headers["authorization"] == "Bearer gateway-key")
    #expect(request.headers["x-client"] == "swift")
    #expect(request.headers["user-agent"] == "CustomApp/1.0 ai-sdk-gateway/4.0.126")
}

@Test func gatewayUsesVercelOIDCTokenWhenGatewayAPIKeyMissing() async throws {
    try await withTemporaryEnvironment([
        "AI_GATEWAY_API_KEY": nil,
        "VERCEL_OIDC_TOKEN": "oidc-token"
    ]) {
        let transport = RecordingTransport(response: jsonResponse("""
        {"content":[{"type":"text","text":"oidc gateway"}],"finishReason":"stop"}
        """))
        let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(transport: transport))
        let model = try provider.languageModel("openai/gpt-4.1-mini")

        _ = try await model.generate(LanguageModelRequest(messages: [.user("Hi")]))

        let request = try #require(await transport.requests().first)
        #expect(request.headers["authorization"] == "Bearer oidc-token")
        #expect(request.headers["ai-gateway-auth-method"] == "oidc")
        #expect(request.headers["ai-gateway-protocol-version"] == "0.0.1")
        #expect(request.headers["user-agent"] == "ai-sdk-gateway/4.0.126")
    }
}

@Test func gatewayMapsErrorResponsesToTypedGatewayErrors() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 404,
        headers: ["content-type": "application/json"],
        body: Data("""
        {"error":{"message":"Model not found","type":"model_not_found","param":{"modelId":"missing-model"}},"generationId":"gen_123"}
        """.utf8)
    ))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.languageModel("missing-model")

    do {
        _ = try await model.generate(LanguageModelRequest(messages: [.user("Hi")]))
        Issue.record("Expected Gateway model_not_found error.")
    } catch let error as AIError {
        guard case let .gateway(gatewayError) = error else {
            Issue.record("Expected AIError.gateway, got \(error).")
            return
        }
        #expect(gatewayError.name == "GatewayModelNotFoundError")
        #expect(gatewayError.type == .modelNotFound)
        #expect(gatewayError.statusCode == 404)
        #expect(gatewayError.message == "Model not found")
        #expect(gatewayError.generationID == "gen_123")
        #expect(gatewayError.modelID == "missing-model")
        #expect(!gatewayError.isRetryable)
    }
}

@Test func gatewayMapsFailedDependencyErrorResponses() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 424,
        headers: ["content-type": "application/json"],
        body: Data("""
        {"error":{"message":"Upstream dependency failed","type":"failed_dependency"}}
        """.utf8)
    ))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.languageModel("openai/gpt-4.1-mini")

    do {
        _ = try await model.generate(LanguageModelRequest(messages: [.user("Hi")]))
        Issue.record("Expected Gateway failed_dependency error.")
    } catch let error as AIError {
        guard case let .gateway(gatewayError) = error else {
            Issue.record("Expected AIError.gateway, got \(error).")
            return
        }
        #expect(gatewayError.name == "GatewayFailedDependencyError")
        #expect(gatewayError.type == .failedDependency)
        #expect(gatewayError.statusCode == 424)
        #expect(gatewayError.message == "Upstream dependency failed")
        #expect(!gatewayError.isRetryable)
    }
}

@Test func gatewayMapsForbiddenErrorResponses() async throws {
    let transport = RecordingTransport(response: AIHTTPResponse(
        statusCode: 403,
        headers: ["content-type": "application/json"],
        body: Data("""
        {"error":{"message":"Rejected by routing policy","type":"forbidden"},"generationId":"gen_forbidden"}
        """.utf8)
    ))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.languageModel("openai/gpt-4.1-mini")

    do {
        _ = try await model.generate(LanguageModelRequest(messages: [.user("Hi")]))
        Issue.record("Expected Gateway forbidden error.")
    } catch let error as AIError {
        guard case let .gateway(gatewayError) = error else {
            Issue.record("Expected AIError.gateway, got \(error).")
            return
        }
        #expect(gatewayError.name == "GatewayForbiddenError")
        #expect(gatewayError.type == .forbidden)
        #expect(gatewayError.statusCode == 403)
        #expect(gatewayError.message == "Rejected by routing policy")
        #expect(gatewayError.generationID == "gen_forbidden")
        #expect(!gatewayError.isRetryable)
    }
}

@Test func gatewayLanguageMapsToolsToolChoiceAndContentToolCalls() async throws {
    let transport = RecordingTransport(response: jsonResponse("""
    {"content":[{"type":"text","text":"checking"},{"type":"source","sourceType":"url","id":"src_1","url":"https://example.com/a","title":"Example A","providerMetadata":{"gateway":{"rank":1}}},{"type":"tool-call","toolCallId":"call_1","toolName":"lookup","input":"{\\"query\\":\\"weather\\"}"},{"type":"tool-call","toolCallId":"gateway_search","toolName":"perplexity_search","input":{"query":"latest news"},"providerExecuted":true}],"finishReason":"stop","usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}
    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.languageModel("openai/gpt-4.1-mini")

    let result = try await model.generate(LanguageModelRequest(
        messages: [AIMessage(role: .user, content: [
            .text("Use tools."),
            .imageURL("https://example.com/image.png"),
            .data(mimeType: "application/pdf", data: Data("%PDF".utf8))
        ])],
        tools: [
            "lookup": [
                "type": "object",
                "description": "Look up a value.",
                "properties": ["query": ["type": "string"]]
            ],
            "gateway.perplexity_search": [
                "type": "provider",
                "id": "gateway.perplexity_search",
                "name": "perplexity_search",
                "args": ["maxResults": 5]
            ]
        ],
        providerOptions: [
            "gateway": [
                "order": ["openai", "anthropic"],
                "has": ["implicit-caching", "vision"],
                "sort": "ttft",
                "disallowPromptTraining": true
            ]
        ],
        extraBody: [
            "toolChoice": ["type": "tool", "toolName": "lookup"]
        ]
    ))

    #expect(result.text == "checking")
    #expect(result.finishReason == "tool-calls")
    #expect(result.usage?.totalTokens == 5)
    #expect(result.toolCalls.count == 2)
    #expect(result.toolCalls[0].id == "call_1")
    #expect(result.toolCalls[0].name == "lookup")
    #expect(result.toolCalls[0].arguments == #"{"query":"weather"}"#)
    #expect(result.toolCalls[1].providerExecuted == true)
    #expect(try decodeJSONBody(Data(result.toolCalls[1].arguments.utf8))["query"]?.stringValue == "latest news")
    #expect(result.sources.count == 1)
    #expect(result.sources[0].id == "src_1")
    #expect(result.sources[0].sourceType == "url")
    #expect(result.sources[0].url == "https://example.com/a")
    #expect(result.sources[0].title == "Example A")
    #expect(result.sources[0].providerMetadata["gateway"]?["rank"]?.intValue == 1)

    let request = try #require(await transport.requests().first)
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["prompt"]?[0]?["content"]?[1]?["data"]?["type"]?.stringValue == "url")
    #expect(body["prompt"]?[0]?["content"]?[1]?["data"]?["url"]?.stringValue == "https://example.com/image.png")
    #expect(body["prompt"]?[0]?["content"]?[2]?["data"]?["type"]?.stringValue == "data")
    #expect(body["prompt"]?[0]?["content"]?[2]?["data"]?["data"]?.stringValue == Data("%PDF".utf8).base64EncodedString())
    #expect(body["prompt"]?[0]?["content"]?[2]?["mediaType"]?.stringValue == "application/pdf")
    let tools = try #require(body["tools"]?.arrayValue)
    let functionTool = try #require(tools.first { $0["type"]?.stringValue == "function" })
    #expect(functionTool["name"]?.stringValue == "lookup")
    #expect(functionTool["description"]?.stringValue == "Look up a value.")
    #expect(functionTool["inputSchema"]?["properties"]?["query"]?["type"]?.stringValue == "string")
    let providerTool = try #require(tools.first { $0["type"]?.stringValue == "provider" })
    #expect(providerTool["id"]?.stringValue == "gateway.perplexity_search")
    #expect(providerTool["name"]?.stringValue == "perplexity_search")
    #expect(providerTool["args"]?["maxResults"]?.intValue == 5)
    #expect(body["toolChoice"]?["type"]?.stringValue == "tool")
    #expect(body["toolChoice"]?["toolName"]?.stringValue == "lookup")
    #expect(body["providerOptions"]?["gateway"]?["order"]?[0]?.stringValue == "openai")
    #expect(body["providerOptions"]?["gateway"]?["has"]?[0]?.stringValue == "implicit-caching")
    #expect(body["providerOptions"]?["gateway"]?["has"]?[1]?.stringValue == "vision")
    #expect(body["providerOptions"]?["gateway"]?["sort"]?.stringValue == "ttft")
    #expect(body["providerOptions"]?["gateway"]?["disallowPromptTraining"]?.boolValue == true)
}

@Test func gatewayToolsHelpersMirrorProviderExecutedToolFactories() async throws {
    let transport = RecordingTransport(response: jsonResponse("""
    {"content":[{"type":"text","text":"ok"}],"finishReason":"stop"}
    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.languageModel("openai/gpt-4.1-mini")

    _ = try await model.generate(LanguageModelRequest(
        messages: [.user("Search.")],
        tools: [
            "gateway.perplexity_search": GatewayTools.perplexitySearch(
                maxResults: 5,
                maxTokensPerPage: 3000,
                maxTokens: 9000,
                country: "US",
                searchDomainFilter: ["nature.com"],
                searchLanguageFilter: ["en"],
                searchRecencyFilter: "week"
            ),
            "gateway.parallel_search": GatewayTools.parallelSearch(
                mode: "agentic",
                maxResults: 3,
                includeDomains: ["example.com"],
                excludeDomains: ["spam.example"],
                afterDate: "2024-01-01",
                maxCharsPerResult: 500,
                maxCharsTotal: 2000,
                maxAgeSeconds: 60
            )
        ]
    ))

    let request = try #require(await transport.requests().first)
    let body = try decodeJSONBody(try #require(request.body))
    let tools = try #require(body["tools"]?.arrayValue)
    let perplexitySearch = try #require(tools.first { $0["id"]?.stringValue == "gateway.perplexity_search" })
    #expect(perplexitySearch["type"]?.stringValue == "provider")
    #expect(perplexitySearch["name"]?.stringValue == "perplexity_search")
    #expect(perplexitySearch["args"]?["maxResults"]?.intValue == 5)
    #expect(perplexitySearch["args"]?["maxTokensPerPage"]?.intValue == 3000)
    #expect(perplexitySearch["args"]?["maxTokens"]?.intValue == 9000)
    #expect(perplexitySearch["args"]?["country"]?.stringValue == "US")
    #expect(perplexitySearch["args"]?["searchDomainFilter"]?[0]?.stringValue == "nature.com")
    #expect(perplexitySearch["args"]?["searchLanguageFilter"]?[0]?.stringValue == "en")
    #expect(perplexitySearch["args"]?["searchRecencyFilter"]?.stringValue == "week")

    let parallelSearch = try #require(tools.first { $0["id"]?.stringValue == "gateway.parallel_search" })
    #expect(parallelSearch["type"]?.stringValue == "provider")
    #expect(parallelSearch["name"]?.stringValue == "parallel_search")
    #expect(parallelSearch["args"]?["mode"]?.stringValue == "agentic")
    #expect(parallelSearch["args"]?["maxResults"]?.intValue == 3)
    #expect(parallelSearch["args"]?["sourcePolicy"]?["includeDomains"]?[0]?.stringValue == "example.com")
    #expect(parallelSearch["args"]?["sourcePolicy"]?["excludeDomains"]?[0]?.stringValue == "spam.example")
    #expect(parallelSearch["args"]?["sourcePolicy"]?["afterDate"]?.stringValue == "2024-01-01")
    #expect(parallelSearch["args"]?["excerpts"]?["maxCharsPerResult"]?.intValue == 500)
    #expect(parallelSearch["args"]?["maxCharsTotal"]?.intValue == 2000)
    #expect(parallelSearch["args"]?["fetchPolicy"]?["maxAgeSeconds"]?.intValue == 60)
}

@Test func gatewayLanguageStreamsV4ReasoningAndToolInputChunks() async throws {
    let transport = RecordingTransport(response: sseResponse("""
    data: {"type":"text-delta","id":"txt","delta":"Hello"}

    data: {"type":"reasoning-delta","id":"r","delta":"think"}

    data: {"type":"source","sourceType":"document","id":"doc_1","title":"Report","mediaType":"application/pdf","filename":"report.pdf","providerMetadata":{"gateway":{"page":2}}}

    data: {"type":"tool-input-start","id":"call_1","toolName":"lookup"}

    data: {"type":"tool-input-delta","id":"call_1","delta":"{\\"query\\":"}

    data: {"type":"tool-input-delta","id":"call_1","delta":"\\"weather\\"}"}

    data: {"type":"tool-input-end","id":"call_1"}

    data: {"type":"finish","finishReason":"stop","usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}

    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.languageModel("openai/gpt-4.1-mini")

    var textDeltas: [String] = []
    var reasoningDeltas: [String] = []
    var legacyTextDeltas: [String] = []
    var legacyReasoningDeltas: [String] = []
    var argumentDeltas: [String] = []
    var inputLifecycle: [String] = []
    var sources: [AISource] = []
    var toolCall: AIToolCall?
    var finishReason: String?
    var totalTokens: Int?
    var terminalCount = 0
    var legacyTerminalCount = 0
    for try await part in model.stream(LanguageModelRequest(messages: [.user("Use a tool.")])) {
        switch part {
        case let .textDelta(delta):
            legacyTextDeltas.append(delta)
        case let .textDeltaPart(_, delta, _):
            textDeltas.append(delta)
        case let .reasoningDelta(delta):
            legacyReasoningDeltas.append(delta)
        case let .reasoningDeltaPart(_, delta, _):
            reasoningDeltas.append(delta)
        case let .source(source):
            sources.append(source)
        case let .toolInputStart(id, name, _, _, _, _):
            inputLifecycle.append("start:\(id):\(name)")
        case let .toolInputDelta(id, delta, _):
            inputLifecycle.append("delta:\(id):\(delta)")
        case let .toolInputEnd(id, _):
            inputLifecycle.append("end:\(id)")
        case let .toolCallDelta(_, _, argumentsDelta, _):
            argumentDeltas.append(argumentsDelta)
        case let .toolCall(call):
            toolCall = call
        case let .finishMetadata(reason, usage, _):
            terminalCount += 1
            finishReason = reason
            totalTokens = usage?.totalTokens
        case .finish:
            legacyTerminalCount += 1
        default:
            break
        }
    }

    #expect(textDeltas == ["Hello"])
    #expect(reasoningDeltas == ["think"])
    #expect(legacyTextDeltas.isEmpty)
    #expect(legacyReasoningDeltas.isEmpty)
    #expect(sources.count == 1)
    #expect(sources[0].id == "doc_1")
    #expect(sources[0].sourceType == "document")
    #expect(sources[0].title == "Report")
    #expect(sources[0].mediaType == "application/pdf")
    #expect(sources[0].filename == "report.pdf")
    #expect(sources[0].providerMetadata["gateway"]?["page"]?.intValue == 2)
    #expect(argumentDeltas == [#"{"query":"#, #""weather"}"#])
    #expect(inputLifecycle == [
        "start:call_1:lookup",
        #"delta:call_1:{"query":"#,
        #"delta:call_1:"weather"}"#,
        "end:call_1"
    ])
    #expect(toolCall?.id == "call_1")
    #expect(toolCall?.name == "lookup")
    #expect(toolCall?.arguments == #"{"query":"weather"}"#)
    #expect(finishReason == "tool-calls")
    #expect(totalTokens == 5)
    #expect(terminalCount == 1)
    #expect(legacyTerminalCount == 0)
}

@Test func gatewayFinishStepClosesPartWithoutPublishingLegacyTerminal() async throws {
    let transport = RecordingTransport(response: sseResponse("""
    data: {"type":"text-delta","id":"step-1","delta":"first"}

    data: {"type":"finish-step","finishReason":"stop","usage":{"total_tokens":2}}

    data: {"type":"text-delta","id":"step-2","delta":"second"}

    data: {"type":"finish","finishReason":"stop","usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}

    data: [DONE]

    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.languageModel("openai/gpt-4.1-mini")

    var sequence: [String] = []
    var legacyTerminals = 0
    for try await part in model.stream(LanguageModelRequest(messages: [.user("Hi")])) {
        switch part {
        case let .textStart(id, _):
            sequence.append("start:\(id)")
        case let .textDeltaPart(id, delta, _):
            sequence.append("delta:\(id):\(delta)")
        case let .textEnd(id, _), let .textEndWithCitations(id, _, _):
            sequence.append("end:\(id)")
        case let .finishMetadata(reason, usage, _):
            sequence.append("finish:\(reason ?? "nil"):\(usage?.totalTokens ?? -1)")
        case .finish:
            legacyTerminals += 1
        default:
            break
        }
    }

    #expect(legacyTerminals == 0)
    #expect(sequence == [
        "start:step-1",
        "delta:step-1:first",
        "end:step-1",
        "start:step-2",
        "delta:step-2:second",
        "end:step-2",
        "finish:stop:5"
    ])
}

@Test func gatewayEmbeddingAndRerankingUseGatewayEndpoints() async throws {
    let embeddingTransport = RecordingTransport(response: jsonResponse("""
    {"embeddings":[[0.1,0.2]],"usage":{"tokens":3}}
    """))
    let gateway = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: embeddingTransport))
    let embeddingModel = try gateway.embeddingModel("text-embedding")
    #expect(embeddingModel.maxEmbeddingsPerCall == 2_048)
    let embeddings = try await embeddingModel.embed(EmbeddingRequest(
        values: ["a"],
        providerOptions: ["gateway": ["quotaEntityId": "tenant-1"]]
    ))
    #expect(embeddings.embeddings == [[0.1, 0.2]])
    #expect(embeddings.usage?.totalTokens == 3)
    let embeddingRequest = try #require(await embeddingTransport.requests().first)
    #expect(embeddingRequest.url.absoluteString == "https://ai-gateway.vercel.sh/v4/ai/embedding-model")
    #expect(embeddingRequest.headers["ai-model-id"] == "text-embedding")
    let embeddingBody = try decodeJSONBody(try #require(embeddingRequest.body))
    #expect(embeddingBody["providerOptions"]?["gateway"]?["quotaEntityId"]?.stringValue == "tenant-1")

    let rerankTransport = RecordingTransport(response: jsonResponse("""
    {"ranking":[{"index":1,"relevanceScore":0.9}]}
    """))
    let rerankGateway = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: rerankTransport))
    let ranking = try await rerankGateway.rerankingModel("reranker").rerank(RerankingRequest(
        query: "q",
        documents: ["a", "b"],
        topK: 1,
        providerOptions: ["gateway": ["serviceTier": "flex"]]
    ))
    #expect(ranking.results == [RerankedDocument(index: 1, score: 0.9)])
    let rerankRequest = try #require(await rerankTransport.requests().first)
    #expect(rerankRequest.url.absoluteString == "https://ai-gateway.vercel.sh/v4/ai/reranking-model")
    let rerankBody = try decodeJSONBody(try #require(rerankRequest.body))
    #expect(rerankBody["topN"]?.intValue == 1)
    #expect(rerankBody["providerOptions"]?["gateway"]?["serviceTier"]?.stringValue == "flex")
}

@Test func gatewayMetadataMethodsUseManagementEndpointsAndMapResponses() async throws {
    let transport = RecordingTransport(responses: [
        jsonResponse(#"{"models":[{"id":"openai/gpt-5","name":"GPT-5","modelType":"language","specification":{"specificationVersion":"v4","provider":"openai","modelId":"gpt-5"}}]}"#),
        jsonResponse(#"{"balance":"42.00","total_used":"8.50"}"#),
        jsonResponse("""
        {"results":[{"day":"2026-03-01","model":"anthropic/claude-sonnet-4.6","provider":"anthropic","credential_type":"byok","total_cost":10.5,"market_cost":9.25,"input_tokens":100,"output_tokens":50,"cached_input_tokens":20,"cache_creation_input_tokens":5,"reasoning_tokens":7,"request_count":25}]}
        """),
        jsonResponse("""
        {"data":{"id":"gen_01","total_cost":0.12,"upstream_inference_cost":0.08,"usage":0.12,"created_at":"2026-03-01T00:00:00Z","model":"anthropic/claude-sonnet-4.6","is_byok":true,"provider_name":"anthropic","streamed":true,"finish_reason":"stop","latency":123,"generation_time":456,"native_tokens_prompt":100,"native_tokens_completion":50,"native_tokens_reasoning":7,"native_tokens_cached":20,"native_tokens_cache_creation":5,"billable_web_search_calls":2}}
        """)
    ])
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", baseURL: "https://custom-gateway.example.com/v4/ai", transport: transport), teamIDOrSlug: "team_123")

    let models = try await provider.getAvailableModels()
    #expect(models.first?.id == "openai/gpt-5")
    #expect(models.first?.provider == "openai")
    #expect(models.first?.modelID == "gpt-5")

    let credits = try await provider.getCredits()
    #expect(credits == GatewayCredits(balance: "42.00", totalUsed: "8.50"))

    let report = try await provider.getSpendReport(GatewaySpendReportParams(
        startDate: "2026-03-01",
        endDate: "2026-03-25",
        groupBy: "model",
        datePart: "day",
        userID: "user-123",
        model: "anthropic/claude-sonnet-4.6",
        provider: "anthropic",
        credentialType: "byok",
        tags: ["production", "api"]
    ))
    #expect(report.results.first?.day == "2026-03-01")
    #expect(report.results.first?.model == "anthropic/claude-sonnet-4.6")
    #expect(report.results.first?.credentialType == "byok")
    #expect(report.results.first?.totalCost == 10.5)
    #expect(report.results.first?.marketCost == 9.25)
    #expect(report.results.first?.inputTokens == 100)
    #expect(report.results.first?.requestCount == 25)

    let generation = try await provider.getGenerationInfo(id: "gen_01")
    #expect(generation.id == "gen_01")
    #expect(generation.totalCost == 0.12)
    #expect(generation.upstreamInferenceCost == 0.08)
    #expect(generation.model == "anthropic/claude-sonnet-4.6")
    #expect(generation.isByok)
    #expect(generation.providerName == "anthropic")
    #expect(generation.streamed)
    #expect(generation.finishReason == "stop")
    #expect(generation.promptTokens == 100)
    #expect(generation.billableWebSearchCalls == 2)

    let requests = await transport.requests()
    #expect(requests.count == 4)
    #expect(requests[0].url.absoluteString == "https://custom-gateway.example.com/v4/ai/config")
    #expect(requests[1].url.absoluteString == "https://custom-gateway.example.com/v1/credits?teamId=team_123")
    #expect(requests[2].url.path == "/v1/report")
    let reportItems = Dictionary(uniqueKeysWithValues: URLComponents(url: requests[2].url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
    #expect(reportItems["start_date"] == "2026-03-01")
    #expect(reportItems["end_date"] == "2026-03-25")
    #expect(reportItems["group_by"] == "model")
    #expect(reportItems["date_part"] == "day")
    #expect(reportItems["user_id"] == "user-123")
    #expect(reportItems["model"] == "anthropic/claude-sonnet-4.6")
    #expect(reportItems["provider"] == "anthropic")
    #expect(reportItems["credential_type"] == "byok")
    #expect(reportItems["tags"] == "production,api")
    #expect(requests[3].url.absoluteString == "https://custom-gateway.example.com/v1/generation?id=gen_01")
    for request in requests {
        #expect(request.headers["authorization"] == "Bearer gateway-key")
        #expect(request.headers["x-vercel-ai-gateway-team"] == "team_123")
        #expect(request.headers["ai-gateway-protocol-version"] == "0.0.1")
        #expect(request.headers["user-agent"] == "ai-sdk-gateway/4.0.126")
    }
}

@Test func gatewayImageMapsFilesMaskAndProviderOptions() async throws {
    let transport = RecordingTransport(response: jsonResponse(#"{"images":["base64-image"]}"#))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.imageModel("google/imagen-4.0-generate")

    let result = try await model.generateImage(ImageGenerationRequest(
        prompt: "Edit these images",
        size: "1024x1024",
        aspectRatio: "16:9",
        seed: 42,
        count: 2,
        files: [
            ImageInputFile(data: Data([1, 2, 3]), mediaType: "image/png"),
            ImageInputFile(url: "https://example.com/reference.png")
        ],
        mask: ImageInputFile(data: Data([4, 5, 6]), mediaType: "image/png"),
        providerOptions: [
            "gateway": [
                "order": ["vertex", "openai"],
                "serviceTier": "priority"
            ]
        ]
    ))

    #expect(result.base64Images == ["base64-image"])
    #expect(result.requestMetadata.body?["prompt"]?.stringValue == "Edit these images")
    #expect(result.requestMetadata.body?["files"]?[0]?["data"]?["type"]?.stringValue == "omitted-media")
    #expect(result.requestMetadata.body?["files"]?[0]?["data"]?["encodedByteLength"]?.intValue == Data([1, 2, 3]).base64EncodedString().utf8.count)
    #expect(result.requestMetadata.body?["files"]?[1]?["url"]?.stringValue == "https://example.com/reference.png")
    #expect(result.requestMetadata.body?["mask"]?["data"]?["type"]?.stringValue == "omitted-media")
    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://ai-gateway.vercel.sh/v4/ai/image-model")
    #expect(request.headers["ai-image-model-specification-version"] == "4")
    #expect(request.headers["ai-model-id"] == "google/imagen-4.0-generate")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["prompt"]?.stringValue == "Edit these images")
    #expect(body["n"]?.intValue == 2)
    #expect(body["size"]?.stringValue == "1024x1024")
    #expect(body["aspectRatio"]?.stringValue == "16:9")
    #expect(body["seed"]?.intValue == 42)
    #expect(body["providerOptions"]?["gateway"]?["order"]?[0]?.stringValue == "vertex")
    #expect(body["providerOptions"]?["gateway"]?["serviceTier"]?.stringValue == "priority")
    #expect(body["files"]?[0]?["type"]?.stringValue == "file")
    #expect(body["files"]?[0]?["mediaType"]?.stringValue == "image/png")
    #expect(body["files"]?[0]?["data"]?.stringValue == Data([1, 2, 3]).base64EncodedString())
    #expect(body["files"]?[1]?["type"]?.stringValue == "url")
    #expect(body["files"]?[1]?["url"]?.stringValue == "https://example.com/reference.png")
    #expect(body["mask"]?["type"]?.stringValue == "file")
    #expect(body["mask"]?["mediaType"]?.stringValue == "image/png")
    #expect(body["mask"]?["data"]?.stringValue == Data([4, 5, 6]).base64EncodedString())
}

@Test func gatewayVideoMapsFrameImagesLikeUpstream() async throws {
    let transport = RecordingTransport(response: sseResponse("""
    data: {"videos":[{"url":"https://gateway.example.com/video.mp4"}]}

    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.videoModel("fal/luma-ray-2")

    _ = try await model.generateVideo(VideoGenerationRequest(
        prompt: "A sunset",
        frameImages: [
            VideoFrameImage(image: ImageInputFile(data: Data("Hello".utf8), mediaType: "image/png"), frameType: .firstFrame),
            VideoFrameImage(image: ImageInputFile(url: "https://example.com/last-frame.png"), frameType: .lastFrame)
        ],
        generateAudio: true,
        providerOptions: ["gateway": ["disallowPromptTraining": true]]
    ))

    let body = try decodeJSONBody(try #require((await transport.requests()).first?.body))
    #expect(body["frameImages"]?[0]?["frameType"]?.stringValue == "first_frame")
    #expect(body["frameImages"]?[0]?["image"]?["type"]?.stringValue == "file")
    #expect(body["frameImages"]?[0]?["image"]?["mediaType"]?.stringValue == "image/png")
    #expect(body["frameImages"]?[0]?["image"]?["data"]?.stringValue == Data("Hello".utf8).base64EncodedString())
    #expect(body["frameImages"]?[1]?["frameType"]?.stringValue == "last_frame")
    #expect(body["frameImages"]?[1]?["image"]?["type"]?.stringValue == "url")
    #expect(body["frameImages"]?[1]?["image"]?["url"]?.stringValue == "https://example.com/last-frame.png")
    #expect(body["generateAudio"]?.boolValue == true)
    #expect(body["providerOptions"]?["gateway"]?["disallowPromptTraining"]?.boolValue == true)
    #expect(body["inputReferences"] == nil)
}

@Test func gatewayVideoMapsInputReferencesLikeUpstream() async throws {
    let transport = RecordingTransport(response: sseResponse("""
    data: {"videos":[{"url":"https://gateway.example.com/video.mp4"}]}

    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.videoModel("fal/luma-ray-2")

    _ = try await model.generateVideo(VideoGenerationRequest(
        prompt: "A sunset",
        inputReferences: [
            ImageInputFile(data: Data("Hello".utf8), mediaType: "image/png"),
            ImageInputFile(url: "https://example.com/reference.png")
        ]
    ))

    let body = try decodeJSONBody(try #require((await transport.requests()).first?.body))
    #expect(body["inputReferences"]?[0]?["type"]?.stringValue == "file")
    #expect(body["inputReferences"]?[0]?["mediaType"]?.stringValue == "image/png")
    #expect(body["inputReferences"]?[0]?["data"]?.stringValue == Data("Hello".utf8).base64EncodedString())
    #expect(body["inputReferences"]?[1]?["type"]?.stringValue == "url")
    #expect(body["inputReferences"]?[1]?["url"]?.stringValue == "https://example.com/reference.png")
    #expect(body["frameImages"] == nil)
}

@Test func gatewayVideoThrowsOnErrorEvent() async throws {
    let transport = RecordingTransport(response: sseResponse("""
    data: {"type":"error","message":"Rate limit exceeded","errorType":"rate_limit_exceeded","statusCode":429,"param":null}

    """))
    let provider = try AIProviders.gateway(configuration: GatewayProviderSettings(apiKey: "gateway-key", transport: transport))
    let model = try provider.videoModel("fal/luma-ray-2")

    do {
        _ = try await model.generateVideo(VideoGenerationRequest(
            prompt: "A sunset",
            aspectRatio: "16:9",
            durationSeconds: 5,
            extraBody: [
                "n": 1,
                "resolution": "1920x1080",
                "fps": 24,
                "seed": 42,
                "providerOptions": ["fal": ["motionStrength": 0.8]]
            ]
        ))
        Issue.record("Expected Gateway video error event to throw.")
    } catch let error as AIError {
        guard case let .gateway(gatewayError) = error else {
            Issue.record("Expected AIError.gateway, got \(error).")
            return
        }
        #expect(gatewayError.name == "GatewayRateLimitError")
        #expect(gatewayError.type == .rateLimitExceeded)
        #expect(gatewayError.statusCode == 429)
        #expect(gatewayError.message == "Rate limit exceeded")
        #expect(gatewayError.isRetryable)
        #expect(gatewayError.headers["content-type"] == "text/event-stream")
    }

    let request = try #require(await transport.requests().first)
    #expect(request.url.absoluteString == "https://ai-gateway.vercel.sh/v4/ai/video-model")
    #expect(request.headers["ai-video-model-specification-version"] == "4")
    #expect(request.headers["ai-model-id"] == "fal/luma-ray-2")
    #expect(request.headers["accept"] == "text/event-stream")
    let body = try decodeJSONBody(try #require(request.body))
    #expect(body["prompt"]?.stringValue == "A sunset")
    #expect(body["aspectRatio"]?.stringValue == "16:9")
    #expect(body["duration"]?.intValue == 5)
    #expect(body["n"]?.intValue == 1)
    #expect(body["resolution"]?.stringValue == "1920x1080")
    #expect(body["fps"]?.intValue == 24)
    #expect(body["seed"]?.intValue == 42)
    #expect(body["providerOptions"]?["fal"]?["motionStrength"]?.doubleValue == 0.8)
}

private func withTemporaryEnvironment<T>(_ updates: [String: String?], operation: () async throws -> T) async rethrows -> T {
    var previous: [String: String?] = [:]
    for key in updates.keys {
        previous[key] = getenv(key).map { String(cString: $0) }
    }
    for (key, value) in updates {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
    defer {
        for (key, value) in previous {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }
    return try await operation()
}
