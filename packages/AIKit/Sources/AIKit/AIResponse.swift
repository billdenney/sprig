// AIResponse — the output of an AIKit provider's completion.
//
// Tier 1 portable. Pure Foundation. Symmetric with `AIRequest` —
// not `Codable` because there's no shared wire format across
// providers; per-provider adapters convert their native response
// to this normalized shape.

import Foundation

/// A completed AI response.
public struct AIResponse: Sendable, Equatable {
    /// The model's generated text. Trimmed of leading/trailing
    /// whitespace by the provider where reasonable; Sprig callers
    /// trust this is "the thing to show the user."
    public var text: String

    /// Why the provider stopped generating.
    public var finishReason: FinishReason

    /// Tokens charged on the input side. Nil when the provider
    /// doesn't expose token counts (e.g., some local Ollama
    /// builds, Apple Foundation Models pre-public API).
    public var inputTokens: Int?

    /// Tokens charged on the output side. Nil per the same
    /// rationale as ``inputTokens``.
    public var outputTokens: Int?

    public init(
        text: String,
        finishReason: FinishReason,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.text = text
        self.finishReason = finishReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Why a model stopped generating tokens. Stable across
/// providers; provider-specific reasons fall under ``other``.
public enum FinishReason: Sendable, Equatable {
    /// Model returned its full intended completion (a stop token,
    /// end-of-sequence, etc.). The default "successful finish."
    case stop

    /// Output was truncated to fit within the request's
    /// `maxTokens` (or the provider's hard limit). Callers
    /// commonly retry with a higher cap.
    case length

    /// Provider reported a finish reason we haven't normalized.
    /// Carries the provider's raw reason string for diagnostics.
    case other(String)
}
