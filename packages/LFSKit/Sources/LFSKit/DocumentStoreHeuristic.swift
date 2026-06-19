// DocumentStoreHeuristic.swift
//
// ADR 0091 (part B) — the one-time, repo-level "this looks like a
// document store — set up LFS?" offer. Where the per-file
// `binaryTypeWithoutLFS` rail nudges a single staged binary, this
// heuristic looks at the *whole tracked set*: when a repo is dominated
// by curated binary types (`.psd`, `.docx`, `.zip`, short `.mp4`, …),
// it offers ONCE to set up LFS tracking for the dominant patterns.
//
// **Never automatic.** This produces an *offer* — a provider-neutral
// struct the UI (a status rail / `StatusViewModel`) renders with a
// one-click "Set up LFS" remedy and a dismiss. The user decides; the
// engine never writes `.gitattributes` on its own. The one-time
// `DocumentStoreOfferFlag` (a file under the git common dir, NOT a ref)
// keeps it quiet after the first surfacing.
//
// Tier 1, portable. Pure Swift + Foundation. All git invocation routes
// through `GitCore.Runner`; the classification math is a pure read of
// the tracked path list (no history walk, no per-file stat — the
// sample is the `git ls-files` output the heuristic already has).

import Foundation
import GitCore

/// A provider-neutral recommendation produced by ``DocumentStoreHeuristic``.
///
/// Carries the verdict (``shouldOffer``) plus the evidence behind it so
/// the UI can show "N of M tracked files are binary documents" and so
/// the "Set up LFS" remedy knows exactly which `*.ext` patterns to
/// track. Pure value type — `Equatable`/`Sendable` for testing and for
/// crossing the IPC boundary.
public struct DocumentStoreRecommendation: Equatable, Sendable {
    /// True when the tracked set is *dominated* by curated binary types
    /// per ``DocumentStoreHeuristic`` (and the repo clears the minimum
    /// tracked-file floor). The UI gates the offer on this. Note that a
    /// caller still consults ``DocumentStoreOfferFlag`` to enforce
    /// once-per-repo: this struct says "the repo qualifies", the flag
    /// says "we haven't asked yet".
    public let shouldOffer: Bool

    /// Total tracked files considered (the `git ls-files` count).
    public let trackedFileCount: Int

    /// How many of ``trackedFileCount`` matched a curated binary type.
    public let binaryFileCount: Int

    /// The dominant `*.ext` LFS patterns, most-common first, then
    /// alphabetical for ties — deterministic so tests and the UI render
    /// stably. Each is ready to hand to ``LFSTrack/track(pattern:runner:)``.
    /// Empty when ``shouldOffer`` is false.
    public let suggestedPatterns: [String]

    /// `binaryFileCount / trackedFileCount` as a fraction in `0...1`
    /// (0 when there are no tracked files). The share the threshold
    /// compares against; surfaced so the UI can show the percentage.
    public var binaryShare: Double {
        guard trackedFileCount > 0 else { return 0 }
        return Double(binaryFileCount) / Double(trackedFileCount)
    }

    public init(
        shouldOffer: Bool,
        trackedFileCount: Int,
        binaryFileCount: Int,
        suggestedPatterns: [String]
    ) {
        self.shouldOffer = shouldOffer
        self.trackedFileCount = trackedFileCount
        self.binaryFileCount = binaryFileCount
        self.suggestedPatterns = suggestedPatterns
    }

    /// The "no, this isn't a document store" verdict for a given count.
    static func declined(trackedFileCount: Int, binaryFileCount: Int) -> Self {
        DocumentStoreRecommendation(
            shouldOffer: false,
            trackedFileCount: trackedFileCount,
            binaryFileCount: binaryFileCount,
            suggestedPatterns: []
        )
    }
}

/// Classifies a repo's tracked set and decides whether to offer LFS setup.
///
/// **What "dominated" means (and why this threshold).** A repo qualifies
/// when curated-binary files are a *large share of the tracked files*
/// **and** there are enough tracked files for the share to be meaningful:
///
///   - `binaryShare >= minimumBinaryShare` (default **0.5** — at least
///     half the tracked files are curated binaries). Half is the
///     defensible line for "this is effectively a document store, not a
///     code repo with some assets": below it, the binaries are a
///     minority the per-file `binaryTypeWithoutLFS` rail already covers
///     one at a time; at or above it, a repo-wide LFS starter set is the
///     proportionate nudge. We key on file *count*, not bytes, because
///     the tracked-byte total would require a `git ls-files`-plus-stat
///     pass (or cat-file) — the ADR says "samples the tracked set, it
///     does not walk full history", and the path list alone is the cheap
///     sample. Count-share is also robust to one giant text file
///     (a generated lockfile, a vendored blob) that bytes would skew.
///   - `trackedFileCount >= minimumTrackedFiles` (default **5**) — a
///     floor so a fresh repo with a single `.psd` (1/1 = 100%) doesn't
///     trip the offer. Five is small enough to catch a real
///     just-started document store yet large enough that the share is
///     not noise.
///
/// Both bounds are injectable so tests pin exact behavior and callers
/// can tune per persona (ADR 0019 reveal levels could relax them).
public struct DocumentStoreHeuristic: Sendable {
    /// The curated binary type set the share is measured against.
    public let binaryTypes: LFSBinaryTypes

    /// Minimum fraction of tracked files that must be curated binaries
    /// for the offer to fire. Default 0.5 (see the type doc comment).
    public let minimumBinaryShare: Double

    /// Minimum tracked-file count below which the offer never fires,
    /// regardless of share. Default 5.
    public let minimumTrackedFiles: Int

    public init(
        binaryTypes: LFSBinaryTypes = LFSBinaryTypes(),
        minimumBinaryShare: Double = 0.5,
        minimumTrackedFiles: Int = 5
    ) {
        self.binaryTypes = binaryTypes
        self.minimumBinaryShare = minimumBinaryShare
        self.minimumTrackedFiles = minimumTrackedFiles
    }

    /// Classify an explicit list of tracked paths (pure — no git).
    ///
    /// This is the testable core: hand it the paths and it returns the
    /// verdict. ``evaluate(runner:cwd:)`` is the convenience that fetches
    /// the paths via `git ls-files` and calls this.
    public func classify(trackedPaths: [String]) -> DocumentStoreRecommendation {
        let trackedFileCount = trackedPaths.count

        // Count curated-binary files per extension so we can rank the
        // dominant `*.ext` patterns for the remedy.
        var perPatternCount: [String: Int] = [:]
        for path in trackedPaths {
            if let pattern = binaryTypes.suggestedPattern(for: path) {
                perPatternCount[pattern, default: 0] += 1
            }
        }
        let binaryFileCount = perPatternCount.values.reduce(0, +)

        guard trackedFileCount >= minimumTrackedFiles else {
            return .declined(trackedFileCount: trackedFileCount, binaryFileCount: binaryFileCount)
        }
        let share = Double(binaryFileCount) / Double(trackedFileCount)
        guard share >= minimumBinaryShare else {
            return .declined(trackedFileCount: trackedFileCount, binaryFileCount: binaryFileCount)
        }

        // Most-common pattern first; alphabetical tiebreak for a stable,
        // deterministic order across platforms (dictionary iteration is
        // unordered, so the sort is what makes the output reproducible).
        let patterns = perPatternCount
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .map(\.key)

        return DocumentStoreRecommendation(
            shouldOffer: true,
            trackedFileCount: trackedFileCount,
            binaryFileCount: binaryFileCount,
            suggestedPatterns: patterns
        )
    }

    /// Fetch the tracked paths via `git ls-files -z` and classify them.
    ///
    /// `-z` (NUL-separated) so paths with spaces / non-ASCII bytes are
    /// unambiguous and core.quotepath can't mangle them. The verdict is
    /// purely the file-name list; no per-file stat or history walk.
    public func evaluate(runner: Runner, cwd: URL? = nil) async throws -> DocumentStoreRecommendation {
        let output = try await runner.run(["ls-files", "-z"], cwd: cwd)
        let paths = Self.parseLSFilesZ(output.stdout)
        return classify(trackedPaths: paths)
    }

    /// Parse `git ls-files -z` output: NUL-separated path records, no
    /// trailing record after the final NUL. Splitting on the NUL byte
    /// also sidesteps the CRLF-in-a-Character trap — there are no line
    /// terminators in the stream at all.
    static func parseLSFilesZ(_ data: Data) -> [String] {
        data
            .split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { String(data: Data($0), encoding: .utf8) }
    }
}
