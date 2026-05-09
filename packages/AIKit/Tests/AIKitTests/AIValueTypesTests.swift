@testable import AIKit
import Foundation
import Testing

@Suite("AIRequest")
struct AIRequestTests {
    @Test("default initializer fills only userPrompt; everything else nil")
    func defaultInit() {
        let request = AIRequest(userPrompt: "explain this conflict")
        #expect(request.userPrompt == "explain this conflict")
        #expect(request.systemPrompt == nil)
        #expect(request.maxTokens == nil)
        #expect(request.temperature == nil)
    }

    @Test("equality treats unspecified fields as equal")
    func equality() {
        let a = AIRequest(userPrompt: "x")
        let b = AIRequest(userPrompt: "x")
        #expect(a == b)
        let c = AIRequest(userPrompt: "x", maxTokens: 100)
        #expect(a != c)
    }

    @Test("system + user prompts are independent")
    func systemAndUserPrompts() {
        let request = AIRequest(systemPrompt: "you are a helpful assistant", userPrompt: "hi")
        #expect(request.systemPrompt == "you are a helpful assistant")
        #expect(request.userPrompt == "hi")
    }
}

@Suite("AIResponse")
struct AIResponseTests {
    @Test("default initializer requires text + finishReason; tokens optional")
    func defaultInit() {
        let response = AIResponse(text: "hello", finishReason: .stop)
        #expect(response.text == "hello")
        #expect(response.finishReason == .stop)
        #expect(response.inputTokens == nil)
        #expect(response.outputTokens == nil)
    }

    @Test("FinishReason.other carries provider's raw reason")
    func finishReasonOther() {
        let response = AIResponse(
            text: "...",
            finishReason: .other("content_filter")
        )
        #expect(response.finishReason == .other("content_filter"))
        #expect(response.finishReason != .stop)
        #expect(response.finishReason != .length)
    }

    @Test("FinishReason.other equality is value-based, not reference-based")
    func finishReasonOtherEquality() {
        #expect(FinishReason.other("foo") == FinishReason.other("foo"))
        #expect(FinishReason.other("foo") != FinishReason.other("bar"))
    }

    @Test("token counts encode the typical billing case")
    func tokenCounts() {
        let response = AIResponse(
            text: "hi",
            finishReason: .stop,
            inputTokens: 42,
            outputTokens: 7
        )
        #expect(response.inputTokens == 42)
        #expect(response.outputTokens == 7)
    }
}

@Suite("AIError")
struct AIErrorTests {
    @Test("providerUnavailable carries provider id and optional underlying")
    func providerUnavailable() {
        let err = AIError.providerUnavailable(
            provider: "ollama",
            underlying: "connection refused"
        )
        #expect(err == .providerUnavailable(provider: "ollama", underlying: "connection refused"))
    }

    @Test("rateLimited's retryAfter is optional")
    func rateLimited() {
        let bare = AIError.rateLimited(provider: "openai", retryAfter: nil)
        #expect(bare == .rateLimited(provider: "openai", retryAfter: nil))
        let withRetry = AIError.rateLimited(provider: "openai", retryAfter: 30)
        #expect(withRetry == .rateLimited(provider: "openai", retryAfter: 30))
        #expect(bare != withRetry)
    }

    @Test("authenticationFailed and invalidRequest are distinct cases")
    func distinctCases() {
        let auth = AIError.authenticationFailed(provider: "anthropic", message: "bad key")
        let invalid = AIError.invalidRequest(provider: "anthropic", message: "bad key")
        #expect(auth != invalid)
    }

    @Test("cancelled has no payload — used as a sentinel")
    func cancelled() {
        let one = AIError.cancelled
        let two = AIError.cancelled
        #expect(one == two)
    }
}
