// AIProvider — the contract every AI backend implements.
//
// Tier 1 portable. Pure Foundation. Provider-side concerns
// (API keys, model selection, network endpoint) are handled by
// each implementation's init — the protocol is intentionally
// minimal so it can survive future providers without churn.
//
// Cancellation propagates through Swift's structured concurrency:
// `complete(request:)` is `async throws`, so callers' `Task.cancel()`
// flows down to the underlying `URLSession.data(for:)` /
// `Process` invocations naturally. Implementations should map any
// observed cancellation to ``AIError/cancelled``.

import Foundation

/// A single AI backend (Ollama, Anthropic, OpenAI, Apple
/// Foundation Models, or a test fake) capable of completing one
/// ``AIRequest`` at a time.
///
/// **Sendable.** Providers are typically reused across many
/// requests — a long-lived `OllamaProvider` configured once with
/// a model name, then called repeatedly. `Sendable` lets callers
/// share an instance across actors / Tasks without per-call
/// reconstruction. Implementations should be thread-safe by
/// construction (immutable + actor-isolated mutable state, or
/// stateless pass-through to URLSession).
///
/// **One method.** `complete(request:)` is the whole contract.
/// Streaming, chat history, tool-use, embeddings — all are
/// future protocol extensions. Keeping this slice tight means
/// concrete provider implementations can land before the
/// protocol shape is fully nailed down.
///
/// **Error mapping.** Implementations translate native errors
/// (HTTP status codes, OllamaError, AnthropicAPIError…) onto
/// ``AIError`` at the protocol boundary so callers handle one
/// vocabulary regardless of provider.
public protocol AIProvider: Sendable {
    /// Stable identifier for this provider instance (e.g.
    /// `"ollama"`, `"anthropic"`, `"openai"`, `"apple"`,
    /// `"mock"`). Surfaced in ``AIError`` cases so logs and
    /// telemetry retain the provenance.
    var identifier: String { get }

    /// Run one completion. Throws ``AIError`` (or one of its
    /// cases) on failure; returns an ``AIResponse`` on success.
    func complete(request: AIRequest) async throws -> AIResponse
}
