// LogBrowserViewModel.swift
//
// Third concrete TaskWindowKit view model — the portable engine behind
// the macOS/Windows "Show Log…" task window. Reads commits via
// `GitCore.LogParser`, paginates with `--skip` + `--max-count`, and
// surfaces results through ``TaskWindowState``.
//
// Tier 1, portable. Per ADR 0048, view models live here; the per-OS
// shells in `apps/{macos,windows}/` bind to this VM's `commits`,
// `hasMore`, and `state`.
//
// What this VM owns:
//   - Revspec the log is showing (default `HEAD`; can switch to a
//     branch name, range, single SHA, etc.).
//   - Loaded commit pages (accumulating `[Commit]`).
//   - Lifecycle state of the in-flight git invocation.
//
// What this VM doesn't own (lives elsewhere by design):
//   - Graph / topology drawing — that's UI-shell concern (SwiftUI
//     CanvasRenderer / swift-cross-ui equivalent).
//   - Search / filter — implemented via the revspec for now (`-S`,
//     `--grep`, `--author` etc. live in a future iteration that
//     exposes a typed filter struct similar to `CloneRequest`).
//   - Per-commit diff loading — that's `DiffViewerViewModel`.

import Foundation
import GitCore

/// View model for the Show Log task window. Pages a commit history
/// into memory and surfaces it to the UI.
///
/// **Actor-isolated.** All mutable state lives behind the actor; the
/// view layer awaits to read.
///
/// **Lifecycle.** Construct with the repo URL, an injected `Runner`,
/// and optional `revSpec` / `pageSize`. The first read goes through
/// ``loadInitial()`` (which also resets cached commits + paging
/// state). ``loadMore()`` appends the next page; ``hasMore`` reports
/// whether another page is expected. Any failure leaves the
/// previously-loaded commits intact — the UI doesn't lose data on a
/// flaky load.
public actor LogBrowserViewModel {
    /// The repo this VM operates on. Injected `Runner`'s working
    /// directory already points here; surfaced for diagnostics.
    public let repoURL: URL

    /// The revspec to log — anything `git log` accepts (`HEAD`,
    /// `main`, `feature/x`, `origin/main..HEAD`, a SHA, …). Default
    /// `HEAD`. Change via ``setRevSpec(_:)``; subsequent
    /// ``loadInitial()`` or ``loadMore()`` calls use the new value.
    public private(set) var revSpec: String

    /// How many commits to load per page. Tunable via
    /// ``setPageSize(_:)`` between loads. Default 50 — reasonable for
    /// human-scrollable history without blowing memory at 100k-commit
    /// scale.
    public private(set) var pageSize: Int

    /// All commits loaded so far, in the order `git log` returned
    /// them (most-recent first by default — see `branch.sort` and
    /// `--reverse`).
    public private(set) var commits: [Commit] = []

    /// True while the VM expects more commits behind the last loaded
    /// page. Goes false when a load returns fewer commits than
    /// `pageSize` (signaling the end of history).
    public private(set) var hasMore: Bool = true

    /// State of the last `git log` invocation. Success payload is the
    /// total number of commits loaded across all pages so far —
    /// useful for the UI's "showing X commits" indicator.
    public private(set) var state: TaskWindowState<Int> = .idle

    /// `Runner` configured against ``repoURL``. Injected for tests.
    private let runner: Runner

    /// In-flight load Task, retained so ``cancel`` can interrupt it.
    private var runningTask: Task<Void, Never>?

    public init(
        repoURL: URL,
        runner: Runner,
        revSpec: String = "HEAD",
        pageSize: Int = 50
    ) {
        self.repoURL = repoURL
        self.runner = runner
        self.revSpec = revSpec
        self.pageSize = pageSize
    }

    // MARK: - Configuration

    /// Change the revspec the log is showing. Does not auto-reload —
    /// the caller follows up with ``loadInitial()`` so the UI can
    /// reset any scroll position / selection deliberately.
    public func setRevSpec(_ newRevSpec: String) {
        revSpec = newRevSpec
    }

    /// Change the page size. Effective on the next ``loadMore()``
    /// call. No effect on already-loaded commits.
    public func setPageSize(_ newPageSize: Int) {
        pageSize = max(1, newPageSize)
    }

    // MARK: - Operations

    /// Discard cached commits and load the first page from scratch.
    /// Call this on initial open, after ``setRevSpec(_:)``, or as a
    /// "reload now" affordance.
    public func loadInitial() async {
        commits = []
        hasMore = true
        await load(skip: 0)
    }

    /// Append the next page to ``commits``. No-ops if ``hasMore`` is
    /// false or the current state is ``TaskWindowState/busy``.
    public func loadMore() async {
        if case .busy = state { return }
        guard hasMore else { return }
        await load(skip: commits.count)
    }

    /// Cancel the in-flight load, if any. The already-loaded commits
    /// stay; state transitions to ``TaskWindowState/failure``.
    public func cancel() {
        runningTask?.cancel()
    }

    /// Reset to ``TaskWindowState/idle`` while preserving the loaded
    /// commits + revspec. Cancels in-flight load. Useful for
    /// dismissing a ``.failure`` banner without starting over.
    public func reset() {
        runningTask?.cancel()
        runningTask = nil
        state = .idle
    }

    // MARK: - Private load helper

    private func load(skip: Int) async {
        state = .busy(progress: nil)

        let argv = [
            "log",
            "-z",
            "--format=\(LogParser.formatString)",
            "--max-count=\(pageSize)",
            "--skip=\(skip)",
            revSpec
        ]
        let runner = self.runner

        runningTask = Task { [weak self] in
            do {
                let output = try await runner.run(argv)
                let page = try LogParser.parse(output.stdout)
                await self?.recordPage(page)
            } catch is CancellationError {
                await self?.recordFailure(.init(description: TaskWindowVocabulary.cancelled("Log load")))
            } catch {
                await self?.recordFailure(.init(from: error))
            }
        }

        await runningTask?.value
    }

    // MARK: - Private state transitions

    private func recordPage(_ page: [Commit]) {
        runningTask = nil
        commits.append(contentsOf: page)
        // If the page is smaller than pageSize, git emitted everything
        // remaining; mark history as exhausted so subsequent
        // `loadMore()` calls are no-ops.
        if page.count < pageSize { hasMore = false }
        state = .success(commits.count)
    }

    private func recordFailure(_ failure: TaskWindowState<Int>.Failure) {
        runningTask = nil
        state = .failure(failure)
    }
}
