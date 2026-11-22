import Foundation
import SwiftAI
import SwiftAIProvider
import SwiftAIProviderUtilities
import SwiftAITransport
import Testing
@testable import SwiftAIGateway

// Translated from @ai-sdk/gateway 4.0.152's gateway-extraction-model.test.ts.
@Suite struct GatewayExtractionUpstreamTests {
    @Test func createsV4ModelsFromBothFactories() throws {
        let provider = try GatewayProvider(configuration: .init(apiKey: "test-token", baseURL: "https://api.test.com"))
        let model = try #require(provider.extractionModel(extractionID) as? GatewayExtractionModel)
        let alias = provider.extraction(extractionID)
        for factoryModel in [model, alias] {
            #expect(factoryModel.specificationVersion == "v4")
            #expect(factoryModel.providerID == "gateway")
            #expect(factoryModel.modelID == "scaledown/extract-1")
            #expect(factoryModel.supportedFieldTypes == [.text, .number, .date, .time, .datetime, .duration, .list])
        }
        #expect(provider.supportedCapabilities.contains(.extraction))
    }

    @Test(arguments: [
        ([AIDecisionStatePart.text("Inspect.")], JSONValue.array([["type": "text", "text": "Inspect."]])),
        ([AIDecisionStatePart.json(["product": "vase", "history": ["new"]])], JSONValue.array([
            ["type": "json", "value": ["product": "vase", "history": ["new"]]]
        ])),
        ([AIDecisionStatePart.text("Inspect."), .json(["product": "vase"]), .text("Again.")], JSONValue.array([
            ["type": "text", "text": "Inspect."], ["type": "json", "value": ["product": "vase"]],
            ["type": "text", "text": "Again."]
        ]))
    ])
    func sendsOrderedTextAndJSONState(fixture: ([AIDecisionStatePart], JSONValue)) async throws {
        let transport = try extractionTransport()
        _ = try await extractionModel(transport).doExtract(.init(state: fixture.0, fields: extractionFields))
        let body = try extractionRequestBody(try #require(await transport.requests().first))
        #expect(body == ["stateParts": fixture.1, "fields": extractionFieldsJSON])
    }

    @Test func sendsFileBytesAsBase64AlongsideText() async throws {
        let transport = try extractionTransport()
        _ = try await extractionModel(transport).doExtract(.init(state: [
            .text("Read this invoice."),
            .file(mediaType: "application/pdf", data: .data(Data([1, 2, 3])), filename: "invoice.pdf")
        ], fields: extractionFields))
        let body = try extractionRequestBody(try #require(await transport.requests().first))
        #expect(body["stateParts"] == [
            ["type": "text", "text": "Read this invoice."],
            ["type": "file", "mediaType": "application/pdf", "filename": "invoice.pdf", "data": ["type": "data", "data": "AQID"]]
        ])
    }

    @Test(arguments: [
        ("image/jpeg", AIDecisionFileData.base64("AQID"), JSONValue.object(["type": "data", "data": "AQID"])),
        ("application/pdf", AIDecisionFileData.reference("file_123"), JSONValue.object(["type": "reference", "reference": ["gateway": "file_123"]]))
    ])
    func sendsBase64AndProviderFileReferences(fixture: (String, AIDecisionFileData, JSONValue)) async throws {
        let transport = try extractionTransport()
        _ = try await extractionModel(transport).doExtract(.init(
            state: [.file(mediaType: fixture.0, data: fixture.1)], fields: extractionFields
        ))
        let body = try extractionRequestBody(try #require(await transport.requests().first))
        #expect(body["stateParts"] == [["type": "file", "mediaType": .string(fixture.0), "data": fixture.2]])
    }

    @Test func rejectsURLFileDataBeforeIO() async throws {
        let transport = try extractionTransport()
        let url = try #require(URL(string: "https://example.com/a.pdf"))
        let file: AIDecisionStatePart = .file(mediaType: "application/pdf", data: .url(url))
        await #expect(throws: AIDecisionUnsupportedFunctionalityError(functionality: "Gateway extraction file input: url data")) {
            try await extractionModel(transport).doExtract(.init(state: [file], fields: extractionFields))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func postsToExtractionEndpointAndOmitsUnsetOptions() async throws {
        let transport = try extractionTransport()
        _ = try await extractionModel(transport).doExtract(extractionOptions)
        let request = try #require(await transport.requests().first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.test.com/extraction-model")
        #expect(try extractionRequestBody(request) == ["stateParts": extractionStateJSON, "fields": extractionFieldsJSON])
    }

    @Test func sendsEveryCallOptionThroughTheRequestBody() async throws {
        let transport = try extractionTransport()
        let providerOptions: [String: JSONValue] = [
            "gateway": ["models": ["openai/gpt-5.4-nano"], "user": "user-123"],
            "scaledown": ["threshold": 0.4]
        ]
        let options = AIExtractionModelV4CallOptions(
            state: extractionState, fields: extractionFields, referenceDate: "2026-11-11",
            maxOutputTokens: 512, reasoning: "low", providerOptions: providerOptions
        )
        _ = try await extractionModel(transport).doExtract(options)
        let body = try extractionRequestBody(try #require(await transport.requests().first))
        #expect(body == [
            "stateParts": extractionStateJSON, "fields": extractionFieldsJSON,
            "referenceDate": "2026-11-11", "maxOutputTokens": 512, "reasoning": "low",
            "providerOptions": .object(providerOptions)
        ])
    }

    @Test func forwardsCustomModelAndObservabilityHeaders() async throws {
        let transport = try extractionTransport()
        var options = extractionOptions
        options.headers = ["Custom-Header": "test-value", "AI-Model-ID": "overridden", "AI-O11Y-Region": "sfo1"]
        _ = try await extractionModel(transport, observabilityHeaders: ["ai-o11y-region": "iad1"]).doExtract(options)
        let headers = normalizeHeaders(try #require(await transport.requests().first).headers)
        #expect(headers["authorization"] == "Bearer test-token")
        #expect(headers["custom-header"] == "test-value")
        #expect(headers["ai-extraction-model-specification-version"] == "4")
        #expect(headers["ai-model-id"] == "scaledown/extract-1")
        #expect(headers["ai-o11y-region"] == "iad1")
    }

    @Test func parsesEveryAnswerTypeAndSource() async throws {
        let answers: JSONValue = [
            "text": ["type": "text", "value": "INV-2041", "guess": "INV-2041", "pNull": 0.01, "confidence": 0.98,
                     "source": ["type": "text", "part": 0, "start": 8, "end": 16]],
            "number": ["type": "number", "value": 1250],
            "date": ["type": "date", "value": "2026-03-03"],
            "time": ["type": "time", "value": "17:30"],
            "datetime": ["type": "datetime", "value": "2026-03-03T17:30:00Z"],
            "duration": ["type": "duration", "value": 120],
            "missing": ["type": "text", "value": .null, "guess": "PO-1", "pNull": 0.9],
            "fromFile": ["type": "text", "value": "Acme", "source": ["type": "file", "part": 1]],
            "texts": ["type": "list", "value": ["Ana", "Bo"], "confidence": 0.9,
                      "items": [["confidence": 0.95, "source": ["type": "text", "part": 0, "start": 1, "end": 4]], [:]]],
            "numbers": ["type": "list", "value": [1, 2.5]],
            "emptyList": ["type": "list", "value": []],
            "missingList": ["type": "list", "value": .null, "pNull": 0.8]
        ]
        let result = try await extractionModel(extractionTransport(["answers": answers])).doExtract(extractionOptions)
        #expect(result.answers == [
            "text": .init(type: .text, value: "INV-2041", guess: "INV-2041", pNull: 0.01, confidence: 0.98, source: .text(part: 0, start: 8, end: 16)),
            "number": .init(type: .number, value: 1250),
            "date": .init(type: .date, value: "2026-03-03"),
            "time": .init(type: .time, value: "17:30"),
            "datetime": .init(type: .datetime, value: "2026-03-03T17:30:00Z"),
            "duration": .init(type: .duration, value: 120),
            "missing": .init(type: .text, guess: "PO-1", pNull: 0.9),
            "fromFile": .init(type: .text, value: "Acme", source: .file(part: 1)),
            "texts": .init(type: .list, value: ["Ana", "Bo"], confidence: 0.9, items: [.init(confidence: 0.95, source: .text(part: 0, start: 1, end: 4)), .init()]),
            "numbers": .init(type: .list, value: [1, 2.5]),
            "emptyList": .init(type: .list, value: []),
            "missingList": .init(type: .list, pNull: 0.8)
        ])
    }

    @Test func parsesRefusalsAlongsideAnswers() async throws {
        let answers: JSONValue = ["invoiceNumber": ["type": "refusal"], "total": ["type": "number", "value": 1250], "contacts": ["type": "refusal"]]
        let result = try await extractionModel(extractionTransport(["answers": answers])).doExtract(extractionOptions)
        #expect(result.answers == ["invoiceNumber": .init(type: .refusal), "total": .init(type: .number, value: 1250), "contacts": .init(type: .refusal)])
    }

    @Test func parsesUsageWarningsAndProviderMetadata() async throws {
        let metadata: [String: JSONValue] = ["gateway": ["cost": "0.002"]]
        let result = try await extractionModel(extractionTransport([
            "usage": ["inputTokens": 120, "outputTokens": 30],
            "warnings": [["type": "unsupported", "feature": "reasoning", "details": "Ignored."], ["type": "other", "message": "Something else."]],
            "providerMetadata": .object(metadata)
        ])).doExtract(extractionOptions)
        #expect(result.usage == .init(inputTokens: 120, outputTokens: 30))
        #expect(result.warnings == [.init(type: "unsupported", feature: "reasoning", message: "Ignored."), .init(type: "other", message: "Something else.")])
        #expect(result.providerMetadata == metadata)
    }

    @Test func leavesUsageAbsentAndDefaultsWarningsAndResponseModel() async throws {
        let result = try await extractionModel(extractionTransport()).doExtract(extractionOptions)
        #expect(result.usage == nil)
        #expect(result.warnings == [])
        #expect(result.response?.modelID == "scaledown/extract-1")
    }

    @Test func dropsOptionalNullFieldsAndKeepsMissingValues() async throws {
        let result = try await extractionModel(extractionTransport([
            "answers": [
                "invoiceNumber": ["type": "text", "value": .null, "guess": .null, "pNull": 0.9, "confidence": .null, "source": .null],
                "total": ["type": "number", "value": 1250, "guess": .null, "source": .null],
                "contacts": ["type": "list", "value": ["Ana"], "pNull": .null, "items": [["confidence": .null, "source": .null]]]
            ],
            "model": .null, "usage": ["inputTokens": 120, "outputTokens": .null], "warnings": .null, "providerMetadata": .null
        ])).doExtract(extractionOptions)
        #expect(result.answers == [
            "invoiceNumber": .init(type: .text, pNull: 0.9),
            "total": .init(type: .number, value: 1250),
            "contacts": .init(type: .list, value: ["Ana"], items: [.init()])
        ])
        #expect(result.usage == .init(inputTokens: 120, outputTokens: nil))
        #expect(result.warnings == [])
        #expect(result.providerMetadata == [:])
        #expect(result.response?.modelID == "scaledown/extract-1")
    }

    @Test func keepsUnknownWarningAsOtherWithItsContent() async throws {
        let result = try await extractionModel(extractionTransport([
            "warnings": [["type": "other", "message": "Known."], ["type": "future", "detail": "New."]]
        ])).doExtract(extractionOptions)
        #expect(result.warnings == [.init(type: "other", message: "Known."), .init(type: "other", message: #"Unknown warning: {"type":"future","detail":"New."}"#)])
    }

    @Test func retainsResponseHeadersBodyAndFallbackModel() async throws {
        let transport = try extractionTransport(["model": "scaledown/extract-1-fallback"], headers: ["x-request-id": "req-1"])
        let result = try await extractionModel(transport).doExtract(extractionOptions)
        #expect(result.response?.modelID == "scaledown/extract-1-fallback")
        #expect(result.response?.headers["x-request-id"] == "req-1")
        #expect(result.response?.body == ["answers": extractionDummyAnswers, "model": "scaledown/extract-1-fallback"])
    }

    @Test func remapsUnsupportedFieldWithNativeModelIdentity() async throws {
        let message = #"Field "total" has type "number", which is not supported by provider "upstream.extraction" and model "extract-1"."#
        let transport = try extractionErrorTransport(400, [
            "message": .string(message), "type": "invalid_request_error",
            "param": ["name": "AI_ExtractionUnsupportedFieldTypeError", "fieldId": "total", "fieldType": "number", "statusCode": 400]
        ])
        let expected = AIExtractionUnsupportedFieldTypeError(fieldID: "total", fieldType: .number, providerID: "gateway", modelID: extractionID)
        await #expect(throws: expected) { try await extractionModel(transport).doExtract(extractionOptions) }
        #expect(expected.message == #"Field "total" has type "number", which is not supported by provider "gateway" and model "scaledown/extract-1"."#)
    }

    @Test func retainsUnsupportedListItemDiscriminator() async throws {
        let transport = try extractionErrorTransport(400, [
            "message": "Unsupported field type.", "type": "invalid_request_error",
            "param": ["name": "AI_ExtractionUnsupportedFieldTypeError", "fieldId": "contacts", "fieldType": "list<number>"]
        ])
        let error = await #expect(throws: AIExtractionUnsupportedFieldTypeError.self) {
            try await extractionModel(transport).doExtract(extractionOptions)
        }
        #expect(error?.fieldID == "contacts")
        #expect(error?.fieldType == .list)
        #expect(error?.fieldTypeLabel == "list<number>")
        #expect(error?.message.contains(#""list<number>""#) == true)
    }

    @Test(arguments: [
        nil as JSONValue?,
        ["name": "AI_InvalidArgumentError", "fieldId": "a", "fieldType": "b"],
        ["name": "AI_ExtractionUnsupportedFieldTypeError"]
    ])
    func leavesOther400ResponsesAsGatewayInvalidRequest(parameter: JSONValue?) async throws {
        let transport = try extractionErrorTransport(400, .object([
            "message": "Invalid fields format", "type": "invalid_request_error", "param": parameter
        ]))
        let error = await #expect(throws: GatewayError.self) {
            try await extractionModel(transport).doExtract(extractionOptions)
        }
        #expect(error?.type == .invalidRequestError)
        #expect(error?.statusCode == 400)
        #expect(error?.message == "Invalid fields format")
    }

    @Test func leaves500ResponsesAsGatewayInternalServerError() async throws {
        let transport = try extractionErrorTransport(500, ["type": "internal_server_error", "message": "Internal server error"])
        let error = await #expect(throws: GatewayError.self) { try await extractionModel(transport).doExtract(extractionOptions) }
        #expect(error?.type == .internalServerError)
        #expect(error?.statusCode == 500)
    }

    @Test(arguments: [
        JSONValue.object(["type": "text"]), ["type": "number", "value": "1250"],
        ["type": "list", "value": ["Ana", 1]], ["type": "text", "value": "A", "source": ["type": "file", "part": 1.5]]
    ])
    func rejectsMalformedWireAnswersAndRetainsResponse(answer: JSONValue) async throws {
        let body: JSONValue = ["answers": ["total": answer]]
        let transport = try extractionTransport(["answers": ["total": answer]])
        let error = await #expect(throws: GatewayError.self) { try await extractionModel(transport).doExtract(extractionOptions) }
        #expect(error?.type == .responseError)
        #expect(error?.response == body)
        #expect(error?.statusCode == 200)
        #expect(error?.isRetryable == true)
    }

    @Test func forwardsAbortSignalAndSkipsAlreadyAbortedCalls() async throws {
        let transport = try extractionTransport()
        let controller = AIAbortController()
        var options = extractionOptions
        options.abortSignal = controller.signal
        _ = try await extractionModel(transport).doExtract(options)
        #expect(await transport.requests().first?.abortSignal === controller.signal)
        controller.abort()
        await #expect(throws: AIAbortError.self) { try await extractionModel(transport).doExtract(options) }
        #expect(await transport.requests().count == 1)
    }

    @Test func experimentalExtractRetriesTransientGatewayErrors() async throws {
        let failed = AIHTTPResponse(statusCode: 500, body: Data(#"{"error":{"type":"internal_server_error","message":"Internal server error"}}"#.utf8))
        let successful = jsonResponse(try decisionJSONText(["answers": extractionDummyAnswers]))
        let transport = RecordingTransport(responses: [failed, successful])
        let result = try await AI.experimentalExtract(
            model: extractionModel(transport), state: .text(extractionText), fields: extractionFields, maxRetries: 1
        )
        #expect(result.answers["invoiceNumber"]?.value == "INV-2041")
        #expect(await transport.requests().count == 2)
    }
}

private let extractionID = "scaledown/extract-1"
private let extractionText = "Invoice INV-2041 from Acme. Total due $1,250.00."
private let extractionState: [AIDecisionStatePart] = [.text(extractionText)]
private let extractionStateJSON: JSONValue = [["type": "text", "text": .string(extractionText)]]
private let extractionFields: [String: AIExtractionField] = [
    "invoiceNumber": .init(type: .text, instructions: "The invoice number"),
    "total": .init(type: .number, instructions: "Total amount due", decimals: 2),
    "contacts": .init(type: .list, items: .text)
]
private let extractionFieldsJSON: JSONValue = [
    "invoiceNumber": ["type": "text", "instructions": "The invoice number"],
    "total": ["type": "number", "instructions": "Total amount due", "decimals": 2],
    "contacts": ["type": "list", "items": "text"]
]
private let extractionDummyAnswers: JSONValue = [
    "invoiceNumber": ["type": "text", "value": "INV-2041", "confidence": 0.98, "pNull": 0.01,
                      "source": ["type": "text", "part": 0, "start": 8, "end": 16]],
    "total": ["type": "number", "value": 1250, "guess": 1250],
    "contacts": ["type": "list", "value": .null]
]
private var extractionOptions: AIExtractionModelV4CallOptions { .init(state: extractionState, fields: extractionFields) }

private func extractionModel(_ transport: RecordingTransport, observabilityHeaders: [String: String] = [:]) -> GatewayExtractionModel {
    let baseURL = "https://api.test.com"
    let client = AIProviderHTTPClient(providerID: "gateway", headers: ["Authorization": "Bearer test-token", "ai-gateway-auth-method": "api-key"],
        transport: transport, dynamicHeaders: { observabilityHeaders }, url: { _, path in try providerURL(baseURL + path, queryParams: [:]) })
    return .init(modelID: extractionID, config: .init(http: client, baseURL: baseURL))
}

private func extractionTransport(_ overrides: [String: JSONValue] = [:], headers: [String: String] = [:]) throws -> RecordingTransport {
    let payload = ["answers": extractionDummyAnswers].merging(overrides) { _, override in override }
    return RecordingTransport(response: jsonResponse(try decisionJSONText(.object(payload)), headers: headers))
}

private func extractionErrorTransport(_ status: Int, _ error: JSONValue) throws -> RecordingTransport {
    RecordingTransport(response: .init(statusCode: status, body: try encodeJSONBody(["error": error])))
}

private func extractionRequestBody(_ request: AIHTTPRequest) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
}
