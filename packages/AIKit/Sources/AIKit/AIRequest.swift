// AIRequest — the input to any AIKit provider.
//
// Tier 1 portable. Pure Foundation. Wire-shape-agnostic: each
// provider (Ollama, Anthropic, OpenAI, Apple Foundation Models)
// converts an `AIRequest` into its own JSON / native format. We
// intentionally do NOT make this `Codable` — there's no single wire
// format every provider speaks, and pretending otherwise would
// commit downstream code to one provider's vocabulary.
//
// Per ADR 0007: AI integration is optional, pluggable, provider-
// agnostic. This struct is the protocol-level vocabulary; provider
// implementations live alongside.

import Foundation

/// A single, completion-shaped request to an AI provider.
///
/// Sprig's M7 use cases — merge conflict suggestions, commit
/// message drafting, PR description drafting — are all single-shot
/// text-in/text-out. Streaming and chat-history modeling are
/// follow-ups; this first slice keeps the surface as small as the
/// callers actually need.
public struct AIRequest: Sendable, Equatable {
    /// Optional system prompt — instruction that shapes the model's
    /// behavior across the whole completion. Most Sprig prompts in
    /// `Sources/AIKit/Prompts/*.md` (per ADR 0037) split into a
    /// system block and a user block; this is the system block.
    public var systemPrompt: String?

    /// Required user prompt — the actual content the model is
    /// asked to act on (a conflict block, a staged diff, etc.).
    public var userPrompt: String

    /// Maximum tokens the provider should emit. Nil leaves it to
    /// the provider's default. Sprig prompts target compact
    /// completions — typically a few hundred tokens — so callers
    /// usually pin this rather than rely on provider defaults.
    public var maxTokens: Int?

    /// Sampling temperature, 0.0 (greedy) to 1.0+ (creative). Nil
    /// uses the provider's default. Sprig's conflict / commit-
    /// message use cases prefer low temperatures (0.0–0.3) for
    /// determinism.
    public var temperature: Double?

    public init(
        systemPrompt: String? = nil,
        userPrompt: String,
        maxTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}
