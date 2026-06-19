// AISituationExplainer — ADR 0095's opt-in "what should I do now?" guide.
//
// Turns a ``RepoSituation`` snapshot into a plain-language explanation
// plus suggested next Sprig verbs. AI is opt-in and local-first
// (ADR 0007/0036): the explainer takes any ``AIProvider`` (default in
// production is Ollama; cloud providers are BYOK + per-action
// confirmation — a Tier-3 boundary this engine never bypasses), but if
// no provider is configured, the user is offline, or the provider
// errors, it falls back to ``DeterministicSituationExplainer`` rather
// than blocking. Suggest-only (ADR 0028): the result names verbs the
// user clicks; this engine never executes anything.
//
// Tier 1 portable. Pure Foundation. Actor-isolated so a single
// explainer can be shared across the task window's refreshes.

import Foundation

/// Explains a repository situation, AI-first with a deterministic
/// fallback.
public actor AISituationExplainer {
    /// The prompt this explainer renders. Pinned to the shipped
    /// version so a bundled-prompt rename is a deliberate, visible
    /// change (the v-suffix is the version per ADR 0037).
    public static let promptName = "situation-explainer-v1"

    /// Token ceiling for the completion. The prompt caps the reply at
    /// ~120 words; this leaves generous headroom without inviting a
    /// runaway essay.
    public static let maxTokens = 400

    /// Low temperature: the explanation should be stable and
    /// conservative, not creative (ADR 0095's "safest next step").
    public static let temperature = 0.2

    private let provider: AIProvider?
    private let prompt: Prompt

    /// Construct with an optional provider and an explicit prompt.
    /// Passing `provider: nil` (AI disabled) makes ``explain(_:)``
    /// take the deterministic path unconditionally.
    ///
    /// `prompt` defaults to the bundled `situation-explainer-v1`. A
    /// caller honoring the user-overridable prompt directory (ADR
    /// 0037) loads its own ``Prompt`` via ``PromptLoader`` and passes
    /// it here.
    public init(provider: AIProvider?, prompt: Prompt) {
        self.provider = provider
        self.prompt = prompt
    }

    /// Convenience init that loads the bundled prompt. Throws only if
    /// the shipped resource is missing (a packaging bug, not a runtime
    /// condition) — callers that can't tolerate a throw should load
    /// the prompt themselves and use ``init(provider:prompt:)``.
    public init(provider: AIProvider?) throws {
        let bundled = try PromptLoader.loadBundled(named: Self.promptName)
        self.init(provider: provider, prompt: bundled)
    }

    /// Explain `situation`. Tries the provider when one is configured;
    /// on any ``AIError`` (or when no provider is set) returns the
    /// deterministic explanation. Never throws — the fallback is
    /// always available, so the caller always gets an answer.
    public func explain(_ situation: RepoSituation) async -> SituationExplanation {
        guard let provider else {
            return DeterministicSituationExplainer.explain(situation)
        }
        let request = AIRequest(
            systemPrompt: prompt.body,
            userPrompt: Self.renderSnapshot(situation),
            maxTokens: Self.maxTokens,
            temperature: Self.temperature
        )
        do {
            let response = try await provider.complete(request: request)
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty completion is as useless as an error — fall back
            // rather than surface a blank explanation. Likewise fall back
            // when the model's prose breaks a hard prompt safety rule
            // (instructing raw git, or implying data was lost): the prompt
            // forbids both, but the prompt is advisory, so this is the
            // runtime backstop ADR 0095 names ("eval coverage is needed to
            // keep guidance safe"). The deterministic prose is always safe.
            guard !text.isEmpty, !Self.violatesSafetyRules(text) else {
                return DeterministicSituationExplainer.explain(situation)
            }
            // The AI authors the prose; the suggestion chips stay
            // deterministic so the UI always has clickable verbs mapped
            // to real Sprig affordances (the prompt is told to use the
            // same closed verb set).
            return SituationExplanation(
                text: text,
                suggestions: DeterministicSituationExplainer.suggestions(for: situation),
                source: .ai
            )
        } catch is AIError {
            return DeterministicSituationExplainer.explain(situation)
        } catch {
            // Any non-AIError (e.g. a cancellation surfaced as a
            // generic error) also falls back — never block on AI.
            return DeterministicSituationExplainer.explain(situation)
        }
    }

    // MARK: - Safety guard

    /// Whether the model's prose violates a hard prompt safety rule and
    /// must be rejected in favor of the deterministic explanation:
    ///
    ///   * **Raw git instructions.** The explainer is suggest-only
    ///     (ADR 0028) — the user clicks a Sprig verb; the prose must not
    ///     tell them to run `git …` themselves. Matched on the
    ///     `git <verb>` command forms that are essentially never benign
    ///     noun phrases — the history-rewriting and sync commands. The
    ///     ambiguous noun-forms (`git branch`, `git commit`, `git add`,
    ///     `git merge` — as in "your Git branch", "a git merge conflict")
    ///     are deliberately NOT matched, so plain mentions of "Git" the
    ///     tool aren't false-flagged. The dangerous verbs (reset, rebase,
    ///     checkout, revert, …) are the ones the prompt most needs to
    ///     keep out of a beginner's hands, and they read as commands here.
    ///   * **Data-loss phrasing.** Sprig keeps recoverable snapshots
    ///     before anything destructive; the prose must never imply work
    ///     is gone (a beginner-reassurance rule whose harm — scaring a
    ///     novice — is real even when no bytes were lost).
    static func violatesSafetyRules(_ text: String) -> Bool {
        let lower = text.lowercased()
        let rawGitCommands = [
            "git reset", "git rebase", "git checkout", "git revert",
            "git cherry-pick", "git clean", "git reflog", "git rm",
            "git config", "git restore", "git push", "git pull",
            "git fetch", "git stash", "git switch", "git --"
        ]
        if rawGitCommands.contains(where: { lower.contains($0) }) {
            return true
        }
        let dataLossPhrases = [
            "lost forever", "permanently lost", "cannot be recovered",
            "can't be recovered", "cannot recover", "unrecoverable",
            "your changes are gone", "your work is gone", "data is gone",
            "gone forever", "no way to recover", "lost your"
        ]
        return dataLossPhrases.contains(where: { lower.contains($0) })
    }

    // MARK: - Snapshot rendering

    /// Render `situation` as the plain-text snapshot appended to the
    /// prompt's user block. Stable field order keeps prompts diffable
    /// and lets eval fixtures pin the input the model sees.
    static func renderSnapshot(_ situation: RepoSituation) -> String {
        var lines = ["Repository snapshot:"]
        if situation.isDetachedHead {
            lines.append("- HEAD: detached (not on a branch)")
        } else {
            lines.append("- branch: \(situation.branchName ?? "(unknown)")")
        }
        if let upstream = situation.upstreamName {
            lines.append("- upstream: \(upstream)\(situation.upstreamGone ? " (gone)" : "")")
        } else {
            lines.append("- upstream: none configured")
        }
        lines.append("- ahead of upstream: \(situation.ahead) commit(s)")
        lines.append("- behind upstream: \(situation.behind) commit(s)")
        lines.append("- staged changes: \(situation.stagedCount)")
        lines.append("- unstaged changes: \(situation.unstagedCount)")
        lines.append("- untracked files: \(situation.untrackedCount)")
        lines.append("- conflicted files: \(situation.conflictedCount)")
        lines.append("- parked operation: \(situation.parkedOperation.label)")
        if !situation.recentReflog.isEmpty {
            lines.append("- recent activity (newest first):")
            for entry in situation.recentReflog.prefix(5) {
                lines.append("  - \(entry)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
