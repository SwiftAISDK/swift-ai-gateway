import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


/// Compatibility Evaluation adapter routed through Gateway's Decision Model V4 endpoint.
public final class GatewayEvaluationModel: AIEvaluationModelV4, @unchecked Sendable {
    public let specificationVersion = "v4"
    public let supportedQuestionTypes: [AIEvaluationQuestionType] = [.choice, .score, .boolean]
    private let decision: GatewayDecisionModel
    public var providerID: String { decision.providerID }
    public var modelID: String { decision.modelID }
    init(modelID: String, config: GatewayModelConfiguration) { decision = GatewayDecisionModel(modelID: modelID, config: config) }

    public func doEvaluate(_ options: AIEvaluationModelV4CallOptions) async throws -> AIEvaluationModelV4Result {
        let result = try await decision.doDecide(options.decisionOptions)
        return try evaluationResult(from: result, providerID: providerID, modelID: modelID)
    }
}