import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
import SwiftAI


public typealias GatewaySpeechFactoryGetTokenOptions = GatewayTranscriptionFactoryGetTokenOptions
public typealias GatewaySpeechFactoryGetTokenResult = GatewayTranscriptionFactoryGetTokenResult

/// Mints speech-bound client secrets on a trusted server and constructs native
/// duplex speech models. A returned token can be supplied as the client's key.
public struct GatewaySpeechFactory: Sendable {
    private let config: GatewayModelConfiguration
    private let webSocketTransport: any AIDuplexWebSocketTransport
    init(config: GatewayModelConfiguration, webSocketTransport: any AIDuplexWebSocketTransport) { self.config = config; self.webSocketTransport = webSocketTransport }
    public func callAsFunction(_ modelID: String) -> GatewaySpeechModel { GatewaySpeechModel(modelID: modelID, config: config, webSocketTransport: webSocketTransport) }
    public func getToken(_ options: GatewaySpeechFactoryGetTokenOptions) async throws -> GatewaySpeechFactoryGetTokenResult {
        let body: JSONValue = .object(["model": .string(options.model), "routeKind": "speech", "expiresIn": options.expiresAfterSeconds.map { .number(Double($0)) }])
        let response: AIHTTPResponse
        do {
            response = try await config.transport.send(AIHTTPRequest(method: "POST", url: try gatewaySpeechOriginURL(config.baseURL),
                                                                      headers: config.headers.mergingHeaders(["content-type": "application/json"]), body: try encodeJSONBody(body)))
        } catch { throw speechGatewayConnectionError(error) }
        guard (200..<300).contains(response.statusCode) else {
            throw gatewayErrorFromHTTPStatus(statusCode: response.statusCode, body: response.bodyText, headers: response.headers)
        }
        let raw = try response.jsonValue()
        guard let token = raw["token"]?.stringValue, !token.isEmpty else { throw AIError.invalidResponse(provider: "gateway", message: "Gateway speech client-secret response did not contain a non-empty token.") }
        return .init(token: token, url: try gatewaySpeechWebSocketURL(baseURL: config.baseURL, modelID: options.model).absoluteString, expiresAt: raw["expiresAt"]?.intValue)
    }
}

private func gatewaySpeechOriginURL(_ base: String) throws -> URL {
    guard var value = URLComponents(string: base) else { throw AIError.invalidURL(base) }
    value.path = "/v1/realtime/client-secrets"; value.query = nil; value.fragment = nil
    guard let url = value.url else { throw AIError.invalidURL(base) }; return url
}

extension GatewaySpeechModel {
    public func stream(_ request: StreamingSpeechRequest) async throws -> StreamingSpeechModelResult {
        do {
            try request.abortSignal?.throwIfAborted()
            let headers = config.headers.mergingHeaders(request.headers).mergingHeaders(["ai-speech-model-specification-version": "4", "ai-model-id": modelID])
            let connection = try await webSocketTransport.connect(.init(url: try gatewaySpeechWebSocketURL(baseURL: config.baseURL, modelID: modelID),
                                                                        headers: headers, protocols: gatewaySpeechProtocols(headers), abortSignal: request.abortSignal))
            let start = SpeechStreamEnvelope.startFrame(request)
            let session = SpeechSocketSession(connection: connection, input: request.text, abortSignal: request.abortSignal,
                                              startFrame: start, decode: { text in
                guard let part = SpeechStreamEnvelope.parsePart(text) else { return [] }
                if case let .error(error) = part {
                    let raw = (error as? AIStreamingSpeechError)?.rawValue ?? .string(String(describing: error))
                    return [.error(speechGatewayServerError(raw))]
                }
                return [part]
            }, inputPump: { session in
                for try await part in request.text {
                    var pieces = splitSpeechTextDelta(part.text)
                    if pieces.isEmpty && (part.voice != nil || !part.providerOptions.isEmpty) { pieces = [""] }
                    for (index, piece) in pieces.enumerated() {
                        try await session.send(.object(["type": .string(SpeechStreamEnvelope.textDeltaFrameType), "delta": .string(piece),
                                                        "voice": part.voice.map(JSONValue.string),
                                                        "providerOptions": index == 0 && !part.providerOptions.isEmpty ? .object(part.providerOptions) : nil]))
                    }
                }
                try await session.send(.object(["type": .string(SpeechStreamEnvelope.textDoneFrameType)]))
            }, connectionError: speechGatewayConnectionError)
            return .init(stream: session.makeStream(), requestMetadata: .init(body: start, headers: request.headers),
                         responseMetadata: .init(timestamp: Date(), modelID: modelID), cancel: { session.cancel() })
        } catch { request.text.cancelFromConsumer(); throw speechGatewayConnectionError(error) }
    }
}


func gatewaySpeechWebSocketURL(baseURL: String, modelID: String) throws -> URL {
    guard var components = URLComponents(string: baseURL) else { throw AIError.invalidURL(baseURL) }
    switch components.scheme?.lowercased() {
    case "https": components.scheme = "wss"
    case "http": components.scheme = "ws"
    case "wss", "ws": break
    default: throw AIError.invalidURL(baseURL)
    }
    components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = "/" + components.path + (components.path.isEmpty ? "" : "/") + "speech-model"
    var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "/?&=+")
    components.percentEncodedQuery = "ai-model-id=" + (modelID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    components.fragment = nil
    guard let url = components.url else { throw AIError.invalidURL(baseURL) }; return url
}

func gatewaySpeechProtocols(_ headers: [String: String]) -> [String] {
    let headers = normalizeHeaders(headers)
    var result = ["ai-gateway-speech.v1"]
    guard let authorization = headers["authorization"], authorization.hasPrefix("Bearer ") else { return result }
    result.append("ai-gateway-auth." + authorization.dropFirst(7))
    if let team = headers["x-vercel-ai-gateway-team"], !team.isEmpty {
        result.append("ai-gateway-team." + Data(team.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
    }
    return result
}

func splitSpeechTextDelta(_ delta: String) -> [String] {
    var output: [String] = []; var piece = ""; var count = 0
    for scalar in delta.unicodeScalars {
        let size = scalar.utf16.count
        if count + size > 8 * 1024 { output.append(piece); piece = ""; count = 0 }
        piece.unicodeScalars.append(scalar); count += size
    }
    if !piece.isEmpty { output.append(piece) }; return output
}

func speechGatewayServerError(_ raw: JSONValue) -> any Error {
    let codes: [String: Int] = ["authentication_error": 401, "failed_dependency": 424, "forbidden": 403,
                               "internal_server_error": 500, "invalid_request_error": 400, "model_not_found": 404, "rate_limit_exceeded": 429]
    if let type = raw["type"]?.stringValue, let code = codes[type], let message = raw["message"]?.stringValue,
       let kind = GatewayErrorType(rawValue: type) { return GatewayError(type: kind, message: message, statusCode: code, response: .object(["error": raw])) }
    return AIStreamingSpeechError(provider: "gateway", message: "AI Gateway speech stream failed: " + (raw["message"]?.stringValue ?? raw.stringValue ?? String(describing: raw)), rawValue: raw)
}

func speechGatewayConnectionError(_ error: any Error) -> any Error {
    if error is GatewayError || error is AIAbortError || error is CancellationError || error is AIStreamingSpeechError { return error }
    return GatewayError(type: .internalServerError, message: "Connection error on AI Gateway speech stream: \(error)", statusCode: 500)
}
