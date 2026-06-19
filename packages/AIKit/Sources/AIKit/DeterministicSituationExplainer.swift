// DeterministicSituationExplainer — the always-available, no-AI path.
//
// Per ADR 0095: the deterministic vocabulary (ADR 0072) remains the
// default explainer for everyone; the AI explainer is strictly an
// optional upgrade. This type is that default, plus the fallback the
// AI explainer drops to when no provider is configured, the user is
// offline, or the provider errors — AI is opt-in and local-first
// (ADR 0007/0036) and must never block the explanation.
//
// Pure template strings over a ``RepoSituation``. No git, no network,
// no provider.
//
// Two orderings, answering two questions:
//   * The HEADLINE (what to tell the user first) ranks by salience —
//     parked op > conflicts > detached HEAD > diverged > behind >
//     ahead > dirty > clean — matching the prompt's rules.
//   * The SUGGESTION list leads with resolving uncommitted work
//     (Commit) *before* any sync verb, because git refuses to
//     pull/merge into a dirty tree — so on a dirty-and-behind (or
//     dirty-and-diverged) repo the safest first action is Commit even
//     though the headline leads with the sync state. The two
//     intentionally differ on dirty-vs-sync.
//
// Tier 1 portable. Pure Foundation.

import Foundation

/// Builds a ``SituationExplanation`` from a ``RepoSituation`` with no
/// AI involvement. Deterministic and total: every situation produces
/// a non-empty explanation and at least one suggestion.
public enum DeterministicSituationExplainer {
    /// Explain `situation` using templates only. The returned
    /// explanation's ``SituationExplanation/source`` is always
    /// ``SituationExplanation/Source/deterministic``.
    public static func explain(_ situation: RepoSituation) -> SituationExplanation {
        let suggestions = suggestions(for: situation)
        let text = narrative(for: situation, suggestions: suggestions)
        return SituationExplanation(
            text: text,
            suggestions: suggestions,
            source: .deterministic
        )
    }

    // MARK: - Suggestions (priority-ordered)

    static func suggestions(for situation: RepoSituation) -> [SuggestedAction] {
        if situation.parkedOperation != .none {
            return parkedSuggestions(situation.parkedOperation)
        }
        if situation.conflictedCount > 0 {
            return [
                SuggestedAction(
                    verb: .resolve,
                    rationale: "open each conflicted file and choose what to keep"
                )
            ]
        }
        if situation.isDetachedHead {
            return detachedSuggestions()
        }
        if situation.isDiverged {
            return divergedSuggestions(for: situation)
        }
        return syncSuggestions(for: situation)
    }

    /// Detached HEAD — the canonical beginner "I'm lost" state. Lead
    /// with the one verb that resolves it (Switch back to a branch); a
    /// read-only Fetch would leave the user exactly as stuck.
    private static func detachedSuggestions() -> [SuggestedAction] {
        [
            SuggestedAction(
                verb: .switchBranch,
                rationale: "get back onto a branch so your work is kept and named"
            )
        ]
    }

    private static func parkedSuggestions(_ op: ParkedOperation) -> [SuggestedAction] {
        [
            SuggestedAction(
                verb: .continueOperation,
                rationale: "finish the \(op.label) once any conflicts are resolved"
            ),
            SuggestedAction(
                verb: .abort,
                rationale: "back out of the \(op.label) and return to where you started"
            )
        ]
    }

    private static func divergedSuggestions(for situation: RepoSituation) -> [SuggestedAction] {
        var out: [SuggestedAction] = []
        // Lead with Commit when the tree is dirty: git refuses to pull /
        // merge into uncommitted changes, so suggesting Pull first would
        // hand a beginner an action that fails. Save the work first.
        if !situation.isClean {
            out.append(SuggestedAction(
                verb: .commit,
                rationale: "save your current changes first so they aren't disturbed when the histories combine"
            ))
        }
        out.append(SuggestedAction(
            verb: .pull,
            rationale: "bring the server's new commits in and combine them with yours"
        ))
        out.append(SuggestedAction(
            verb: .fetch,
            rationale: "just look at what changed on the server first, changing nothing locally"
        ))
        return out
    }

    private static func syncSuggestions(for situation: RepoSituation) -> [SuggestedAction] {
        var out: [SuggestedAction] = []
        if !situation.isClean {
            out.append(SuggestedAction(
                verb: .commit,
                rationale: "save your current changes as a commit"
            ))
        }
        if situation.behind > 0 {
            out.append(SuggestedAction(
                verb: .pull,
                rationale: "catch up to the \(situation.behind) commit(s) waiting on the server"
            ))
        }
        if situation.ahead > 0 {
            out.append(SuggestedAction(
                verb: .push,
                rationale: "send your \(situation.ahead) commit(s) up to the server"
            ))
        }
        if out.isEmpty {
            out.append(SuggestedAction(
                verb: .fetch,
                rationale: "check the server for anything new (this changes nothing locally)"
            ))
        }
        return out
    }

    // MARK: - Narrative

    private static func narrative(
        for situation: RepoSituation,
        suggestions: [SuggestedAction]
    ) -> String {
        let headline = headline(for: situation)
        let actions = suggestions
            .map { "- \($0.verb.rawValue) — \($0.rationale)" }
            .joined(separator: "\n")
        return headline + "\n\n" + actions
    }

    private static func headline(for situation: RepoSituation) -> String {
        if situation.parkedOperation != .none {
            return "A \(situation.parkedOperation.label) is paused part-way through. "
                + "You can finish it or back out — nothing is lost either way."
        }
        if situation.conflictedCount > 0 {
            return "\(situation.conflictedCount) file(s) have conflicting edits that need a "
                + "decision before you can move on."
        }
        if situation.isDetachedHead {
            return "You're not on a branch right now (a 'detached HEAD'); new commits here "
                + "aren't attached to anything yet."
        }
        return syncHeadline(for: situation)
    }

    private static func syncHeadline(for situation: RepoSituation) -> String {
        let place = situation.branchName.map { "On branch \($0). " } ?? ""
        if situation.isDiverged {
            return place + "Your branch and the server's copy have each moved on "
                + "independently (called 'diverged')."
        }
        if situation.upstreamGone {
            return place + "The branch this one followed on the server is gone."
        }
        if situation.behind > 0 {
            return place + "The server has \(situation.behind) commit(s) you don't have yet."
        }
        if situation.ahead > 0 {
            return place + "You have \(situation.ahead) commit(s) the server hasn't seen yet."
        }
        if !situation.isClean {
            return place + "You have unsaved changes in your working files."
        }
        return place + "Everything is clean and in sync — nothing needs doing right now."
    }
}
