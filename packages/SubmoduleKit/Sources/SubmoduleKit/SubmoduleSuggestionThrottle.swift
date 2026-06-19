// SubmoduleSuggestionThrottle — per-repo last-shown timestamp store for
// ADR 0096's throttled submodule-update suggestion.
//
// Tier 1 portable. Pure Foundation; spawns git via `GitCore.Runner`
// only to resolve the git-common-dir.
//
// The freshness heuristic (``SubmoduleFreshness/shouldSuggestUpdate``)
// can be true on every status refresh, but we must not nag. ADR 0096
// throttles the suggestion to at most once per
// `submoduleSuggestionThrottleHours` (default 4) per repo. The state is
// a single timestamp persisted in a small file under the git dir, so it
// survives process restarts and is naturally per-repo (and shared
// across linked worktrees, since it lives in the COMMON dir).
//
// Path: `<git-common-dir>/sprig/submodule-suggestion-shown`. We resolve
// the common dir with `git rev-parse --path-format=absolute
// --git-common-dir` so linked worktrees all read/write the one shared
// file rather than per-worktree copies. The file's contents are a
// single line: the last-shown instant as integer Unix epoch seconds
// (UTC by construction, no timezone or formatter to disagree across
// platforms, trivially parseable). A missing or unparseable file means
// "never shown" → not throttled.

import Foundation
import GitCore

/// Per-repo throttle for the submodule-update suggestion.
public struct SubmoduleSuggestionThrottle: Sendable {
    /// File name under `<git-common-dir>/sprig/`.
    public static let fileName = "submodule-suggestion-shown"
    /// Subdirectory under the git-common-dir that holds Sprig's
    /// per-repo state files.
    public static let stateSubdirectory = "sprig"

    /// Runner for the repo whose suggestion is being throttled.
    public let runner: Runner

    /// Clock injection (tests pass scripted clocks; production uses
    /// `Date()`).
    public let clock: @Sendable () -> Date

    /// `{ Date() }` hoisted once so the default parameter doesn't trip
    /// Swift 6 strict-concurrency checking.
    public static let defaultClock: @Sendable () -> Date = { Date() }

    public init(
        runner: Runner,
        clock: @Sendable @escaping () -> Date = SubmoduleSuggestionThrottle.defaultClock
    ) {
        self.runner = runner
        self.clock = clock
    }

    /// Whether the suggestion may be shown now, given the throttle
    /// window. `true` when the suggestion has never been shown, or when
    /// at least `throttleHours` have elapsed since it last was.
    ///
    /// - Parameter throttleHours: the window from
    ///   `AppPreferences.submoduleSuggestionThrottleHours` (default 4).
    ///   A value `<= 0` disables throttling (always returns `true`).
    public func mayShow(throttleHours: Int) async throws -> Bool {
        guard throttleHours > 0 else { return true }
        guard let lastShown = try await lastShownTimestamp() else { return true }
        let elapsed = clock().timeIntervalSince(lastShown)
        return elapsed >= Double(throttleHours) * 3600
    }

    /// Record that the suggestion was shown now, resetting the window.
    /// Creates `<git-common-dir>/sprig/` if needed.
    public func recordShown() async throws {
        let url = try await storeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let epoch = Int(clock().timeIntervalSince1970.rounded(.down))
        let data = Data("\(epoch)\n".utf8)
        // Direct (non-atomic) write with a short retry. `.atomic`'s
        // temp-file + rename is the pattern Windows transiently rejects
        // with ERROR_SHARING_VIOLATION (an antivirus/indexer briefly
        // holding a handle on a freshly-created `.git` subdir); only the
        // single integer this file holds matters, so atomicity is moot.
        var lastError: Error?
        for attempt in 0 ..< 5 {
            do {
                try data.write(to: url)
                return
            } catch {
                lastError = error
                if attempt < 4 { try? await Task.sleep(nanoseconds: 150_000_000) }
            }
        }
        if let lastError { throw lastError }
    }

    /// The persisted last-shown instant, or `nil` when the file is
    /// missing or its contents don't parse (treated as "never shown").
    public func lastShownTimestamp() async throws -> Date? {
        let url = try await storeURL()
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let epoch = TimeInterval(trimmed) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Resolve `<git-common-dir>/sprig/submodule-suggestion-shown`.
    private func storeURL() async throws -> URL {
        let output = try await runner.run([
            "rev-parse", "--path-format=absolute", "--git-common-dir"
        ])
        let raw = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw GitError.parseFailure(
                context: "`git rev-parse --git-common-dir` returned an empty path",
                rawSnippet: raw
            )
        }
        return URL(fileURLWithPath: raw)
            .appendingPathComponent(Self.stateSubdirectory)
            .appendingPathComponent(Self.fileName)
    }
}
