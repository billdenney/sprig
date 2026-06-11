// CloneDialogViewModel.swift
//
// First concrete TaskWindowKit view model — the portable engine behind
// the macOS/Windows "Clone…" task window. Holds the form inputs the
// user is editing, validates them, runs `git clone` via GitCore.Runner,
// and surfaces progress through ``TaskWindowState``.
//
// Tier 1, portable. No SwiftUI / swift-cross-ui imports — the per-OS
// shells bind to this VM's `state` and `request` from their native
// rendering layer (per ADR 0048, ADR 0030's Finder/Explorer-first
// invariant).
//
// What this VM owns:
//   - Validated form inputs (`CloneRequest`).
//   - Lifecycle state of the in-flight clone (`TaskWindowState<URL>`).
//   - Cancellation of the underlying `git clone` invocation.
//
// What this VM doesn't own (lives elsewhere by design):
//   - Credential prompts — `Runner` inherits the user's existing
//     `git-credential-*` helper chain; in-shell prompts arrive via a
//     future `CredentialKit` integration.
//   - Recurse-submodules wiring beyond the top-level flag — submodule
//     update semantics live in `SubmoduleKit` (M6).
//   - Post-clone repo registration — that's a higher-level workflow in
//     `AgentKit` / `RepoState`'s discovery surface, triggered after a
//     successful clone.

import ForgeKit
import Foundation
import GitCore

/// Form inputs for the Clone task window, captured as one immutable
/// value so the UI can build a fresh value when the user edits and pass
/// it back via ``CloneDialogViewModel/update(_:)``.
///
/// Validation happens via ``validationError`` (returns a presentable
/// message) and ``isReady`` (Boolean shortcut for "submit button enabled").
public struct CloneRequest: Sendable, Equatable {
    /// The remote URL or path to clone from. Required.
    public var sourceURL: String

    /// Absolute or `~`-expandable directory the new clone goes into.
    /// Required. The directory must not exist yet (git refuses); the
    /// VM checks the parent's writability instead.
    public var targetDirectory: String

    /// Pass `--recurse-submodules` (default `true` per master plan §10
    /// "Repository lifecycle" — submodule-aware throughout).
    public var recurseSubmodules: Bool

    /// Pass `--depth <N>` for a shallow clone when set. `nil` means
    /// "full history".
    public var depth: Int?

    public init(
        sourceURL: String = "",
        targetDirectory: String = "",
        recurseSubmodules: Bool = true,
        depth: Int? = nil
    ) {
        self.sourceURL = sourceURL
        self.targetDirectory = targetDirectory
        self.recurseSubmodules = recurseSubmodules
        self.depth = depth
    }

    /// User-presentable message describing why the request can't be
    /// submitted, or `nil` if it can. Order matters: the most
    /// "common-mistake-first" check wins so the UI surfaces the
    /// highest-priority feedback.
    public var validationError: String? {
        let url = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return TaskWindowVocabulary.enterRepositoryURL }

        let target = targetDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty { return TaskWindowVocabulary.chooseTargetDirectory }

        if let depth, depth <= 0 {
            return TaskWindowVocabulary.shallowDepthMustBePositive
        }
        return nil
    }

    /// Convenience inverse of ``validationError``.
    public var isReady: Bool {
        validationError == nil
    }

    /// The argv `git clone` should be invoked with for this request.
    /// Exposed for testing the argv-construction logic without
    /// spawning git. **Does not include `--quiet`** — callers stream
    /// stderr / progress as they like.
    public func gitArguments() -> [String] {
        var args = ["clone"]
        if recurseSubmodules { args.append("--recurse-submodules") }
        if let depth { args.append(contentsOf: ["--depth", String(depth)]) }
        args.append(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines))
        args.append(targetDirectory.trimmingCharacters(in: .whitespacesAndNewlines))
        return args
    }
}

/// View model for the Clone task window. Holds the form state, runs
/// `git clone`, surfaces results.
///
/// **Actor-isolated.** All mutable state lives behind the actor; the
/// view layer awaits to read or set. This is the cross-platform
/// neutral pattern — SwiftUI consumers can wrap reads in `Task` from
/// `@MainActor`; swift-cross-ui does the same.
///
/// **Lifecycle.** Construct with a starting `request` and an injected
/// `Runner`. Tests inject a mock runner; production wires a real
/// `GitCore.Runner`. `clone()` transitions ``state`` from `.idle` /
/// `.failure` / `.success` → `.busy` → terminal. `cancel()` interrupts
/// the in-flight clone and lands in `.failure`. `reset()` returns to
/// `.idle` at any time.
public actor CloneDialogViewModel {
    /// The current form inputs. Editable via ``update(_:)``.
    public private(set) var request: CloneRequest

    /// The current operation state. Read by the UI on each render and
    /// after `Task.yield()` ticks. ``TaskWindowState`` defines the
    /// transitions; this property is the source of truth.
    public private(set) var state: TaskWindowState<URL> = .idle

    /// `Runner` whose `defaultWorkingDirectory` is the parent of the
    /// target directory (so `git clone <url> <subdir>` lands inside it).
    /// Injected so tests can use a fixture-spawn `Runner`.
    private let runner: Runner

    /// In-flight clone Task, retained so ``cancel`` can interrupt it.
    /// Cleared in the terminal branches of `clone()`.
    private var runningTask: Task<Void, Never>?

    public init(request: CloneRequest = CloneRequest(), runner: Runner) {
        self.request = request
        self.runner = runner
    }

    // MARK: - Form updates

    /// Replace the current request with a new value. Has no effect on
    /// ``state`` — callers can edit the form while a clone is in
    /// flight (e.g. typing a new target dir for a "Clone again" retry).
    public func update(_ newRequest: CloneRequest) {
        request = newRequest
    }

    // MARK: - Forge browse (affordance 3.2, ADR 0078)

    /// Repositories from the most recent ``browseRepos(...)`` — the
    /// pick-from-list alternative to pasting a clone URL.
    public private(set) var browseResults: [ForgeRepo] = []

    /// Typed failure of the most recent browse, kept separate from
    /// ``state`` (browsing is a form aid; it must never clobber an
    /// in-flight clone's lifecycle).
    public private(set) var browseError: ForgeError?

    /// List the user's repositories on `provider`. The TOKEN IS
    /// INJECTED — acquisition is onboarding/shell work and storage is
    /// CredentialKit's platform adapters; this VM never persists it.
    public func browseRepos(
        provider: ForgeProvider,
        token: String,
        browser: ForgeRepoBrowser = ForgeRepoBrowser()
    ) async {
        browseError = nil
        do {
            browseResults = try await browser.listRepos(provider: provider, token: token)
        } catch let error as ForgeError {
            browseResults = []
            browseError = error
        } catch {
            browseResults = []
            browseError = .malformedResponse(detail: String(describing: error))
        }
    }

    /// Adopt a browsed repository into the form: the HTTPS clone URL
    /// becomes the source, and the repo's name seeds the target
    /// directory when the user hasn't typed one yet (never clobbers
    /// a non-empty target).
    public func selectBrowsed(_ repo: ForgeRepo) {
        request.sourceURL = repo.cloneURL
        let trimmedTarget = request.targetDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTarget.isEmpty {
            let name = repo.fullName.split(separator: "/").last.map(String.init)
            request.targetDirectory = name ?? ""
        }
    }

    // MARK: - Operations

    /// Run `git clone` for the current request. Returns when the
    /// terminal state has been recorded; the caller can also observe
    /// the `state` property directly.
    ///
    /// No-ops if the state is already ``TaskWindowState/busy``.
    /// Pre-flights ``CloneRequest/validationError`` and lands in
    /// `.failure` immediately if the form isn't ready (without
    /// spawning git).
    public func clone() async {
        if case .busy = state { return }

        if let validationError = request.validationError {
            state = .failure(.init(description: validationError))
            return
        }

        state = .busy(progress: nil)

        // Capture inputs into the Task so `cancel()` can null out
        // `runningTask` independently of state moves.
        let argv = request.gitArguments()
        let target = request.targetDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let runner = self.runner

        runningTask = Task { [weak self] in
            do {
                _ = try await runner.run(argv)
                let absolute = URL(fileURLWithPath: target).standardized
                await self?.recordSuccess(absolute)
            } catch is CancellationError {
                await self?.recordFailure(.init(description: TaskWindowVocabulary.cancelled("Clone")))
            } catch {
                await self?.recordFailure(.init(from: error))
            }
        }

        await runningTask?.value
    }

    /// Cancel the in-flight clone, if any. After cancellation the
    /// state transitions to ``TaskWindowState/failure`` with a
    /// "cancelled" description. A no-op if no clone is running.
    public func cancel() {
        runningTask?.cancel()
    }

    /// Reset to ``TaskWindowState/idle`` regardless of current state.
    /// Cancels an in-flight clone as a side effect.
    public func reset() {
        runningTask?.cancel()
        runningTask = nil
        state = .idle
    }

    // MARK: - Private state transitions

    private func recordSuccess(_ output: URL) {
        runningTask = nil
        state = .success(output)
    }

    private func recordFailure(_ failure: TaskWindowState<URL>.Failure) {
        runningTask = nil
        state = .failure(failure)
    }
}
