@testable import SwiftAIGateway
@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing

@Suite struct WeeklyGatewaySpeech20261025 {
    @Test func speechEnvelopeSplitsTextWithoutBreakingUnicodeOrRepeatingEvents() async throws {
        let socket = WeeklySpeechSocketTransport()
        let provider = try AIProviders.gateway(configuration: .init(apiKey: "test-token", baseURL: "https://api.test.com/v4/ai"), teamIDOrSlug: "my-team", webSocketTransport: socket)
        let model = try provider.streamingSpeechModel("elevenlabs/eleven-flash-v2.5")
        let long = String(repeating: "a", count: 8191) + "😀b"
        let input = AIStreamingTextInput.parts([.init(text: long, voice: "b", providerOptions: ["elevenlabs": ["newTurn": true]]), .init(text: "", voice: "c")])
        let result = try await model.stream(.init(text: input, voice: "a", outputFormat: .init(mediaType: "audio/pcm", sampleRate: 24000), speed: 1.1))
        socket.socket.open()
        #expect(await weeklySpeechWait { socket.socket.sent.count == 5 })
        let sent = socket.socket.sent
        #expect(sent[0]["type"] == "speech-stream.start")
        #expect(sent[0]["outputFormat"]?["rate"] == 24000)
        #expect(sent[1]["delta"]?.stringValue == String(repeating: "a", count: 8191))
        #expect(sent[2]["delta"] == "😀b")
        #expect(sent[1]["voice"] == "b"); #expect(sent[2]["voice"] == "b")
        #expect(sent[1]["providerOptions"]?["elevenlabs"]?["newTurn"] == true)
        #expect(sent[2]["providerOptions"] == nil)
        #expect(sent[3]["delta"] == ""); #expect(sent[3]["voice"] == "c")
        #expect(sent[4]["type"] == "speech-stream.text-done")
        let request = try #require(socket.requests.first)
        #expect(request.url.absoluteString == "wss://api.test.com/v4/ai/speech-model?ai-model-id=elevenlabs%2Feleven-flash-v2.5")
        #expect(request.protocols == ["ai-gateway-speech.v1", "ai-gateway-auth.test-token", "ai-gateway-team.bXktdGVhbQ"])
        #expect(normalizeHeaders(request.headers)["ai-speech-model-specification-version"] == "4")
        try socket.socket.receive(["type": "stream-start", "warnings": []])
        try socket.socket.receive(["type": "audio", "audio": "AQI=", "audioFormat": ["type": "audio/pcm", "rate": 24000]])
        try socket.socket.receive(["type": "finish", "usage": ["inputCharacters": 8193]])
        var count = 0
        for try await part in result.stream { if case .audio = part { count += 1 } }
        #expect(count == 1)
        #expect(await weeklySpeechWait { socket.socket.closeCount == 1 })
    }

    @Test func tokenFactoryUsesSpeechRouteAndExactOrigin() async throws {
        let transport = RecordingTransport(response: jsonResponse(#"{"token":"vcst_minted","expiresAt":1700000060}"#))
        let provider = try AIProviders.gateway(configuration: .init(apiKey: "token", baseURL: "https://proxy.test/v4/ai", transport: transport))
        let result = try await provider.experimentalSpeech.getToken(.init(model: "elevenlabs/eleven_v4", expiresAfterSeconds: 120))
        #expect(result.token == "vcst_minted")
        #expect(result.url == "wss://proxy.test/v4/ai/speech-model?ai-model-id=elevenlabs%2Feleven_v4")
        #expect(result.expiresAt == 1700000060)
        let request = try #require(await transport.requests().first)
        #expect(request.url.absoluteString == "https://proxy.test/v1/realtime/client-secrets")
        let body = try decodeJSONBody(try #require(request.body))
        #expect(body["routeKind"] == "speech"); #expect(body["expiresIn"] == 120)
    }

    @Test func typedServerErrorSurvivesCloseAndAudioProjection() async throws {
        let socket = WeeklySpeechSocketTransport()
        let provider = try AIProviders.gateway(configuration: .init(apiKey: "token"), webSocketTransport: socket)
        let model = provider.experimentalSpeech("test/model")
        let result = try AI.experimentalStreamSpeech(model: model, request: .init(text: "hello"))
        #expect(await weeklySpeechWait { !socket.requests.isEmpty })
        socket.socket.open()
        try socket.socket.receive(["type": "audio", "audio": "AQ==", "audioFormat": ["type": "audio/mpeg"]])
        try socket.socket.receive(["type": "error", "error": ["type": "invalid_request_error", "message": "bad voice"]])
        socket.socket.closed(1008)
        do { for try await _ in try result.audioStream {}; Issue.record("Expected typed failure") }
        catch let error as GatewayError { #expect(error.type == .invalidRequestError); #expect(error.statusCode == 400); #expect(error.message == "bad voice") }
    }

    @Test func plainCloseWithoutFinishFailsAndCancelClosesSocket() async throws {
        let socket = WeeklySpeechSocketTransport()
        let provider = try AIProviders.gateway(configuration: .init(apiKey: "token"), webSocketTransport: socket)
        let raw = try await provider.experimentalSpeech("test/model").stream(.init(text: "hello"))
        socket.socket.open(); socket.socket.closed()
        do { for try await _ in raw.stream {}; Issue.record("Expected incomplete stream error") } catch { #expect(String(describing: error).contains("before completion")) }
        #expect(await weeklySpeechWait { socket.socket.closeCount == 1 })
    }
}
