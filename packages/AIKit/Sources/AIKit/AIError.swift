// AIError — the typed error vocabulary every AIProvider throws.
//
// Tier 1 portable. Pure Foundation. The shape is normalized so
// callers can react without provider-specific switches: a "user
// needs to add an API key" UI path doesn't care whether it was
// Anthropic or OpenAI that complained. Each case carries the
// provider identifier so logs and error reports retain that
// detail.

import Foundation

/// Errors any AIProvider can surface.
///
/// Provider implementations should map their native error types
/// onto this enum at the protocol boundary; callers handle
/// AIError without unwrapping further.
public enum AIError: Error, Sendable, Equatable {
    /// The provider couldn't be reached at all (Ollama daemon
    /// not running, network down, DNS failure, etc.).
    /// `underlying` carries an optional human-readable message.
    case providerUnavailable(provider: String, underlying: String?)

    /// The provider rejected our credentials. For BYOK cloud
    /// providers (Anthropic, OpenAI), this is the "user needs
    /// to (re-)enter API key" path.
    case authenticationFailed(provider: String, message: String)

    /// The provider rate-limited us. `retryAfter` (when present)
    /// is the server's suggested wait — typically from
    /// `Retry-After` headers.
    case rateLimited(provider: String, retryAfter: TimeInterval?)

    /// The request was malformed — too long, invalid params,
    /// model-specific constraint violated. Distinct from
    /// authentication failures (different remediation).
    case invalidRequest(provider: String, message: String)

    /// The named model doesn't exist on this provider, or the
    /// user doesn't have access to it.
    case modelNotAvailable(provider: String, model: String)

    /// The provider's response couldn't be decoded into the
    /// AIKit normalized shape — usually a wire-format change on
    /// the provider side. Carries a snippet of the offending
    /// response for diagnostics (truncated to keep logs small).
    case responseDecodingFailed(provider: String, snippet: String)

    /// The request was cancelled (`Task.cancel()` propagated
    /// through). Distinct from a provider-side error.
    case cancelled
}
