// SituationExplanation — the output of the situation explainer.
//
// Per ADR 0095: a plain-language explanation plus one or more
// SUGGESTED next actions, each mapped to an existing Sprig verb. It
// never executes anything — the user picks a verb, which runs through
// the normal (snapshotted, confirmed) path.
//
// Tier 1 portable. Pure Foundation.

import Foundation

/// The explainer's result: human-readable text plus structured
/// suggestions, tagged with whether the AI path or the deterministic
/// fallback produced it.
public struct SituationExplanation: Sendable, Equatable {
    /// The plain-language explanation shown to the user. From the AI
    /// provider when ``source`` is ``Source/ai``; assembled from
    /// templates when ``Source/deterministic``.
    public var text: String

    /// Suggested next verbs, most-recommended first. The
    /// deterministic path always populates this; the AI path mirrors
    /// the same structured suggestions so the UI can render clickable
    /// affordances regardless of source.
    public var suggestions: [SuggestedAction]

    /// Whether AI or the deterministic fallback produced ``text``.
    public var source: Source

    public init(
        text: String,
        suggestions: [SuggestedAction],
        source: Source
    ) {
        self.text = text
        self.suggestions = suggestions
        self.source = source
    }

    /// Where the explanation came from.
    public enum Source: String, Sendable, Equatable {
        /// Produced by the injected `AIProvider`.
        case ai
        /// Produced by the built-in template fallback (no provider,
        /// offline, or the provider errored). AI is opt-in and
        /// local-first (ADR 0007/0036); the deterministic path keeps
        /// the explainer from ever blocking on AI.
        case deterministic
    }
}

/// One suggested next action, mapped to a Sprig verb. Suggest-only
/// (ADR 0028): selecting it runs through Sprig's normal confirmed,
/// snapshotted path — this type carries no side effects.
public struct SuggestedAction: Sendable, Equatable {
    /// The Sprig verb to surface as a clickable affordance.
    public var verb: SprigVerb

    /// One-line "what it does and why" for this situation.
    public var rationale: String

    public init(verb: SprigVerb, rationale: String) {
        self.verb = verb
        self.rationale = rationale
    }
}

/// The Sprig verbs the explainer is allowed to suggest. A closed set
/// so the prompt and the deterministic path can never propose an
/// action with no corresponding Sprig affordance.
public enum SprigVerb: String, Sendable, Equatable, CaseIterable {
    case commit = "Commit"
    case fetch = "Fetch"
    case pull = "Pull"
    case push = "Push"
    case sync = "Sync"
    case continueOperation = "Continue"
    case abort = "Abort"
    case recover = "Recover"
    case stash = "Stash"
    case switchBranch = "Switch"
    case resolve = "Resolve"
}
