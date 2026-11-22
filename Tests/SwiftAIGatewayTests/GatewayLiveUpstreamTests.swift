import Foundation
import SwiftAIProvider
import SwiftAITransport
import Testing
@testable import SwiftAIGateway

// Translated from @ai-sdk/gateway 4.0.152's gateway-realtime-model-live.test.ts
// and the Live factory coverage in gateway-provider.test-d.ts.
@Suite struct GatewayLiveUpstreamTests {
    @Test func declaresContinuousWebSocketCapabilities() throws {
        let model: any AIRealtimeModelV4 = try liveProvider().liveModel(liveID)
        #expect(model.specificationVersion == "v4")
        #expect(model.providerID == "gateway.live")
        #expect(model.modelID == "openai/gpt-live-1.1")
        #expect(model.capabilities == .init(conversation: .continuous, transports: [.webSocket],
                                            connections: [.clientSecretWebSocket, .serverWebSocket],
                                            startup: .sessionStart, finalization: .sessionClose))
    }

    @Test func mintsALiveBoundSecretAndReturnsLiveURL() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"token":"vcst_live","expiresAt":1700000060}"#))
        let model = try liveProvider(transport: transport).liveModel(liveID)
        let result = try await model.doCreateClientSecret(.init(expiresAfterSeconds: 120))
        #expect(result == .init(token: "vcst_live", url: liveURL, expiresAt: 1_700_000_060))
        let request = try #require(await transport.requests().first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://ai-gateway.vercel.sh/v1/realtime/client-secrets")
        #expect(try liveMintBody(request) == ["model": "openai/gpt-live-1.1", "routeKind": "live", "expiresIn": 120])
    }

    @Test func upgradesHTTPBaseURLToWS() async throws {
        let model = try liveProvider(baseURL: "http://localhost:3000/v4/ai").liveModel(liveID)
        let result = try await model.createClientSecret()
        #expect(result.url == "ws://localhost:3000/v4/ai/live-model?ai-model-id=openai%2Fgpt-live-1.1")
    }

    @Test func carriesTokenAndTeamScopeInSubprotocols() throws {
        let model = try liveProvider(teamIDOrSlug: "my-team").liveModel(liveID)
        let config = model.getWebSocketConfig(token: "vcst_x", url: liveURL)
        #expect(config.url == liveURL)
        #expect(Array(config.protocols.prefix(2)) == [GatewayRealtimeAuth.realtimeSubprotocol, "\(GatewayRealtimeAuth.authSubprotocolPrefix)vcst_x"])
        #expect(GatewayRealtimeAuth.teamIDOrSlug(fromSecWebSocketProtocol: config.protocols.joined(separator: ", ")) == "my-team")
        #expect(config.headers.isEmpty)
    }

    @Test func returnsLiveURLAndDefinedHeadersForServerConnections() async throws {
        let descriptor = try await liveProvider().liveModel(liveID).getResolvedServerWebSocketConfig()
        #expect(descriptor.url == liveURL)
        #expect(normalizeHeaders(descriptor.headers)["authorization"] == "Bearer vck_test-token")
        #expect(normalizeHeaders(descriptor.headers)["x-unset"] == nil)
    }

    @Test func reportsAuthenticationFailureForAnEmptyRotatingCredential() async throws {
        let provider = try GatewayProvider(configuration: .init(apiKeyProvider: { "" }))
        let model = provider.liveModel(liveID)
        let error = await #expect(throws: AIError.self) { try await model.getResolvedServerWebSocketConfig() }
        guard case let .gateway(gatewayError) = error else { Issue.record("Expected a Gateway authentication error"); return }
        #expect(gatewayError.type == .authenticationError)
        #expect(gatewayError.statusCode == 401)
        #expect(gatewayError.message.contains("No authentication provided"))
    }

    @Test func rejectsNonConversationIntentsInAllEntryPoints() async throws {
        let model: any AIRealtimeModelV4 = try liveProvider().liveModel(liveID)
        let error = AIError.invalidArgument(argument: "intent", message: "AI Gateway Live does not support the 'transcription' session intent.")
        await #expect(throws: error) { try await model.getResolvedServerWebSocketConfig(intent: .transcription) }
        #expect(throws: error) { try model.getServerWebSocketConfig(intent: .transcription) }
        await #expect(throws: error) { try await model.serializeClientEvent(.sessionClose(), intent: .transcription) }
        #expect(throws: error) { try model.buildSessionConfig(.init(), intent: .transcription) }
    }

    @Test func addsModelIDToSessionStart() async throws {
        let model = try liveProvider().liveModel(liveID)
        let options: [String: JSONValue] = ["gateway": ["tags": ["demo"]], "openai": ["delegation": ["type": "client"]]]
        let format = AIRealtimeAudioFormat(type: "audio/pcm", rate: 24_000)
        let config = AIRealtimeSessionConfiguration(instructions: "Be brief.", voice: "marin", inputAudioFormat: format, outputAudioFormat: format, providerOptions: options)
        let wire = try await model.serializeClientEvent(.sessionStart(config, eventID: "start-1"))
        #expect(wire == .json([
            "type": "session-start", "modelId": "openai/gpt-live-1.1", "eventId": "start-1", "config": [
                "instructions": "Be brief.", "voice": "marin", "inputAudioFormat": ["type": "audio/pcm", "rate": 24000],
                "outputAudioFormat": ["type": "audio/pcm", "rate": 24000], "providerOptions": .object(options)
            ]
        ]))
    }

    @Test(arguments: liveClientEvents)
    func mapsNormalizedLiveEvents(fixture: (AIRealtimeClientEvent, JSONValue)) async throws {
        let wire = try await liveProvider().liveModel(liveID).serializeClientEvent(fixture.0)
        #expect(wire == .json(fixture.1))
    }

    @Test(arguments: liveUnsupportedContextOptions)
    func rejectsInvalidContextProviderOptions(options: [String: JSONValue]) async throws {
        let model = try liveProvider().liveModel(liveID)
        await #expect(throws: GatewayLiveUnsupportedFunctionalityError.self) {
            try await model.serializeClientEvent(.contextAppend(content: "Note", delegationID: nil, providerOptions: options))
        }
    }

    @Test(arguments: ["commentary", "instructions", "thinking"])
    func acceptsContextChannels(channel: String) async throws {
        let model = try liveProvider().liveModel(liveID)
        let options: [String: JSONValue] = ["openai": ["channel": .string(channel)]]
        let wire = try await model.serializeClientEvent(.contextAppend(content: "Note", delegationID: nil, providerOptions: options))
        #expect(wire == .json(["type": "context-append", "content": "Note", "delegationId": .null, "providerOptions": .object(options)]))
    }

    @Test(arguments: liveUnsupportedClientEvents)
    func rejectsUnsupportedClientEvents(fixture: (AIRealtimeClientEvent, String)) async throws {
        let model = try liveProvider().liveModel(liveID)
        await #expect(throws: GatewayLiveUnsupportedFunctionalityError(functionality: "AI Gateway Live client event: \(fixture.1)")) {
            try await model.serializeClientEvent(fixture.0)
        }
    }

    @Test(arguments: liveUnsupportedSessionSettings)
    func rejectsUnsupportedSessionSettings(fixture: (AIRealtimeSessionConfiguration, String)) throws {
        let model = try liveProvider().liveModel(liveID)
        #expect(throws: GatewayLiveUnsupportedFunctionalityError(functionality: "AI Gateway Live session setting: \(fixture.1)")) {
            try model.buildValidatedSessionConfig(fixture.0)
        }
    }

    @Test(arguments: liveUnsupportedSessionProviderOptions)
    func rejectsUnsupportedProviderOptions(options: [String: JSONValue]) throws {
        let model = try liveProvider().liveModel(liveID)
        #expect(throws: GatewayLiveUnsupportedFunctionalityError.self) {
            try model.buildValidatedSessionConfig(.init(providerOptions: options))
        }
    }

    @Test(arguments: liveMalformedNamespaces)
    func rejectsMalformedProviderOptionNamespaces(options: [String: JSONValue]) throws {
        let model = try liveProvider().liveModel(liveID)
        #expect(throws: AIError.self) { try model.buildValidatedSessionConfig(.init(providerOptions: options)) }
    }

    @Test(arguments: liveMalformedOpenAIOptions)
    func rejectsMalformedOpenAIOptions(fixture: (String, JSONValue)) throws {
        let model = try liveProvider().liveModel(liveID)
        let error = #expect(throws: AIError.self) {
            try model.buildValidatedSessionConfig(.init(providerOptions: ["openai": .object([fixture.0: fixture.1])]))
        }
        guard case let .invalidArgument(argument, _) = error else { Issue.record("Expected an invalid argument"); return }
        #expect(argument == "providerOptions.openai.\(fixture.0)")
    }

    @Test func accepts128MessagesAndEverySupportedRoleAndPartType() throws {
        let model = try liveProvider().liveModel(liveID)
        let input = [liveInput("developer", "input_text"), liveInput("user", "input_text"),
                     liveInput("assistant", "text"), liveInput("assistant", "output_text")]
            + Array(repeating: liveInput("user", "input_text"), count: 124)
        let providerOptions: [String: JSONValue] = ["openai": ["input": .array(input)]]
        #expect(try model.buildValidatedSessionConfig(.init(providerOptions: providerOptions)) == ["providerOptions": .object(providerOptions)])
    }

    @Test func acceptsProviderOptionsAndLeavesGatewayOptionsOpen() throws {
        let model = try liveProvider().liveModel(liveID)
        let providerOptions: [String: JSONValue] = [
            "gateway": ["tags": ["demo"], "futureOption": ["nested": true]],
            "openai": ["delegation": .null, "input": [liveInput("user", "input_text")], "store": false, "voice": ["id": "voice_1"]]
        ]
        #expect(try model.buildValidatedSessionConfig(.init(providerOptions: providerOptions)) == ["providerOptions": .object(providerOptions)])
        #expect(try model.buildValidatedSessionConfig(.init(instructions: "Hi")) == ["instructions": "Hi"])
    }

    @Test(arguments: liveUnsupportedAudioFormats)
    func rejectsUnsupportedAudioFormats(format: AIRealtimeAudioFormat) throws {
        let model = try liveProvider().liveModel(liveID)
        #expect(throws: GatewayLiveUnsupportedFunctionalityError.self) {
            try model.buildValidatedSessionConfig(.init(inputAudioFormat: format))
        }
    }

    @Test(arguments: liveSupportedAudioFormats)
    func acceptsSupportedAudioFormats(format: AIRealtimeAudioFormat) throws {
        let model = try liveProvider().liveModel(liveID)
        let encoded: JSONValue = ["type": .string(format.type), "rate": .number(Double(try #require(format.rate)))]
        #expect(try model.buildValidatedSessionConfig(.init(inputAudioFormat: format, outputAudioFormat: format)) == [
            "inputAudioFormat": encoded, "outputAudioFormat": encoded
        ])
    }

    @Test func requiresMatchingInputAndOutputFormats() throws {
        let model = try liveProvider().liveModel(liveID)
        let input = AIRealtimeAudioFormat(type: "audio/pcm", rate: 16_000)
        let output = AIRealtimeAudioFormat(type: "audio/pcm", rate: 24_000)
        #expect(throws: AIError.invalidArgument(argument: "outputAudioFormat", message: "AI Gateway Live requires the same input and output audio format.")) {
            try model.buildValidatedSessionConfig(.init(inputAudioFormat: input, outputAudioFormat: output))
        }
    }

    @Test func decodesNormalizedEventsAndPreservesGatewayErrorFramesAsRaw() throws {
        let model = try liveProvider().liveModel(liveID)
        let providerRaw: JSONValue = ["type": "session.closed"]
        let event: JSONValue = ["type": "session-closed", "sessionId": "live_1", "usage": ["seconds": 14], "reason": "close_requested", "raw": providerRaw]
        #expect(model.parseServerEvent(event) == [.sessionClosed(sessionID: "live_1", usage: .init(seconds: 14), reason: "close_requested", raw: providerRaw)])
        let frame: JSONValue = ["type": "error", "code": "invalid_request_error", "message": "Live requires a canonical model slug"]
        #expect(model.parseServerEvent(frame) == [.error(message: "Live requires a canonical model slug", code: "invalid_request_error", raw: frame)])
    }

    @Test(arguments: [JSONValue.null, "text", [], [:], ["type": 1]])
    func reportsInvalidFrames(raw: JSONValue) throws {
        let model = try liveProvider().liveModel(liveID)
        #expect(model.parseServerEvent(raw) == [.error(message: "Invalid AI Gateway Live server event.", code: "invalid_server_event", raw: raw)])
    }

    @Test(arguments: ["openai/gpt-live-1", "openai/gpt-live-1.1"])
    func routesKnownLiveModels(modelID: String) throws {
        let model = try liveProvider().experimentalRealtime(modelID)
        #expect(model is GatewayRealtimeModelLive)
        #expect(model.providerID == "gateway.live")
    }

    @Test(arguments: ["openai/gpt-realtime-2", "google/gemini-3.8-live", "spacexai/grok-voice-3.0"])
    func keepsOtherModelsOnRealtimeRoute(modelID: String) throws {
        let model = try liveProvider().experimentalRealtime(modelID)
        #expect(model is GatewayRealtimeModel)
        #expect(model.providerID == "gateway.realtime")
    }

    @Test func honorsExplicitRouteAndRetainsConcreteRealtimeFactory() throws {
        let provider = try liveProvider()
        let live = provider.experimentalRealtime("openai/gpt-live-2", api: .live)
        let realtime = provider.experimentalRealtime("openai/gpt-live-1.1", api: .realtime)
        #expect(live is GatewayRealtimeModelLive)
        #expect(live.capabilities?.startup == .sessionStart)
        #expect(realtime is GatewayRealtimeModel)
        #expect(realtime.capabilities?.conversation == .turnBased)
        let retained: GatewayRealtimeModel = provider.realtimeModel(liveID)
        #expect(retained.providerID == "gateway.realtime")
        #expect(GatewayRealtimeAPI(rawValue: "other") == nil)
    }

    @Test func factoryMintsKnownLiveTokenAtGatewayOrigin() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"token":"vcst_live","expiresAt":1700000060}"#))
        let factory = try liveProvider(transport: transport).experimentalRealtime
        let result = try await factory.getToken(.init(model: "openai/gpt-live-1.1", expiresAfterSeconds: 60))
        #expect(result == .init(token: "vcst_live", url: liveURL, expiresAt: 1_700_000_060))
        let request = try #require(await transport.requests().first)
        #expect(request.url.absoluteString == "https://ai-gateway.vercel.sh/v1/realtime/client-secrets")
        #expect(try liveMintBody(request) == ["model": "openai/gpt-live-1.1", "routeKind": "live", "expiresIn": 60])
    }

    @Test func factoryMintsWithExplicitAPIRouteAndOmitsRouteKindForRealtime() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"token":"vcst_x"}"#))
        let factory = try liveProvider(transport: transport).experimentalRealtime
        let live = try await factory.getToken(.init(model: "openai/gpt-live-2", api: .live))
        let realtime = try await factory.getToken(.init(model: "openai/gpt-live-1.1", api: .realtime))
        #expect(live.url.contains("/v4/ai/live-model?"))
        #expect(realtime.url.contains("/v4/ai/realtime-model?"))
        let bodies = try await transport.requests().map(liveMintBody)
        #expect(bodies == [["model": "openai/gpt-live-2", "routeKind": "live"], ["model": "openai/gpt-live-1.1"]])
    }
}

private let liveID = "openai/gpt-live-1.1"
private let liveURL = "wss://ai-gateway.vercel.sh/v4/ai/live-model?ai-model-id=openai%2Fgpt-live-1.1"

private func liveProvider(
    baseURL: String? = nil,
    teamIDOrSlug: String? = nil,
    transport: RecordingTransport = RecordingTransport(response: jsonResponse(#"{"token":"vcst_test-secret"}"#))
) throws -> GatewayProvider {
    try GatewayProvider(configuration: .init(apiKey: "vck_test-token", baseURL: baseURL, transport: transport), teamIDOrSlug: teamIDOrSlug)
}

private func liveMintBody(_ request: AIHTTPRequest) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
}

private func liveInput(_ role: String, _ part: String) -> JSONValue {
    ["type": "message", "role": .string(role), "content": [["type": .string(part), "text": "Hi"]]]
}

private let liveClientEvents: [(AIRealtimeClientEvent, JSONValue)] = [
    (.sessionClose(), ["type": "session-close"]),
    (.sessionClose(eventID: "close-1"), ["type": "session-close", "eventId": "close-1"]),
    (.inputAudioMute(), ["type": "input-audio-mute"]),
    (.inputAudioUnmute(), ["type": "input-audio-unmute"]),
    (.inputAudioAppend(audio: "AAAA"), ["type": "input-audio-append", "audio": "AAAA"]),
    (.contextAppend(content: "Note", delegationID: nil), ["type": "context-append", "content": "Note", "delegationId": .null]),
    (.contextAppend(content: "Checking", delegationID: "d1", eventID: "ctx-1", providerOptions: ["openai": ["channel": "thinking"]]),
     ["type": "context-append", "content": "Checking", "delegationId": "d1", "eventId": "ctx-1", "providerOptions": ["openai": ["channel": "thinking"]]])
]

private let liveUnsupportedContextOptions: [[String: JSONValue]] = [
    ["openai": ["channel": "shouting"]], ["openai": ["channel": .null]], ["openai": ["priority": "high"]], ["google": ["channel": "thinking"]]
]

private let liveUnsupportedClientEvents: [(AIRealtimeClientEvent, String)] = [
    (.sessionUpdate(.init()), "session-update"), (.inputAudioCommit, "input-audio-commit"), (.inputAudioClear, "input-audio-clear"),
    (.responseCreate(), "response-create"), (.responseCancel, "response-cancel")
]

private let liveUnsupportedSessionSettings: [(AIRealtimeSessionConfiguration, String)] = [
    (.init(tools: []), "tools"), (.init(turnDetection: .init(type: .serverVAD)), "turnDetection"),
    (.init(outputModalities: []), "outputModalities")
]

private let liveUnsupportedSessionProviderOptions: [[String: JSONValue]] = [
    ["openai": ["client": ["dataChannel": [:]]]],
    ["openai": ["delegation": ["type": "responses"]]], ["openai": ["delegation": "client"]], ["google": [:]],
    ["openai": ["delegation": ["type": "client", "extra": true]]]
]

private let liveMalformedNamespaces: [[String: JSONValue]] = [
    ["openai": .null], ["gateway": "tags"]
]

private let liveMalformedOpenAIOptions: [(String, JSONValue)] = [
    ("voice", .null), ("store", .null), ("voice", "marin"), ("voice", ["id": ""]), ("voice", ["id": "v", "name": "extra"]),
    ("store", "false"), ("input", [:]), ("input", [liveInput("user", "text")]), ("input", [liveInput("assistant", "input_text")]),
    ("input", [liveInput("system", "input_text")]),
    ("input", [["type": "message", "role": "user", "content": [["type": "input_text", "text": "Hi"]], "extra": true]]),
    ("input", [["type": "message", "role": "user", "content": []]]),
    ("input", .array(Array(repeating: liveInput("user", "input_text"), count: 129))),
    ("input", [.null])
]

private let liveUnsupportedAudioFormats: [AIRealtimeAudioFormat] = [
    .init(type: "audio/pcm", rate: 48_000), .init(type: "audio/pcm"),
    .init(type: "audio/pcmu", rate: 16_000), .init(type: "audio/opus", rate: 24_000)
]

private let liveSupportedAudioFormats: [AIRealtimeAudioFormat] = [
    .init(type: "audio/pcm", rate: 16_000), .init(type: "audio/pcm", rate: 24_000),
    .init(type: "audio/pcma", rate: 8_000), .init(type: "audio/pcmu", rate: 8_000)
]
