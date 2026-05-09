@testable import AIKit
import Foundation
import Testing

@Suite("MockAIProvider")
struct MockAIProviderTests {
    @Test("identifier defaults to 'mock' but is configurable")
    func identifier() {
        let mock = MockAIProvider(outcomes: [])
        #expect(mock.identifier == "mock")
        let renamed = MockAIProvider(identifier: "fake", outcomes: [])
        #expect(renamed.identifier == "fake")
    }

    @Test("sequence mode returns scripted responses in order")
    func sequenceModeOrder() async throws {
        let r1 = AIResponse(text: "first", finishReason: .stop)
        let r2 = AIResponse(text: "second", finishReason: .stop)
        let mock = MockAIProvider(outcomes: [.response(r1), .response(r2)])

        let out1 = try await mock.complete(request: AIRequest(userPrompt: "a"))
        let out2 = try await mock.complete(request: AIRequest(userPrompt: "b"))
        #expect(out1.text == "first")
        #expect(out2.text == "second")
    }

    @Test("sequence mode throws when the script is exhausted")
    func sequenceModeExhausts() async {
        let r = AIResponse(text: "only", finishReason: .stop)
        let mock = MockAIProvider(outcomes: [.response(r)])
        _ = try? await mock.complete(request: AIRequest(userPrompt: "ok"))

        do {
            _ = try await mock.complete(request: AIRequest(userPrompt: "boom"))
            Issue.record("expected providerUnavailable but call succeeded")
        } catch let error as AIError {
            switch error {
            case let .providerUnavailable(provider, underlying):
                #expect(provider == "mock")
                #expect(underlying?.contains("exhausted") == true)
            default:
                Issue.record("expected providerUnavailable, got \(error)")
            }
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }

    @Test("sequence mode throws scripted errors")
    func sequenceModeThrowsScriptedErrors() async {
        let mock = MockAIProvider(outcomes: [
            .error(.rateLimited(provider: "mock", retryAfter: 5))
        ])
        do {
            _ = try await mock.complete(request: AIRequest(userPrompt: "x"))
            Issue.record("expected throw")
        } catch let error as AIError {
            #expect(error == .rateLimited(provider: "mock", retryAfter: 5))
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }

    @Test("always mode returns the same response every call")
    func alwaysModeRepeats() async throws {
        let r = AIResponse(text: "same", finishReason: .stop)
        let mock = MockAIProvider.always(r)
        for _ in 0 ..< 5 {
            let response = try await mock.complete(request: AIRequest(userPrompt: "ping"))
            #expect(response.text == "same")
        }
    }

    @Test("requestLog records every observed request in order")
    func requestLogRecords() async throws {
        let r = AIResponse(text: "ack", finishReason: .stop)
        let mock = MockAIProvider.always(r)

        _ = try await mock.complete(request: AIRequest(userPrompt: "first"))
        _ = try await mock.complete(request: AIRequest(systemPrompt: "sys", userPrompt: "second"))

        let log = await mock.requestLog
        #expect(log.count == 2)
        #expect(log[0].userPrompt == "first")
        #expect(log[1].userPrompt == "second")
        #expect(log[1].systemPrompt == "sys")
    }
}
