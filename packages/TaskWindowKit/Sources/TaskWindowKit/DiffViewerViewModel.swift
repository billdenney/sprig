// DiffViewerViewModel.swift
//
// Fourth concrete TaskWindowKit view model — the portable engine
// behind the macOS/Windows "Diff…" task window. Invokes `git diff` or
// `git show` against an injected ``Runner`` and surfaces the raw
// unified-diff bytes via ``TaskWindowState``.
//
// Tier 1, portable. Per ADR 0048, view models live here; the per-OS
// shells in `apps/{macos,windows}/` bind to this VM's `target`,
// `payload`, and `state`.
//
// What this VM owns:
//   - The diff "target" the user is viewing (worktree changes, staged
//     changes, or a single commit's introduced changes).
//   - The raw unified-diff bytes plus a coarse summary (files
//     changed). Structured parsing — per-file, per-hunk, per-line —
//     lives in a future package (likely a new `DiffKit`) once we
//     know what M4 MergeConflictResolver actually needs to consume.
//   - Lifecycle state of the in-flight `git` invocation.
//
// What this VM doesn't own (deliberately):
//   - Arbitrary `<rev>..<rev>` ranges, file-scoped diffs, word-diff,
//     `--remerge-diff` (ADR 0024's noted git 2.36+ feature). All
//     deferred to a future iteration that exposes a typed filter
//     struct similar to `CloneRequest`.
//   - Syntax highlighting / per-hunk staging — UI-shell concerns.
//   - Binary file detection beyond what git's own output marks. The
//     UI renders git's `Binary files differ` line as-is.

import Foundation
import GitCore

/// What to diff. Each case maps to one canonical `git` invocation;
/// adding new cases requires adding the matching argv to
/// ``DiffViewerViewModel/gitArguments(for:)``.
public enum DiffTarget: Sendable, Equatable, Hashable {
    /// Working-tree changes not yet staged (`git diff`).
    case worktreeAgainstIndex

    /// Staged changes not yet committed (`git diff --cached`).
    case indexAgainstHead

    /// The changes a single commit introduced, compared to its first
    /// parent (`git show --format= <sha>`). For root commits — where
    /// no parent exists — git emits the full tree as additions, which
    /// is the right behavior for "what did this commit add".
    case commit(sha: String)
}

/// Payload surfaced when a diff load succeeds. Holds the raw bytes
/// plus enough summary to drive a "showing X files" indicator without
/// the UI parsing the diff itself.
public struct DiffPayload: Sendable, Equatable {
    /// Exact bytes git emitted (UTF-8 when source files are text;
    /// `Binary files differ` markers when they're not). The UI is
    /// responsible for decoding / rendering.
    public let rawDiff: Data

    /// Number of `diff --git ` headers found in the raw bytes — a
    /// reliable proxy for "how many files changed" without a full
    /// unified-diff parser. Returns 0 when ``rawDiff`` is empty
    /// (clean target with no changes).
    public let filesChanged: Int

    public init(rawDiff: Data, filesChanged: Int) {
        self.rawDiff = rawDiff
        self.filesChanged = filesChanged
    }

    /// Convenience: true when no files changed (the target is clean
    /// or — for `.commit` — the SHA points at a no-op commit).
    public var isEmpty: Bool {
        filesChanged == 0
    }
}

/// View model for the Diff task window. Holds the current target and
/// the last-loaded payload.
///
/// **Actor-isolated.** All mutable state lives behind the actor; the
/// view layer awaits to read or write.
///
/// **Lifecycle.** Construct with the repo URL and an injected
/// `Runner`. Set / change the target via the initializer or
/// ``setTarget(_:)``, then trigger ``load()`` to invoke git. The
/// payload survives a subsequent ``setTarget(_:)`` until the next
/// load completes — the UI keeps showing the prior diff while
/// re-fetching, so the user doesn't see a blank pane mid-load.
public actor DiffViewerViewModel {
    /// The repo this VM operates on. Surfaced for diagnostics; the
    /// injected ``Runner`` already has it as its working directory.
    public let repoURL: URL

    /// The diff target currently configured. Default
    /// ``DiffTarget/worktreeAgainstIndex`` so the "show me what's
    /// dirty right now" path is one click.
    public private(set) var target: DiffTarget

    /// The most-recently-loaded payload, or `nil` until the first
    /// successful load.
    public private(set) var payload: DiffPayload?

    /// State of the in-flight or last `git` invocation. Success
    /// payload is the file count — pairs with the UI's "showing X
    /// files" indicator without forcing it to await ``payload``.
    public private(set) var state: TaskWindowState<Int> = .idle

    /// `Runner` configured against ``repoURL``. Injected for tests.
    private let runner: Runner

    /// In-flight load Task, retained so ``cancel`` can interrupt it.
    private var runningTask: Task<Void, Never>?

    public init(
        repoURL: URL,
        runner: Runner,
        target: DiffTarget = .worktreeAgainstIndex
    ) {
        self.repoURL = repoURL
        self.runner = runner
        self.target = target
    }

    // MARK: - Configuration

    /// Change the target without auto-reloading. Caller follows up
    /// with ``load()`` so the UI can stage state-reset events
    /// (selection, scroll position) deliberately.
    public func setTarget(_ newTarget: DiffTarget) {
        target = newTarget
    }

    // MARK: - Operations

    /// Invoke git for the current ``target`` and update
    /// ``payload`` + ``state``. No-ops if state is already
    /// ``TaskWindowState/busy``.
    public func load() async {
        if case .busy = state { return }

        state = .busy(progress: nil)
        let argv = DiffViewerViewModel.gitArguments(for: target)
        let runner = self.runner

        runningTask = Task { [weak self] in
            do {
                let output = try await runner.run(argv)
                let filesChanged = DiffViewerViewModel.countDiffGitHeaders(in: output.stdout)
                let loaded = DiffPayload(rawDiff: output.stdout, filesChanged: filesChanged)
                await self?.recordSuccess(loaded)
            } catch is CancellationError {
                await self?.recordFailure(.init(description: TaskWindowVocabulary.cancelled("Diff load")))
            } catch {
                await self?.recordFailure(.init(from: error))
            }
        }

        await runningTask?.value
    }

    /// Cancel the in-flight load, if any. Leaves the prior payload
    /// intact.
    public func cancel() {
        runningTask?.cancel()
    }

    /// Reset state to ``TaskWindowState/idle`` while preserving the
    /// loaded ``payload`` and current ``target``. Cancels any
    /// in-flight load.
    public func reset() {
        runningTask?.cancel()
        runningTask = nil
        state = .idle
    }

    // MARK: - Private helpers

    /// Build the argv `git` should be invoked with for a given
    /// target. Exposed `internal` so tests can verify argv without
    /// spawning git.
    static func gitArguments(for target: DiffTarget) -> [String] {
        switch target {
        case .worktreeAgainstIndex:
            ["diff"]
        case .indexAgainstHead:
            ["diff", "--cached"]
        case let .commit(sha):
            // `git show --format=` suppresses the commit metadata
            // header so the output is purely the unified diff —
            // exactly what a diff viewer wants. `git diff <sha>^!`
            // is an alternative but doesn't handle root commits (no
            // parent), where `git show` does.
            ["show", "--format=", sha]
        }
    }

    /// Count `diff --git ` headers in a raw-bytes diff. Each header
    /// starts a new file in unified-diff output. Counted bytewise so
    /// non-UTF-8 file content doesn't break the calculation.
    static func countDiffGitHeaders(in data: Data) -> Int {
        let marker: [UInt8] = Array("diff --git ".utf8)
        guard !marker.isEmpty, data.count >= marker.count else { return 0 }
        var count = 0
        var index = data.startIndex
        let lastSearchStart = data.endIndex - marker.count
        while index <= lastSearchStart {
            // Header must start at beginning-of-data OR right after a
            // newline. Otherwise `diff --git ` substrings inside a
            // commit-message line that happens to mention them would
            // count.
            let atStart = index == data.startIndex
            let prevIsNewline = !atStart && data[data.index(before: index)] == 0x0A
            if atStart || prevIsNewline {
                var matches = true
                for offset in 0 ..< marker.count where data[data.index(index, offsetBy: offset)] != marker[offset] {
                    matches = false
                    break
                }
                if matches {
                    count += 1
                    index = data.index(index, offsetBy: marker.count)
                    continue
                }
            }
            index = data.index(after: index)
        }
        return count
    }

    private func recordSuccess(_ loaded: DiffPayload) {
        runningTask = nil
        payload = loaded
        state = .success(loaded.filesChanged)
    }

    private func recordFailure(_ failure: TaskWindowState<Int>.Failure) {
        runningTask = nil
        state = .failure(failure)
    }
}
