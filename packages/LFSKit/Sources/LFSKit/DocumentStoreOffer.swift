// DocumentStoreOffer.swift
//
// ADR 0091 (part B) — the provider-neutral offer surface + the
// one-time-per-repo flag store behind the document-store heuristic.
//
// The OFFER (`DocumentStoreOffer`) is the value the UI consumes: it
// pairs the heuristic's recommendation with the ready-to-run LFS
// patterns. Where it would surface: a status rail in the Status task
// window — `TaskWindowKit.StatusViewModel` (Tier 1 view model) would
// expose an optional `documentStoreOffer` the macOS shell renders as a
// one-time banner ("This looks like a document store — set up LFS
// tracking for common binary types?") with a "Set up LFS" button (wired
// to `LFSTrack.track` over each `suggestedPattern`) and a "Not now"
// dismiss. Wiring that view model is a FOLLOW-UP; this slice is the
// engine that produces the offer and remembers we've made it.
//
// The FLAG (`DocumentStoreOfferFlag`) is the once-per-repo memory. It is
// a small file under the git COMMON dir — deliberately NOT a ref:
//   - A ref under `refs/sprig/…` would be fetched/pushed and shared with
//     collaborators; "have we offered LFS on THIS clone" is local state.
//   - The common dir (resolved via
//     `git rev-parse --path-format=absolute --git-common-dir`) is shared
//     across linked worktrees and is repo-global, so the offer fires
//     once per repository, not once per worktree.
//
// Tier 1, portable. Git invocation routes through `GitCore.Runner`; the
// flag write/read is plain Foundation file I/O under the resolved dir.

import Foundation
import GitCore

/// The provider-neutral document-store LFS offer the UI consumes.
///
/// Built from a ``DocumentStoreRecommendation`` whose ``DocumentStoreRecommendation/shouldOffer``
/// is true. Carries the human-facing counts and the exact `*.ext`
/// patterns the "Set up LFS" remedy tracks. `Equatable`/`Sendable` so it
/// crosses the IPC boundary as a plain `Codable`-able value.
public struct DocumentStoreOffer: Equatable, Sendable {
    /// The `*.ext` patterns to track with LFS on consent, dominant-first.
    public let patternsToTrack: [String]

    /// Tracked-file count the verdict was computed over (for the banner).
    public let trackedFileCount: Int

    /// Curated-binary file count (for the "N of M are binaries" copy).
    public let binaryFileCount: Int

    public init(patternsToTrack: [String], trackedFileCount: Int, binaryFileCount: Int) {
        self.patternsToTrack = patternsToTrack
        self.trackedFileCount = trackedFileCount
        self.binaryFileCount = binaryFileCount
    }

    /// Build an offer from a recommendation, or nil when the
    /// recommendation says not to offer. The caller still gates on
    /// ``DocumentStoreOfferFlag/hasOffered(runner:cwd:)`` for the
    /// once-per-repo rule — a true recommendation that's already been
    /// offered yields no banner.
    public init?(recommendation: DocumentStoreRecommendation) {
        guard recommendation.shouldOffer else { return nil }
        self.init(
            patternsToTrack: recommendation.suggestedPatterns,
            trackedFileCount: recommendation.trackedFileCount,
            binaryFileCount: recommendation.binaryFileCount
        )
    }
}

/// The one-time-per-repo flag: "have we already made the document-store
/// LFS offer for this repository?"
///
/// Stored as a marker file under the git common dir. Reads and writes go
/// through ``GitCore/Runner`` only to RESOLVE the dir (so the path is
/// worktree-safe and repo-global); the marker itself is plain file I/O.
public enum DocumentStoreOfferFlag {
    /// The marker file's name under `<common-dir>/sprig/`. Namespaced
    /// under `sprig/` so Sprig's per-repo local state stays grouped and
    /// never collides with git's own files.
    static let markerRelativePath = "sprig/document-store-offer-made"

    /// Resolve the absolute git common dir for `cwd`'s repo.
    ///
    /// `--path-format=absolute` so the result is a usable filesystem path
    /// regardless of cwd; `--git-common-dir` (not `--git-dir`) so linked
    /// worktrees all resolve to the SAME shared dir — the offer is
    /// per-repo, not per-worktree.
    static func commonDir(runner: Runner, cwd: URL? = nil) async throws -> URL {
        let output = try await runner.run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd: cwd
        )
        // One path on stdout. Trim the trailing newline only (a path can
        // legitimately contain spaces, so trim newlines, not whitespace).
        let raw = output.stdoutString.trimmingCharacters(in: .newlines)
        guard !raw.isEmpty else {
            throw GitError.parseFailure(
                context: "git rev-parse --git-common-dir",
                rawSnippet: output.stdoutString
            )
        }
        return URL(fileURLWithPath: raw).standardized
    }

    /// The absolute marker-file URL for `cwd`'s repo.
    static func markerURL(runner: Runner, cwd: URL? = nil) async throws -> URL {
        let dir = try await commonDir(runner: runner, cwd: cwd)
        return dir.appendingPathComponent(markerRelativePath)
    }

    /// True iff the document-store offer has already been recorded for
    /// this repo (i.e. the marker file exists). Best-effort: a resolve
    /// failure propagates as a `GitError`, but a present-or-absent marker
    /// is a pure file-existence check.
    public static func hasOffered(runner: Runner, cwd: URL? = nil) async throws -> Bool {
        let marker = try await markerURL(runner: runner, cwd: cwd)
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// Record that the offer has been made, so it stays suppressed.
    /// Idempotent — writing twice leaves the same single marker. Creates
    /// the `sprig/` subdir if needed.
    public static func recordOffered(runner: Runner, cwd: URL? = nil) async throws {
        let marker = try await markerURL(runner: runner, cwd: cwd)
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Tiny, human-readable content (a timestamp) so a curious user
        // who finds the file under .git/sprig/ understands what it is.
        // Content is not parsed back — only the file's existence matters,
        // so a direct (non-atomic) write is enough. We deliberately avoid
        // `.atomic`: its temp-file + rename is the pattern Windows
        // transiently rejects with ERROR_SHARING_VIOLATION (an antivirus
        // or indexer briefly holding a handle on a freshly-created `.git`
        // subdir). The short retry rides out such a transient handle.
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("document-store LFS offer made: \(stamp)\n".utf8)
        var lastError: Error?
        for attempt in 0 ..< 5 {
            do {
                try data.write(to: marker)
                return
            } catch {
                lastError = error
                if attempt < 4 { try? await Task.sleep(nanoseconds: 150_000_000) }
            }
        }
        if let lastError { throw lastError }
    }
}
