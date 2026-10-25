import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


/// Gateway's native Decision Model V4 endpoint.
public final class GatewayDecisionModel: AIDecisionModelV4, @unchecked Sendable {
    public let specificationVersion = "v4"
    public let supportedQuestionTypes: [AIDecisionQuestionType] = [.choice, .score, .boolean]
    public let providerID: String
    public let modelID: String

    private let config: GatewayModelConfiguration

    init(modelID: String, config: GatewayModelConfiguration) {
        self.providerID = config.providerID
        self.modelID = modelID
        self.config = config
    }

    public func doDecide(
        _ options: AIDecisionModelV4CallOptions
    ) async throws -> AIDecisionModelV4Result {
        try validateGatewayDecisionProviderOptions(options.providerOptions)

        var body: [String: JSONValue] = [
            "stateParts": .array(try options.state.map(gatewayDecisionStatePart)),
            "questions": .object(options.questions.mapValues(gatewayDecisionQuestion))
        ]
        if let maxOutputTokens = options.maxOutputTokens {
            body["maxOutputTokens"] = .number(Double(maxOutputTokens))
        }
        if let reasoning = options.reasoning {
            body["reasoning"] = .string(reasoning)
        }
        if !options.providerOptions.isEmpty {
            body["providerOptions"] = .object(options.providerOptions)
        }

        let request = try config.request(
            path: "/decision-model",
            modelID: modelID,
            body: .object(body),
            headers: options.headers.mergingHeaders([
                "ai-decision-model-specification-version": "4",
                "ai-model-id": modelID
            ]),
            abortSignal: options.abortSignal
        )

        let response: AIHTTPResponse
        do {
            response = try await config.transport.send(request)
        } catch let error as AIAbortError {
            throw error
        } catch let error as CancellationError {
            throw error
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

        let raw: JSONValue
        do {
            raw = try response.jsonValue()
        } catch {
            throw gatewayDecisionResponseError(
                message: "Gateway decision response was not valid JSON.",
                response: response
            )
        }

        guard let rawAnswers = raw["answers"]?.objectValue else {
            throw gatewayDecisionResponseError(
                message: "Gateway decision response is missing answers.",
                response: response,
                raw: raw
            )
        }

        let responseModelID: String
        if let returnedModel = raw["model"] {
            guard let returnedModel = returnedModel.stringValue else {
                throw gatewayDecisionResponseError(
                    message: "Gateway decision response model is invalid.",
                    response: response,
                    raw: raw
                )
            }
            responseModelID = returnedModel
        } else {
            responseModelID = modelID
        }

        var answers: [String: AIDecisionAnswer] = [:]
        answers.reserveCapacity(rawAnswers.count)
        for (questionID, value) in rawAnswers {
            answers[questionID] = try gatewayDecisionAnswer(
                value,
                questionID: questionID,
                response: response,
                raw: raw
            )
        }

        return AIDecisionModelV4Result(
            answers: answers,
            rounding: try gatewayDecisionRounding(raw["rounding"], response: response, raw: raw),
            usage: try gatewayDecisionUsage(raw["usage"], response: response, raw: raw),
            warnings: try gatewayDecisionWarnings(raw["warnings"], response: response, raw: raw),
            providerMetadata: try gatewayDecisionProviderMetadata(
                raw["providerMetadata"] ?? raw["provider_metadata"],
                response: response,
                raw: raw
            ),
            response: AIResponseMetadata(
                modelID: responseModelID,
                headers: response.headers,
                body: raw
            )
        )
    }
}

private let gatewayDecisionFallbackMaxConditionDepth = 5
private let gatewayDecisionFallbackMaxConditionsPerList = 20
private let gatewayDecisionFallbackMaxQuestionLength = 256

private func validateGatewayDecisionProviderOptions(
    _ providerOptions: [String: JSONValue]
) throws {
    guard let value = providerOptions["gateway"] else { return }
    guard let gatewayOptions = value.objectValue else {
        throw gatewayDecisionProviderOptionsError("Gateway decision provider options must be an object.")
    }
    guard let modelsValue = gatewayOptions["models"] else { return }
    guard let models = modelsValue.arrayValue else {
        throw gatewayDecisionProviderOptionsError("Gateway decision models must be an array.")
    }

    var conditionalCount = 0
    for (index, entry) in models.enumerated() {
        if entry.stringValue != nil { continue }
        guard let fallback = entry.objectValue,
              Set(fallback.keys) == Set(["model", "when"]),
              let model = fallback["model"]?.stringValue,
              !model.isEmpty,
              let condition = fallback["when"] else {
            throw gatewayDecisionProviderOptionsError("Gateway conditional model fallbacks are invalid.")
        }
        conditionalCount += 1
        guard conditionalCount == 1 else {
            throw gatewayDecisionProviderOptionsError("Gateway models support at most one conditional decision fallback.")
        }
        guard index == 0 else {
            throw gatewayDecisionProviderOptionsError("A conditional Gateway decision fallback must be the first models entry.")
        }
        try validateGatewayDecisionFallbackCondition(condition, depth: 1)
    }
}

private func validateGatewayDecisionFallbackCondition(
    _ value: JSONValue,
    depth: Int
) throws {
    guard let condition = value.objectValue else {
        throw gatewayDecisionProviderOptionsError("Gateway decision fallback conditions must be objects.")
    }

    if Set(condition.keys) == Set(["question", "confidenceBelow"]) || Set(condition.keys) == Set(["confidenceBelow"]) {
        if let question = condition["question"] { try validateGatewayDecisionQuestionID(question) }
        try validateGatewayDecisionProbability(
            condition["confidenceBelow"],
            message: "Gateway confidenceBelow must be a finite number from 0 through 1."
        )
        return
    }

    if Set(condition.keys) == Set(["question", "probabilityBetween"]) || Set(condition.keys) == Set(["probabilityBetween"]) {
        if let question = condition["question"] { try validateGatewayDecisionQuestionID(question) }
        guard let bounds = condition["probabilityBetween"]?.arrayValue,
              bounds.count == 2 else {
            throw gatewayDecisionProviderOptionsError("Gateway probabilityBetween must contain exactly two probabilities.")
        }
        try validateGatewayDecisionProbability(
            bounds[0],
            message: "Gateway probabilityBetween values must be finite numbers from 0 through 1."
        )
        try validateGatewayDecisionProbability(
            bounds[1],
            message: "Gateway probabilityBetween values must be finite numbers from 0 through 1."
        )
        guard let minimum = bounds[0].doubleValue,
              let maximum = bounds[1].doubleValue,
              minimum <= maximum else {
            throw gatewayDecisionProviderOptionsError("Gateway probabilityBetween minimum must not exceed its maximum.")
        }
        return
    }

    guard depth < gatewayDecisionFallbackMaxConditionDepth else {
        throw gatewayDecisionProviderOptionsError(
            "Gateway decision fallback conditions can be nested at most \(gatewayDecisionFallbackMaxConditionDepth) levels deep."
        )
    }

    if Set(condition.keys) == Set(["any"]) {
        try validateGatewayDecisionConditionList(condition["any"], depth: depth + 1)
        return
    }
    if Set(condition.keys) == Set(["all"]) {
        try validateGatewayDecisionConditionList(condition["all"], depth: depth + 1)
        return
    }
    if Set(condition.keys) == Set(["atLeast"]),
       let atLeast = condition["atLeast"]?.objectValue,
       Set(atLeast.keys) == Set(["count", "conditions"]),
       let countValue = atLeast["count"]?.doubleValue,
       countValue.isFinite,
       countValue.rounded(.towardZero) == countValue,
       let count = Int(exactly: countValue),
       let conditions = atLeast["conditions"]?.arrayValue,
       count >= 1,
       count <= conditions.count {
        try validateGatewayDecisionConditionList(.array(conditions), depth: depth + 1)
        return
    }

    throw gatewayDecisionProviderOptionsError("Gateway decision fallback condition is invalid.")
}

private func validateGatewayDecisionConditionList(
    _ value: JSONValue?,
    depth: Int
) throws {
    guard let conditions = value?.arrayValue,
          !conditions.isEmpty,
          conditions.count <= gatewayDecisionFallbackMaxConditionsPerList else {
        throw gatewayDecisionProviderOptionsError(
            "Gateway decision condition lists must contain 1 through \(gatewayDecisionFallbackMaxConditionsPerList) conditions."
        )
    }
    for condition in conditions {
        try validateGatewayDecisionFallbackCondition(condition, depth: depth)
    }
}

private func validateGatewayDecisionQuestionID(_ value: JSONValue?) throws {
    guard let question = value?.stringValue,
          !question.isEmpty,
          question.utf16.count <= gatewayDecisionFallbackMaxQuestionLength else {
        throw gatewayDecisionProviderOptionsError(
            "Gateway decision fallback question IDs must contain 1 through \(gatewayDecisionFallbackMaxQuestionLength) characters."
        )
    }
}

private func validateGatewayDecisionProbability(
    _ value: JSONValue?,
    message: String
) throws {
    guard let probability = value?.doubleValue,
          probability.isFinite,
          (0...1).contains(probability) else {
        throw gatewayDecisionProviderOptionsError(message)
    }
}

private func gatewayDecisionProviderOptionsError(_ message: String) -> AIError {
    .invalidArgument(argument: "providerOptions.gateway.models", message: message)
}

private func gatewayDecisionQuestion(_ question: AIDecisionQuestion) -> JSONValue {
    switch question {
    case let .choice(instructions, criteria):
        return .object([
            "type": .string("choice"),
            "instructions": instructions,
            "criteria": .object(criteria)
        ])
    case let .score(instructions, criteria):
        return .object([
            "type": .string("score"),
            "instructions": instructions,
            "criteria": .array(criteria)
        ])
    case let .box(instructions):
        return .object(["type": "box", "instructions": instructions])
    case let .boolean(instructions, criteria):
        return .object([
            "type": .string("boolean"),
            "instructions": instructions,
            "criteria": criteria.map(JSONValue.object)
        ])
    }
}

private func gatewayDecisionAnswer(
    _ value: JSONValue,
    questionID: String,
    response: AIHTTPResponse,
    raw: JSONValue
) throws -> AIDecisionAnswer {
    guard let object = value.objectValue, let type = object["type"]?.stringValue else {
        throw gatewayDecisionResponseError(
            message: "Gateway decision answer \"\(questionID)\" is invalid.",
            response: response,
            raw: raw
        )
    }
    switch type {
    case "choice":
        guard let choice = object["choice"]?.stringValue else {
            throw gatewayDecisionResponseError(
                message: "Gateway decision choice answer \"\(questionID)\" is missing choice.",
                response: response,
                raw: raw
            )
        }
        return .choice(
            choice: choice,
            probabilities: try gatewayDecisionProbabilities(
                object["probabilities"],
                questionID: questionID,
                response: response,
                raw: raw
            )
        )
    case "score":
        guard let score = object["score"]?.doubleValue, score.isFinite else {
            throw gatewayDecisionResponseError(
                message: "Gateway decision score answer \"\(questionID)\" is missing a finite score.",
                response: response,
                raw: raw
            )
        }
        return .score(
            score: score,
            probabilities: try gatewayDecisionProbabilities(
                object["probabilities"],
                questionID: questionID,
                response: response,
                raw: raw
            )
        )
    case "refusal":
        return .refusal
    case "boolean":
        guard let probability = object["probability"]?.doubleValue,
              probability.isFinite else {
            throw gatewayDecisionResponseError(
                message: "Gateway decision boolean answer \"\(questionID)\" is missing a finite probability.",
                response: response,
                raw: raw
            )
        }
        return .boolean(probability: probability)
    default:
        throw gatewayDecisionResponseError(
            message: "Gateway decision answer \"\(questionID)\" has unknown type \"\(type)\".",
            response: response,
            raw: raw
        )
    }
}

private func gatewayDecisionProbabilities(
    _ value: JSONValue?,
    questionID: String,
    response: AIHTTPResponse,
    raw: JSONValue
) throws -> [String: Double]? {
    guard let value else { return nil }
    guard let object = value.objectValue else {
        throw gatewayDecisionResponseError(
            message: "Gateway decision answer \"\(questionID)\" has invalid probabilities.",
            response: response,
            raw: raw
        )
    }
    var result: [String: Double] = [:]
    for (key, item) in object {
        guard let number = item.doubleValue, number.isFinite else {
            throw gatewayDecisionResponseError(
                message: "Gateway decision answer \"\(questionID)\" has invalid probabilities.",
                response: response,
                raw: raw
            )
        }
        result[key] = number
    }
    return result
}

private func gatewayDecisionRounding(
    _ value: JSONValue?,
    response: AIHTTPResponse,
    raw: JSONValue
) throws -> AIDecisionRounding? {
    guard let value else { return nil }
    guard let object = value.objectValue else {
        throw gatewayDecisionResponseError(message: "Gateway decision rounding is invalid.", response: response, raw: raw)
    }
    return AIDecisionRounding(
        probabilityDecimals: try gatewayDecisionInteger(
            object["probabilityDecimals"],
            field: "rounding.probabilityDecimals",
            response: response,
            raw: raw
        ),
        scoreDecimals: try gatewayDecisionInteger(
            object["scoreDecimals"],
            field: "rounding.scoreDecimals",
            response: response,
            raw: raw
        )
    )
}

private func gatewayDecisionUsage(
    _ value: JSONValue?,
    response: AIHTTPResponse,
    raw: JSONValue
) throws -> AIDecisionModelUsage? {
    guard let value else { return nil }
    guard let object = value.objectValue else {
        throw gatewayDecisionResponseError(message: "Gateway decision usage is invalid.", response: response, raw: raw)
    }
    return AIDecisionModelUsage(
        inputTokens: try gatewayDecisionInteger(
            object["inputTokens"],
            field: "usage.inputTokens",
            response: response,
            raw: raw
        ),
        outputTokens: try gatewayDecisionInteger(
            object["outputTokens"],
            field: "usage.outputTokens",
            response: response,
            raw: raw
        )
    )
}

private func gatewayDecisionInteger(
    _ value: JSONValue?,
    field: String,
    response: AIHTTPResponse,
    raw: JSONValue
) throws -> Int? {
    guard let value else { return nil }
    guard let number = value.doubleValue,
          number.isFinite,
          number.rounded(.towardZero) == number,
          let integer = Int(exactly: number) else {
        throw gatewayDecisionResponseError(
            message: "Gateway decision \(field) must be an integer.",
            response: response,
            raw: raw
        )
    }
    return integer
}

private func gatewayDecisionWarnings(
    _ value: JSONValue?,
    response: AIHTTPResponse,
    raw: JSONValue
) throws -> [AIWarning] {
    guard let value else { return [] }
    guard let values = value.arrayValue else {
        throw gatewayDecisionResponseError(message: "Gateway decision warnings are invalid.", response: response, raw: raw)
    }
    return try values.map { warning in
        guard let object = warning.objectValue,
              let type = object["type"]?.stringValue else {
            throw gatewayDecisionResponseError(message: "Gateway decision warning is invalid.", response: response, raw: raw)
        }
        switch type {
        case "unsupported", "compatibility":
            guard let feature = object["feature"]?.stringValue else {
                throw gatewayDecisionResponseError(message: "Gateway decision warning is missing feature.", response: response, raw: raw)
            }
            return AIWarning(
                type: type,
                feature: feature,
                message: object["details"]?.stringValue
            )
        case "deprecated":
            guard let setting = object["setting"]?.stringValue,
                  let message = object["message"]?.stringValue else {
                throw gatewayDecisionResponseError(message: "Gateway decision deprecation warning is invalid.", response: response, raw: raw)
            }
            return AIWarning(type: type, setting: setting, message: message)
        case "other":
            guard let message = object["message"]?.stringValue else {
                throw gatewayDecisionResponseError(message: "Gateway decision warning is missing message.", response: response, raw: raw)
            }
            return AIWarning(type: type, message: message)
        default:
            throw gatewayDecisionResponseError(message: "Gateway decision warning has unknown type \"\(type)\".", response: response, raw: raw)
        }
    }
}

private func gatewayDecisionProviderMetadata(
    _ value: JSONValue?,
    response: AIHTTPResponse,
    raw: JSONValue
) throws -> [String: JSONValue] {
    guard let value else { return [:] }
    guard let metadata = value.objectValue,
          metadata.values.allSatisfy({ $0.objectValue != nil }) else {
        throw gatewayDecisionResponseError(message: "Gateway decision provider metadata is invalid.", response: response, raw: raw)
    }
    return metadata
}

private func gatewayDecisionResponseError(
    message: String,
    response: AIHTTPResponse,
    raw: JSONValue? = nil
) -> GatewayError {
    GatewayError(
        type: .responseError,
        message: message,
        statusCode: response.statusCode,
        response: raw,
        headers: response.headers,
        cause: AIAPICallError(
            provider: "gateway",
            statusCode: response.statusCode,
            responseHeaders: response.headers,
            responseBody: response.bodyText
        )
    )
}

private func gatewayDecisionStatePart(_ part: AIDecisionStatePart) throws -> JSONValue {
    if case let .file(_, data, _, _) = part {
        switch data {
        case .data, .base64: break
        case .url, .reference:
            throw AIDecisionUnsupportedFunctionalityError(functionality: "Gateway decision file input requires data")
        }
    }
    return decisionStatePartJSON(part)
}

public extension GatewayDecisionModel {
    /// Compatibility alias for the published Evaluation-to-Decision rename.
    func doEvaluate(_ options: AIDecisionModelV4CallOptions) async throws -> AIDecisionModelV4Result {
        try await doDecide(options)
    }
}
