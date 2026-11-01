import Foundation
import Testing
@testable import SwiftAIGateway
import SwiftAIProvider
import SwiftAITransport

@Suite struct Weekly20261101CancellationTests {
    @Test func httpAndTokenFactoriesPreserveCallerCancellationIdentity() async throws {
        for name in ["AbortError", "TimeoutError"] {
            let error = NSError(domain: name, code: 42)
            let transport = WeeklyGatewayThrowingTransport(error: error)
            let provider = try GatewayProvider(configuration: .init(apiKey: "token", transport: transport))
            do { _ = try await provider.languageModel("test/model").generate(.init(messages: [.user("Hello")])); Issue.record("Expected failure") }
            catch let caught as NSError { #expect(caught === error) }
            do { _ = try await provider.experimentalTranscription.getToken(.init(model: "test/model")); Issue.record("Expected failure") }
            catch let caught as NSError { #expect(caught === error) }
            do { _ = try await provider.experimentalSpeech.getToken(.init(model: "test/model")); Issue.record("Expected failure") }
            catch let caught as NSError { #expect(caught === error) }
            do { for try await _ in try provider.languageModel("test/model").stream(.init(messages: [.user("Hello")])) {}; Issue.record("Expected failure") }
            catch let caught as NSError { #expect(caught === error) }
        }
    }

    @Test func speechTextFailureRetainsOriginalErrorAndClosesSocket() async throws {
        for name in ["AbortError", "TimeoutError"] {
            let error = NSError(domain: name, code: 42)
            let input = AsyncThrowingStream<SpeechTextPart, Error>.makeStream()
            let socket = WeeklySpeechSocketTransport()
            let provider = try GatewayProvider(configuration: .init(apiKey: "token"), webSocketTransport: socket)
            let result = try await provider.experimentalSpeech("test/model").stream(.init(text: AIStreamingTextInput(input.stream)))
            socket.socket.open()
            input.continuation.finish(throwing: error)
            do { for try await _ in result.stream {}; Issue.record("Expected original error") }
            catch let caught as NSError { #expect(caught === error) }
            #expect(await weeklySpeechWait { socket.socket.closeCount == 1 })
        }
    }

    @Test func transcriptionAudioFailureRetainsOriginalErrorAndClosesSocket() async throws {
        for error: any Error in [NSError(domain: "TimeoutError", code: 42), CancellationError()] {
            let input = AsyncThrowingStream<Data, Error>.makeStream()
            let socket = WeeklySpeechSocketTransport()
            let provider = try GatewayProvider(configuration: .init(apiKey: "token"), webSocketTransport: socket)
            let result = try await provider.experimentalTranscription("test/model").stream(.init(audio: AIStreamingAudioInput(input.stream), inputAudioFormat: .init(mediaType: "audio/pcm", sampleRate: 16000)))
            socket.socket.open()
            input.continuation.finish(throwing: error)
            do { for try await _ in result.stream {}; Issue.record("Expected original error") }
            catch { #expect(gatewayIsCallerCancellation(error)) }
            #expect(await weeklySpeechWait { socket.socket.closeCount == 1 })
        }
    }

    @Test func blankCredentialCallbackFailsBeforeSending() async throws {
        let transport = RecordingTransport(response: jsonResponse("{}"))
        let provider = try GatewayProvider(configuration: .init(apiKeyProvider: { " " }, transport: transport))
        await #expect(throws: AIError.invalidArgument(argument: "apiKeyProvider", message: "AI Gateway API key must be a non-empty string.")) {
            _ = try await provider.languageModel("test/model").generate(.init(messages: [.user("Hello")]))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func metadataErrorsDoNotResolveCredentialAgainForErrorClassification() async throws {
        let keys = WeeklyGatewayKeySequence()
        let transport = RecordingTransport(response: .init(statusCode: 401, body: Data(#"{"error":{"type":"authentication_error","message":"No access"}}"#.utf8)))
        let provider = try GatewayProvider(configuration: .init(apiKeyProvider: { await keys.next() }, transport: transport))
        #expect(await keys.count == 0)
        do { _ = try await provider.getAvailableModels(); Issue.record("Expected error") } catch {}
        do { _ = try await provider.getCredits(); Issue.record("Expected error") } catch {}
        #expect(await keys.count == 2)
        let requests = await transport.requests()
        #expect(requests.map { normalizeHeaders($0.headers)["authorization"] } == ["Bearer key-1", "Bearer key-2"])
    }

    @Test func duplexCredentialsRefreshAtConnectionAndRespectHeaderOverrides() async throws {
        for speech in [false, true] {
            let keys = WeeklyGatewayKeySequence()
            let socket = WeeklySpeechSocketTransport()
            let provider = try GatewayProvider(configuration: .init(apiKeyProvider: { await keys.next() }), webSocketTransport: socket)
            #expect(await keys.count == 0)
            for override in [false, true, false] {
                let headers = override ? ["Authorization": "Bearer override-key"] : [:]
                if speech {
                    let result = try await provider.experimentalSpeech("test/model").stream(.init(text: .text("Hello"), headers: headers))
                    result.cancel()
                } else {
                    let input = AsyncThrowingStream<Data, Error>.makeStream()
                    let result = try await provider.experimentalTranscription("test/model").stream(.init(audio: AIStreamingAudioInput(input.stream), inputAudioFormat: .init(mediaType: "audio/pcm", sampleRate: 16000), headers: headers))
                    result.cancel()
                    input.continuation.finish()
                }
                let request = try #require(socket.requests.last)
                let count = await keys.count
                #expect(normalizeHeaders(request.headers)["authorization"] == (override ? "Bearer override-key" : "Bearer key-\(count)"))
                #expect(!request.headers.values.contains { $0.contains("__swift_ai_credential_") })
                #expect(request.protocols.contains("ai-gateway-auth." + (override ? "override-key" : "key-\(count)")))
            }
            #expect(await keys.count == 2)
        }
    }
}

private actor WeeklyGatewayKeySequence {
    private(set) var count = 0
    func next() -> String { count += 1; return "key-\(count)" }
}

private struct WeeklyGatewayThrowingTransport: AIStreamingTransport {
    let error: NSError
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse { throw error }
    func stream(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse { throw error }
}
