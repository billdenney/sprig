// CommitComposerViewModel.swift
//
// Fifth concrete TaskWindowKit view model — the portable engine behind
// the macOS/Windows "Commit…" task window, one of the MVP-10 verbs.
// Surfaces the file-granularity staging + commit-message + commit-
// options surface that `git commit` ultimately consumes.
//
// Tier 1, portable. Per ADR 0048, view models live here; the per-OS
// shells in `apps/{macos,windows}/` bind to this VM's
// `staged` / `unstaged` / `untracked`, `message`, `options`, and
// `state`.
//
// What this VM owns:
//   - The latest porcelain-v2 partition (staged / unstaged /
//     untracked / conflicted paths).
//   - The commit message the user is composing (subject + body).
//   - Boolean options the UI surfaces as toggles: amend, sign-off,
//     SSH/GPG sign, allow-empty.
//   - File-granularity stage / unstage operations via
//     `git add <path>` / `git restore --staged <path>`.
//   - The final `git commit` invocation + the new commit SHA on
//     success.
//
// What this VM doesn't own (deliberately):
//   - **Sub-hunk / region staging.** Master plan §13.3-C and ADR 0061
//     flag this as the killer power-user feature; it lands in its
//     own slice once the diff-rendering layer has selection plumbing.
//     For the MVP cut, staging is per-path.
//   - Conventional Commits prompt (master plan 11.5) — separate VM
//     concern that wraps this one.
//   - Co-author picker, signing-key picker — future iterations
//     extend `CommitOptions`.
//   - Hook trust prompts (ADR 0050) — `Runner` invokes git which
//     invokes hooks; the trust surface is a `SafetyKit` concern that
//     gates the invocation upstream of this VM.

import Foundation
import GitCore

/// View model for the Commit task window. Holds the working partition
/// of changes, the in-progress message, the option toggles, and the
/// lifecycle state of the latest stage / unstage / commit call.
///
/// **Actor-isolated.** All mutable state lives behind the actor.
///
/// **Lifecycle.** Construct with the repo URL + Runner. Call
/// ``refresh()`` to populate the staged / unstaged / untracked lists.
/// The UI calls ``stage(_:)`` / ``unstage(_:)`` to move paths between
/// piles, edits ``message`` via ``setMessage(_:)``, flips toggles via
/// ``setOptions(_:)``, then runs ``commit()``. Success exposes the
/// new commit SHA via `state.successValue`.
public actor CommitComposerViewModel {
    /// The repo this VM operates on. Surfaced for diagnostics.
    public let repoURL: URL

    /// Paths with staged (index) changes — the commit's payload.
    /// Renamed entries appear under their new path.
    public private(set) var staged: [String] = []

    /// Paths with unstaged (worktree) changes. Subset / overlap with
    /// `staged` is possible (the "MM" xy code → both lists).
    public private(set) var unstaged: [String] = []

    /// Paths git considers untracked. Editable into `staged` via
    /// ``stage(_:)`` (which runs `git add <path>`).
    public private(set) var untracked: [String] = []

    /// Paths git considers in-conflict (porcelain-v2 unmerged
    /// entries). The UI surfaces a "resolve conflicts first" banner
    /// when this isn't empty; ``commit()`` rejects the call in that
    /// case.
    public private(set) var conflicted: [String] = []

    /// The current message draft.
    public private(set) var message: CommitMessage

    /// The current toggle state.
    public private(set) var options: CommitOptions

    /// State of the latest stage / unstage / commit call. Success
    /// payload is the new commit SHA when ``commit()`` completes;
    /// for stage / unstage / refresh ops the success payload is the
    /// SHA `HEAD` already pointed at, so the UI has a stable handle.
    public private(set) var state: TaskWindowState<String> = .idle

    /// ADR 0070 guard rails, repopulated by every ``refresh()``:
    /// committing-to-default-branch, detached HEAD, large staged file
    /// without LFS. Warnings only — ``commit()`` never blocks on
    /// them; the UI renders banners with one-click remedies.
    public private(set) var preflightWarnings: [PreflightWarning] = []

    /// `Runner` configured against ``repoURL``. Injected for tests.
    private let runner: Runner

    /// Guard-rail evaluator. Injected so tests can shrink the
    /// large-file threshold instead of staging 50 MiB fixtures.
    private let preflight: PreflightChecks

    /// Staged paths whose index status is `A` (newly added) — feeds
    /// ADR 0074's Add-vs-Update suggestion wording. Repopulated by
    /// every ``refresh()``.
    private var stagedAdded: Set<String> = []

    /// In-flight Task, retained so ``cancel`` can interrupt it.
    private var runningTask: Task<Void, Never>?

    public init(
        repoURL: URL,
        runner: Runner,
        message: CommitMessage = CommitMessage(),
        options: CommitOptions = CommitOptions(),
        preflight: PreflightChecks = PreflightChecks()
    ) {
        self.repoURL = repoURL
        self.runner = runner
        self.message = message
        self.options = options
        self.preflight = preflight
    }

    // MARK: - Form updates

    public func setMessage(_ newMessage: CommitMessage) {
        message = newMessage
    }

    /// ADR 0074: fill ``message`` with the deterministic suggestion —
    /// the repo's `commit.template` when configured, otherwise a
    /// subject synthesized from the staged paths ("Update README.md",
    /// "Add docs (3 files)").
    ///
    /// Never clobbers user input: a no-op (returning false) when the
    /// current subject or body is non-empty, or when there's nothing
    /// to suggest from. The UI calls this on open / after staging
    /// changes; an explicit "suggest" button can call it after
    /// ``setMessage(_:)`` cleared the draft.
    @discardableResult
    public func suggestMessage() async -> Bool {
        guard message.subject.isEmpty, message.body.isEmpty else { return false }
        guard let suggestion = await CommitMessageSuggestion.suggest(
            stagedPaths: staged,
            newPaths: stagedAdded,
            runner: runner,
            repoURL: repoURL
        ) else { return false }
        message = suggestion
        return true
    }

    public func setOptions(_ newOptions: CommitOptions) {
        options = newOptions
    }

    // MARK: - Staging

    /// Re-read the working tree partition via
    /// `git status --porcelain=v2 -z`. The four path lists
    /// (staged / unstaged / untracked / conflicted) get repopulated.
    /// Failures land in ``state`` as `.failure` and leave the prior
    /// partition empty so the UI doesn't show stale data.
    public func refresh() async {
        do {
            let output = try await runner.run([
                "status",
                "--porcelain=v2",
                "-z",
                "--branch", // headers feed the ADR 0070 branch rails
                "--untracked-files=all"
            ])
            let parsed = try PorcelainV2Parser.parse(output.stdout)
            applyPartition(parsed)

            // ADR 0070 guard rails. Branch checks are pure reads of
            // the status we just parsed; the large-file check stats
            // the staged paths and only spawns `git check-attr` for
            // the over-threshold subset (usually none).
            var warnings = preflight.branchWarnings(from: parsed.branch)
            warnings += await preflight.largeStagedFileWarnings(
                stagedPaths: staged,
                repoURL: repoURL,
                runner: runner
            )
            warnings += await preflight.binaryTypeWarnings(
                stagedPaths: staged,
                repoURL: repoURL,
                runner: runner
            )
            warnings += await preflight.stagedSecretWarnings(
                stagedPaths: staged,
                repoURL: repoURL,
                runner: runner
            )
            preflightWarnings = warnings
        } catch {
            staged = []
            unstaged = []
            untracked = []
            conflicted = []
            preflightWarnings = []
            state = .failure(.init(from: error))
        }
    }

    /// Run `git add <path>`. Repopulates the partition on success.
    public func stage(_ path: String) async {
        await runGitMutation(["add", path])
    }

    /// Run `git restore --staged <path>` — unstage without
    /// discarding the worktree change.
    public func unstage(_ path: String) async {
        await runGitMutation(["restore", "--staged", path])
    }

    // MARK: - Commit

    /// Run `git commit` with the current message + options. Updates
    /// ``state`` with the new commit SHA on success.
    ///
    /// Pre-flights:
    ///   - rejects when ``message`` fails validation (no spawn)
    ///   - rejects when ``conflicted`` is non-empty (no spawn) —
    ///     "resolve conflicts before committing"
    ///   - rejects when ``staged`` is empty and the user didn't
    ///     opt into `--amend` or `--allow-empty`
    public func commit() async {
        if case .busy = state { return }

        if !conflicted.isEmpty {
            state = .failure(.init(
                description: TaskWindowVocabulary.resolveConflictedFirst(count: conflicted.count)
            ))
            return
        }

        if let validationError = message.validationError {
            state = .failure(.init(description: validationError))
            return
        }

        if staged.isEmpty, !options.amend, !options.allowEmpty {
            state = .failure(.init(description: TaskWindowVocabulary.nothingToCommit))
            return
        }

        state = .busy(progress: nil)
        let argv = gitCommitArguments()
        let runner = self.runner

        runningTask = Task { [weak self] in
            do {
                _ = try await runner.run(argv)
                let sha = try await runner.run(["rev-parse", "HEAD"]).stdoutString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await self?.recordCommitSuccess(sha)
            } catch is CancellationError {
                await self?.recordFailure(.init(description: TaskWindowVocabulary.cancelled("Commit")))
            } catch {
                await self?.recordFailure(.init(from: error))
            }
        }

        await runningTask?.value
    }

    /// Cancel the in-flight op, if any.
    public func cancel() {
        runningTask?.cancel()
    }

    /// Reset state to `.idle`. Preserves partition + message + options.
    public func reset() {
        runningTask?.cancel()
        runningTask = nil
        state = .idle
    }

    // MARK: - Internal argv builder

    /// Build the argv `git commit` should be invoked with for the
    /// current message + options. Exposed `internal` so tests can
    /// verify the argv without spawning git.
    func gitCommitArguments() -> [String] {
        var args = ["commit"]
        if options.amend { args.append("--amend") }
        if options.signOff { args.append("-s") }
        if options.sign { args.append("-S") }
        if options.allowEmpty { args.append("--allow-empty") }
        args.append(contentsOf: ["-m", message.subject])
        let trimmedBody = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            args.append(contentsOf: ["-m", trimmedBody])
        }
        return args
    }

    // MARK: - Private helpers

    private func runGitMutation(_ argv: [String]) async {
        do {
            _ = try await runner.run(argv)
            await refresh()
        } catch {
            state = .failure(.init(from: error))
        }
    }

    // Entry classification lives in the shared
    // `WorkingTreeClassifier` so the Status window's counts can never
    // disagree with this composer's partition.

    private func applyPartition(_ status: PorcelainV2Status) {
        var staged: [String] = []
        var unstaged: [String] = []
        var untracked: [String] = []
        var conflicted: [String] = []
        var added: Set<String> = []
        for entry in status.entries {
            let buckets = WorkingTreeClassifier.classify(entry)
            if let path = buckets.staged { staged.append(path) }
            if let path = buckets.unstaged { unstaged.append(path) }
            if let path = buckets.untracked { untracked.append(path) }
            if let path = buckets.conflicted { conflicted.append(path) }
            // Track staged-as-new for ADR 0074's Add-vs-Update wording.
            if case let .ordinary(ord) = entry, ord.xy.index == .added {
                added.insert(ord.path)
            }
        }
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        stagedAdded = added
        if let oid = status.branch?.oid {
            state = .success(oid)
        } else {
            state = .idle
        }
    }

    private func recordCommitSuccess(_ sha: String) async {
        runningTask = nil
        // Re-read the partition so the UI reflects the post-commit state.
        await refresh()
        state = .success(sha)
    }

    private func recordFailure(_ failure: TaskWindowState<String>.Failure) {
        runningTask = nil
        state = .failure(failure)
    }
}
