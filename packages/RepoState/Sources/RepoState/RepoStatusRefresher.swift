// RepoStatusRefresher.swift
//
// Tier 1 portable helper that bridges `GitCore.Runner` output into
// `RepoStateStore.apply(_:)`. The "M2 agent main loop" minus the
// IPC half: given a watcher event, the agent calls `refresh()` and
// the store gets the latest porcelain-v2 snapshot.
//
// Composes everything we've shipped so far:
//
// - `GitCore.Runner` — spawns `git status` race-safely
//   (ProcessTerminationGate fixes the macOS waitUntilExit deadlock)
// - `GitCore.PorcelainV2Parser` — parses `--porcelain=v2 -z`
// - `GitCore.GitMetadataPaths` — resolves the actual `.git` dir
//   (handles submodule + linked-worktree pointer files) and detects
//   "git op in flight" so we defer mid-mutation refreshes (ADR 0056)
// - `RepoStateStore.apply(_:)` — whole-snapshot replace into the
//   path-trie + branch info
//
// Stays Tier 1 — no platform APIs, no `WatcherKit` dep. The Tier-2
// integration that wires this to a watcher's tick stream lands when
// the M2 agent code is built.

import Foundation
import GitCore

/// Outcome of a single ``RepoStatusRefresher/refresh()`` call.
public enum RefreshOutcome: Sendable {
    /// Snapshot applied to the store. `entryCount` is the trie size
    /// after apply — useful for diagnostics ("did the badge set
    /// shrink as expected?").
    case applied(entryCount: Int)

    /// Refresh deferred because some git agent is mid-mutation.
    /// Caller should retry on the next tick. See
    /// ``DeferralReason`` for the specific signal.
    case deferred(reason: DeferralReason)

    /// `git status` (or the parser) failed. The caller can log and
    /// retry on the next tick; persistent failures usually mean the
    /// worktree was deleted or git itself broke.
    case failed(any Error)

    /// What caused a refresh to defer.
    public enum DeferralReason: Sendable, Equatable {
        /// A `*.lock` file exists in a critical location inside
        /// `.git/` (index.lock, HEAD.lock, packed-refs.lock,
        /// config.lock, shallow.lock). See ADR 0056 §"Defer status
        /// refreshes while a git operation is in flight."
        case gitOperationInFlight
    }
}

/// Bridges a porcelain-v2 `git status` invocation into a
/// ``RepoStateStore`` apply.
///
/// One refresher per watched repo. The agent's tick loop (or a
/// scheduled timer, or an IPC-triggered "force refresh") calls
/// ``refresh()`` and gets a ``RefreshOutcome`` it can log / count /
/// retry on. Stateless apart from the captured store + runner.
///
/// **Multi-agent awareness (ADR 0056 + R15 audit).** Before
/// invoking git, this checks ``GitMetadataPaths/gitOperationInFlight(in:gitVersion:)``
/// against the resolved git directory. If true, the refresh is
/// deferred — querying status mid-mutation observes inconsistent
/// state. Typical lock duration is <100 ms; the caller retries on
/// the next tick.
public struct RepoStatusRefresher: Sendable {
    private let store: RepoStateStore
    private let runner: Runner
    private let resolvedGitDir: URL?

    /// - Parameters:
    ///   - store: the per-repo store to populate. The refresher
    ///     calls only `repoRoot` (nonisolated) and `apply(_:)` on it.
    ///   - runner: optional explicit `Runner`. When nil, the
    ///     refresher constructs one with `defaultWorkingDirectory`
    ///     set to the store's `repoRoot`.
    public init(store: RepoStateStore, runner: Runner? = nil) {
        self.store = store
        self.runner = runner ?? Runner(defaultWorkingDirectory: store.repoRoot)
        // Resolve once at init. Future `.git`-pointer changes
        // (e.g. submodule re-init via `git submodule add`) require
        // a fresh refresher; documented in the API doc.
        resolvedGitDir = try? GitMetadataPaths.resolveGitDir(forWorktree: store.repoRoot)
    }

    /// Refresh the store from a single `git status --porcelain=v2 -z`
    /// invocation. Returns ``RefreshOutcome``; never throws.
    public func refresh() async -> RefreshOutcome {
        // Defer when external (or our own) git op is mid-mutation.
        if let gitDir = resolvedGitDir, GitMetadataPaths.gitOperationInFlight(in: gitDir) {
            return .deferred(reason: .gitOperationInFlight)
        }

        do {
            let output = try await runner.run([
                "status",
                "--porcelain=v2",
                "--branch",
                "--show-stash",
                "-z",
                "--untracked-files=all"
            ])
            let status = try PorcelainV2Parser.parse(output.stdout)
            await store.apply(status)
            return await .applied(entryCount: store.entryCount())
        } catch {
            return .failed(error)
        }
    }
}
