// PreflightChecks.swift
//
// ADR 0070 "pre-flight guard rails": cheap, porcelain-driven nudges
// surfaced at verb time — never blocking, never background nags
// (git-beginner-affordances.md item 2.3). The checks shipped here are
// the commit-time set:
//
//   * committing to a default branch (main/master) that tracks a
//     remote — most teams want a feature branch;
//   * detached HEAD — work here can be lost without a branch;
//   * a staged file over the size threshold that isn't LFS-tracked —
//     offer ADR 0029's LFS flow before the push gets painful;
//   * a staged hunk that looks like a secret — an API key, token, or
//     private key (ADR 0092), via the vendored `GitCore.SecretScan`.
//
// Design constraints:
//   - **Warnings, not errors.** Nothing here blocks `commit()`; the
//     UI renders banners with one-click remedies. Power users ignore
//     them (or disable per the reveal level, ADR 0019).
//   - **No extra spawns in the common case.** Branch checks read the
//     `PorcelainV2Status` the view model already parsed; the LFS
//     check stats staged files first and only invokes
//     `git check-attr` for the over-threshold subset (usually empty).
//   - **Best-effort.** A failing probe drops its check rather than
//     failing the refresh — a broken repo will surface real errors
//     through the verbs themselves.

import Foundation
import GitCore
import LFSKit

/// One pre-flight nudge for the UI to render as a banner with a
/// one-click remedy. Cases carry the data the remedy needs.
public enum PreflightWarning: Sendable, Equatable {
    /// HEAD is a default branch (main/master) with an upstream —
    /// suggest creating a feature branch (one-click: New Branch…
    /// carrying staged changes along).
    case committingToDefaultBranch(branch: String, upstream: String)

    /// HEAD is detached — commits made here are easy to lose.
    /// One-click remedy: create a branch at `oid`.
    case detachedHEAD(oid: String?)

    /// A staged file exceeds `thresholdBytes` and is not LFS-tracked.
    /// One-click remedy: ADR 0029's "track with LFS" flow.
    case largeStagedFileWithoutLFS(path: String, sizeBytes: Int64, thresholdBytes: Int64)

    /// The CURRENT branch has commits its upstream doesn't — shown at
    /// switch time. Purely informational: the commits stay safely on
    /// the branch, but beginners often read "switched away" as
    /// "lost". One-click remedy: push before switching.
    case switchingAwayFromUnpushed(branch: String, unpushedCount: Int)

    /// A staged hunk contains what looks like a secret — an API key,
    /// token, or private key (ADR 0092). Warn-and-proceed: the banner
    /// offers "Add to `.gitignore`" (reuse ``GitignoreSuggestion``) and a
    /// revocation-first reminder (if the secret already reached a remote,
    /// rotating it matters more than removing it). Carries only the file,
    /// the matched rule's title, and the line — never the secret value.
    case stagedSecretDetected(path: String, rule: String, line: Int)

    /// The push target is the forge default / protected branch
    /// (main/master heuristic; ADR 0063 can refine with forge metadata).
    /// Pushing straight to it is what most teams gate behind review (ADR 0093).
    case pushingToProtectedBranch(branch: String)

    /// The current branch has diverged from its upstream (`ahead` local
    /// commits, `behind` remote commits), so a plain push is rejected and
    /// only a force could publish it — which rewrites history collaborators
    /// may have. Sprig routes to fetch + resolve, never an auto-force
    /// (ADR 0052/0093).
    case forcePushConsequence(branch: String, ahead: Int, behind: Int)

    /// A commit in the outgoing range (`@{u}..HEAD`) — not just the staged
    /// tree — contains what looks like a secret (ADR 0093, via the ADR 0092
    /// ``GitCore/SecretScan``). Carries file/rule/line, never the value.
    case secretInOutgoingCommits(path: String, rule: String, line: Int)

    /// A staged file whose *type* (curated binary extension) warrants LFS
    /// but isn't LFS-tracked — regardless of size (ADR 0091). The sibling
    /// of ``largeStagedFileWithoutLFS``, covering the small-to-medium
    /// binaries (`.psd`, `.docx`, short `.mp4`) the size rail misses.
    /// One-click remedy: ADR 0029's "Track with LFS" for `suggestedPattern`.
    case binaryTypeWithoutLFS(path: String, suggestedPattern: String)

    /// Stable per-rail identifier — the value the shells' "never
    /// show this again" checkbox writes into
    /// `AppPreferences.suppressedGuardRails` (ADR 0070 amendment)
    /// and ``PreflightChecks/suppressedRails`` filters on. Wire-ish:
    /// persisted in preference files, so renaming is a migration.
    public var railID: String {
        switch self {
        case .committingToDefaultBranch: "committing-to-default-branch"
        case .detachedHEAD: "detached-head"
        case .largeStagedFileWithoutLFS: "large-staged-file-without-lfs"
        case .switchingAwayFromUnpushed: "switching-away-from-unpushed"
        case .stagedSecretDetected: "staged-secret"
        case .pushingToProtectedBranch: "pushing-to-protected-branch"
        case .forcePushConsequence: "force-push-consequence"
        case .secretInOutgoingCommits: "secret-in-outgoing-commits"
        case .binaryTypeWithoutLFS: "binary-type-without-lfs"
        }
    }
}

/// Stateless evaluator for the ADR 0070 commit-time guard rails.
public struct PreflightChecks: Sendable {
    /// 50 MiB — under GitHub's hard 100 MB push limit with margin,
    /// and the point where clone/fetch pain becomes noticeable.
    public static let defaultLargeFileThresholdBytes: Int64 = 50 * 1024 * 1024

    /// Branch names treated as "the default branch". Heuristic, not
    /// forge-derived: ADR 0063's forge integration can refine this
    /// with the repo's actual default/protected branch later.
    public static let defaultBranchNames: Set<String> = ["main", "master"]

    public var largeFileThresholdBytes: Int64
    public var defaultBranchNames: Set<String>

    /// Rail IDs the user opted out of via the banner's "never show
    /// this again" checkbox (persisted in
    /// `AppPreferences.suppressedGuardRails`; shells pass the value
    /// through here). Suppressed rails are filtered out of every
    /// result — the checks may not even run (the LFS rail skips its
    /// stat pass entirely when suppressed).
    public var suppressedRails: Set<String>

    public init(
        largeFileThresholdBytes: Int64 = PreflightChecks.defaultLargeFileThresholdBytes,
        defaultBranchNames: Set<String> = PreflightChecks.defaultBranchNames,
        suppressedRails: Set<String> = []
    ) {
        self.largeFileThresholdBytes = largeFileThresholdBytes
        self.defaultBranchNames = defaultBranchNames
        self.suppressedRails = suppressedRails
    }

    /// Branch-state checks, computed purely from an already-parsed
    /// porcelain-v2 status — no git invocation.
    ///
    /// `branch.head == nil` is the parser's detached-HEAD encoding
    /// (`# branch.head (detached)`). The default-branch warning fires
    /// only when an upstream is configured: a local-only repo where
    /// `main` is the only branch shouldn't nag.
    public func branchWarnings(from branch: BranchInfo?) -> [PreflightWarning] {
        guard let branch else { return [] }
        guard let head = branch.head else {
            return [.detachedHEAD(oid: branch.oid)].filter(notSuppressed)
        }
        if let upstream = branch.upstream, defaultBranchNames.contains(head) {
            return [.committingToDefaultBranch(branch: head, upstream: upstream)]
                .filter(notSuppressed)
        }
        return []
    }

    private func notSuppressed(_ warning: PreflightWarning) -> Bool {
        !suppressedRails.contains(warning.railID)
    }

    /// Switch-time informational (the 2.3 remainder): the checked-out
    /// branch is ahead of its upstream. Pure read of already-fetched
    /// sync states — no git invocation here; the VM passes the
    /// `branchSyncStates()` it computes anyway. Quiet with no
    /// upstream (nothing to be "not on") and on a gone upstream
    /// (the ADR 0073 cleanup banner owns that story).
    public func switchAwayWarnings(states: [BranchSyncState]) -> [PreflightWarning] {
        guard let current = states.first(where: \.isCurrent),
              current.upstreamShort != nil,
              !current.upstreamGone,
              current.ahead > 0
        else { return [] }
        return [
            PreflightWarning.switchingAwayFromUnpushed(
                branch: current.name,
                unpushedCount: current.ahead
            )
        ].filter(notSuppressed)
    }

    /// Large-staged-file check: stat each staged path on disk, then
    /// ask `git check-attr` (via ``LFSKit/LFSAttributeChecker``)
    /// whether the over-threshold subset is LFS-tracked. Paths that
    /// don't exist on disk (staged deletes/renames) and probe
    /// failures are skipped — best-effort by design.
    ///
    /// Worktree size is used as a proxy for the staged blob's size;
    /// the rare stage-then-truncate divergence costs a spurious (or
    /// missed) warning, not correctness.
    public func largeStagedFileWarnings(
        stagedPaths: [String],
        repoURL: URL,
        runner: Runner
    ) async -> [PreflightWarning] {
        guard !suppressedRails.contains("large-staged-file-without-lfs") else { return [] }
        let oversize: [(path: String, size: Int64)] = stagedPaths.compactMap { path in
            let url = repoURL.appendingPathComponent(path)
            guard
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = (attrs[.size] as? NSNumber)?.int64Value,
                size > largeFileThresholdBytes
            else { return nil }
            return (path, size)
        }
        guard !oversize.isEmpty else { return [] }

        guard let results = try? await LFSAttributeChecker.check(
            paths: oversize.map(\.path),
            runner: runner
        ) else { return [] }
        let lfsTracked = Set(results.filter(\.isLFS).map(\.path))

        return oversize
            .filter { !lfsTracked.contains($0.path) }
            .map { .largeStagedFileWithoutLFS(
                path: $0.path,
                sizeBytes: $0.size,
                thresholdBytes: largeFileThresholdBytes
            ) }
    }

    /// Type-aware LFS check (ADR 0091): staged files whose curated binary
    /// *type* warrants LFS but that aren't LFS-tracked — the small-to-medium
    /// binaries (`.psd`, `.docx`, short `.mp4`) the size rail
    /// (``largeStagedFileWithoutLFS``) misses. Files at or over the size
    /// threshold are left to that rail, so a file never gets two banners.
    /// Best-effort; skipped when suppressed or nothing is staged.
    public func binaryTypeWarnings(
        stagedPaths: [String],
        repoURL: URL,
        runner: Runner,
        binaryTypes: LFSBinaryTypes = LFSBinaryTypes()
    ) async -> [PreflightWarning] {
        guard !suppressedRails.contains("binary-type-without-lfs"), !stagedPaths.isEmpty else { return [] }
        let candidates: [(path: String, pattern: String)] = stagedPaths.compactMap { path in
            guard binaryTypes.matches(path: path),
                  let pattern = binaryTypes.suggestedPattern(for: path)
            else { return nil }
            // Over-threshold binaries are the size rail's; skip them here.
            let url = repoURL.appendingPathComponent(path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                .flatMap { ($0[.size] as? NSNumber)?.int64Value }
            if let size, size > largeFileThresholdBytes { return nil }
            return (path, pattern)
        }
        guard !candidates.isEmpty else { return [] }

        guard let results = try? await LFSAttributeChecker.check(
            paths: candidates.map(\.path),
            runner: runner
        ) else { return [] }
        let lfsTracked = Set(results.filter(\.isLFS).map(\.path))

        return candidates
            .filter { !lfsTracked.contains($0.path) }
            .map { .binaryTypeWithoutLFS(path: $0.path, suggestedPattern: $0.pattern) }
    }

    /// Staged-secret check (ADR 0092): run ``GitCore/SecretScan`` over
    /// the staged hunks (`git diff --cached`) against the vendored
    /// ruleset, honoring the repo's `.sprig/secret-allow` allowlist. One
    /// warning per distinct (path, rule, line). Best-effort: a scan
    /// failure drops the check rather than failing the refresh.
    ///
    /// Gated on `stagedPaths` being non-empty so it adds **no** git spawn
    /// in the common "nothing staged" case (ADR 0070's no-extra-spawns
    /// principle); skipped entirely when the rail is suppressed.
    public func stagedSecretWarnings(
        stagedPaths: [String],
        repoURL: URL,
        runner: Runner,
        scanner: SecretScan = SecretScan()
    ) async -> [PreflightWarning] {
        guard !suppressedRails.contains("staged-secret"), !stagedPaths.isEmpty else { return [] }
        let allowlist = SecretScan.loadAllowlist(repoURL: repoURL)
        guard let findings = try? await scanner.scanStaged(runner: runner, allowlist: allowlist) else {
            return []
        }
        var seen: Set<String> = []
        var warnings: [PreflightWarning] = []
        for finding in findings {
            let key = "\(finding.path)\u{0}\(finding.ruleID)\u{0}\(finding.line)"
            guard seen.insert(key).inserted else { continue }
            warnings.append(.stagedSecretDetected(
                path: finding.path,
                rule: finding.ruleTitle,
                line: finding.line
            ))
        }
        return warnings
    }

    /// Push-time rails (ADR 0093), evaluated from the post-fetch sync
    /// `states` just before the push leg. All warn-and-proceed.
    ///
    /// Protected-branch and force-consequence are pure reads of `states`
    /// (no spawn); the outgoing-commit secret scan runs only when there
    /// is an upstream and outgoing commits, over the bounded `@{u}..HEAD`
    /// range. Each rail is skipped when suppressed.
    public func pushWarnings(
        states: [BranchSyncState],
        repoURL: URL,
        runner: Runner,
        scanner: SecretScan = SecretScan()
    ) async -> [PreflightWarning] {
        guard let current = states.first(where: \.isCurrent) else { return [] }
        var warnings: [PreflightWarning] = []

        // Single-line conditions (precomputed bools) avoid the
        // SwiftFormat-vs-SwiftLint multiline-`if`-brace conflict.
        let onProtected = current.upstreamShort != nil && defaultBranchNames.contains(current.name)
        if onProtected, !suppressedRails.contains("pushing-to-protected-branch") {
            warnings.append(.pushingToProtectedBranch(branch: current.name))
        }

        let diverged = !current.upstreamGone && current.ahead > 0 && current.behind > 0
        if diverged, !suppressedRails.contains("force-push-consequence") {
            warnings.append(.forcePushConsequence(branch: current.name, ahead: current.ahead, behind: current.behind))
        }

        let hasOutgoing = current.upstreamShort != nil && !current.upstreamGone && current.ahead > 0
        if hasOutgoing, !suppressedRails.contains("secret-in-outgoing-commits") {
            let allowlist = SecretScan.loadAllowlist(repoURL: repoURL)
            if let findings = try? await scanner.scanRange("@{u}..HEAD", runner: runner, allowlist: allowlist) {
                var seen: Set<String> = []
                for finding in findings {
                    let key = "\(finding.path)\u{0}\(finding.ruleID)\u{0}\(finding.line)"
                    guard seen.insert(key).inserted else { continue }
                    warnings.append(.secretInOutgoingCommits(path: finding.path, rule: finding.ruleTitle, line: finding.line))
                }
            }
        }
        return warnings
    }
}
