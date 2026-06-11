// DestructiveOpTier.swift
//
// Slice S5 of ADR 0033 — the three-tier confirmation policy that drives
// how destructive ops surface to the user. The data lives here; the
// strings, dialogs, typed-phrase prompts, and banner UI live in the
// task windows that consume these values.
//
// Pairing with the rest of the SafetyKit surface:
//   * `SnapshotRefName` (S1) — the ref-name format.
//   * `SnapshotWriter` (S2) — writes the snapshot before the op runs.
//   * `SnapshotWriter.withSnapshot(...)` (S4) — wraps any async body
//     with an auto-snapshot using the writer above.
//   * `RepoState.SnapshotIndex` (S3, in `RepoState`) — read/prune.
//   * `DestructiveOpTier` (S5, this file) — drives the *confirmation*
//     surface a caller pairs with the snapshot for a given op.
//
// Callers (typically a destructive-op task window's view model) ask
// `DestructiveOpTier.tier(for: SnapshotRefName.opResetHard)` to decide
// what confirmation chrome to show, then call
// `SnapshotWriter.withSnapshot` when `tier.requiresSnapshot` is true.

import Foundation

/// The confirmation policy for a destructive git operation, per ADR 0033's
/// three-tier model (master plan §3, ADR 0033 ratification).
///
/// **Pure data.** No git invocation here; no UI strings. The accessors
/// (``requiresSnapshot``, ``requiresTypedPhrase``, ``undoBannerPolicy``)
/// are inputs to a destructive-op task window's confirmation flow:
///
///   1. Look up the tier for the user's chosen op via ``tier(for:)``.
///   2. Show the right confirmation: single-button for ``low``,
///      confirm + snapshot for ``medium``, typed-phrase + snapshot for
///      ``high``.
///   3. If ``requiresSnapshot``, wrap the op in
///      ``SnapshotWriter/withSnapshot(op:target:_:)``.
///   4. After success, show the undo banner per ``undoBannerPolicy``.
///
/// **Fail-closed lookup.** ``tier(for:)`` returns `nil` for unknown op
/// strings rather than defaulting to ``low`` — adding a new destructive
/// op to the project MUST come with an explicit tier classification.
/// Defaulting to ``low`` would silently weaken the safety surface every
/// time a new op is introduced without a tier decision.
public enum DestructiveOpTier: Sendable, Equatable, Hashable, CaseIterable {
    /// Single confirm; no snapshot is taken.
    ///
    /// Per the master plan: `reset --mixed`, unstaged discard. The user
    /// might lose unstaged work, but staged work and committed history
    /// are untouched, so a snapshot would be overhead with no recovery
    /// value.
    case low

    /// Confirm + auto-snapshot under `refs/sprig/snapshots/...`.
    ///
    /// Per the master plan: `reset --hard`, branch delete with unpushed
    /// commits, stash drop, rebase on divergent history, merge,
    /// cherry-pick, revert, checkout with dirty tree. These all alter
    /// state that can't be reconstructed from any other source, so the
    /// snapshot is the user's only undo path.
    case medium

    /// Typed-phrase confirm + auto-snapshot + persistent undo banner.
    ///
    /// Per the master plan: `force-push` (always emitted as
    /// `--force-with-lease --force-if-includes`), `filter-repo`,
    /// `subtree split` that rewrites. These are operations whose
    /// consequences extend beyond the local repo or rewrite history;
    /// the typed-phrase friction is intentional.
    case high

    // MARK: - Policy accessors

    /// True if a destructive-op caller should snapshot via
    /// ``SnapshotWriter/withSnapshot(op:target:_:)`` before running the
    /// op. ``low`` returns false; ``medium`` and ``high`` return true.
    public var requiresSnapshot: Bool {
        switch self {
        case .low: false
        case .medium, .high: true
        }
    }

    /// True if confirmation must be a typed phrase (e.g. type
    /// `FORCE-PUSH` to continue) rather than a single button press.
    /// Only ``high`` returns true.
    public var requiresTypedPhrase: Bool {
        switch self {
        case .low, .medium: false
        case .high: true
        }
    }

    /// Undo-banner behavior to apply after the op succeeds.
    ///
    /// ``low`` → ``UndoBannerPolicy/none`` (nothing to undo via a
    ///   snapshot; the op didn't snapshot).
    /// ``medium`` → ``UndoBannerPolicy/autoDismiss(after:)`` 24 hours
    ///   per the master plan's "Sprig saved your work here, undo is
    ///   available for 24h" notice.
    /// ``high`` → ``UndoBannerPolicy/persistent`` — the banner stays
    ///   until the user explicitly dismisses it (master plan: "persistent
    ///   undo banner until explicitly dismissed").
    public var undoBannerPolicy: UndoBannerPolicy {
        switch self {
        case .low: .none
        case .medium: .autoDismiss(after: .seconds(24 * 60 * 60))
        case .high: .persistent
        }
    }

    // MARK: - Lookup

    /// Map an op-tag string (the same strings used as
    /// ``SnapshotRefName/opXxx`` constants) to its tier.
    ///
    /// Returns nil for unrecognized inputs so the caller is forced to
    /// add an explicit tier classification when introducing a new
    /// destructive op. **Do not default to ``low``** — that would
    /// silently weaken the safety surface every time a new op is
    /// introduced without a tier review.
    ///
    /// - Parameter op: An op-tag string, typically one of the
    ///   ``SnapshotRefName`` `opXxx` constants. Must match
    ///   ``SnapshotRefName/isValidOp(_:)`` to be eligible, but the
    ///   reverse isn't true — a syntactically-valid op-tag with no
    ///   registered tier returns nil.
    public static func tier(for op: String) -> DestructiveOpTier? {
        switch op {
        // Low tier — no snapshot, single confirm.
        // These op-tags are listed here for `tier(for:)` lookup but do
        // not appear in `SnapshotRefName.opXxx` because low-tier ops
        // don't write snapshot refs.
        case "reset-mixed", "discard-unstaged":
            .low

        // Medium tier — confirm + snapshot.
        case SnapshotRefName.opMerge,
             SnapshotRefName.opRebase,
             SnapshotRefName.opResetHard,
             SnapshotRefName.opStashDrop,
             SnapshotRefName.opCherryPick,
             SnapshotRefName.opRevert,
             SnapshotRefName.opBranchDelete,
             SnapshotRefName.opCheckoutDirty,
             SnapshotRefName.opReword,
             SnapshotRefName.opSquash:
            .medium

        // High tier — typed-phrase + snapshot + persistent banner.
        case SnapshotRefName.opForcePush:
            .high

        default:
            nil
        }
    }
}

/// How an undo banner behaves after a destructive op succeeds.
///
/// Returned by ``DestructiveOpTier/undoBannerPolicy``. The UI layer
/// (task-window view models in `apps/{macos,windows}/`) translates this
/// into a concrete banner widget; SafetyKit only declares the policy.
public enum UndoBannerPolicy: Sendable, Equatable, Hashable {
    /// No banner is shown at all. Used for ``DestructiveOpTier/low``,
    /// where no snapshot was taken and there's nothing to undo via the
    /// SafetyKit surface.
    case none

    /// Banner auto-dismisses after the given duration. Used for
    /// ``DestructiveOpTier/medium`` (24 hours per ADR 0033).
    case autoDismiss(after: Duration)

    /// Banner stays visible until the user explicitly dismisses it.
    /// Used for ``DestructiveOpTier/high`` (force-push and friends).
    case persistent
}
