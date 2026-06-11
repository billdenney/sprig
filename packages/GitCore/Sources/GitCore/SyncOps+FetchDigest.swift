// SyncOps+FetchDigest.swift
//
// Affordance 3.3 (ADR 0077): "what changed?" after a fetch — answer
// the question before the user asks it. When a fetch moves a
// remote-tracking ref, summarize the movement as "N new commits from
// M people on origin/x". Pure plumbing — one `git log --format=%an`
// per moved ref (line count = commits, unique count = authors); no
// AI anywhere near it.

import Foundation

/// One remote-tracking ref's movement across a fetch.
public struct FetchDigest: Sendable, Equatable {
    /// Short ref, e.g. `origin/main`.
    public let ref: String
    public let oldSHA: String
    public let newSHA: String
    /// Commits in `oldSHA..newSHA`.
    public let commitCount: Int
    /// Distinct commit authors in that range.
    public let authorCount: Int

    public init(ref: String, oldSHA: String, newSHA: String, commitCount: Int, authorCount: Int) {
        self.ref = ref
        self.oldSHA = oldSHA
        self.newSHA = newSHA
        self.commitCount = commitCount
        self.authorCount = authorCount
    }
}

public extension SyncOps {
    /// `fetchAll` with movement detection: snapshot the
    /// remote-tracking refs before and after, then digest each moved
    /// ref. Brand-new refs (no old SHA) and deleted refs are skipped —
    /// the digest answers "what's new on branches I already track".
    func fetchAllDigesting(prune: Bool = true) async throws -> [FetchDigest] {
        let before = try await remoteTrackingTips()
        try await fetchAll(prune: prune)
        let after = try await remoteTrackingTips()

        var digests: [FetchDigest] = []
        for (ref, newSHA) in after.sorted(by: { $0.key < $1.key }) {
            guard let oldSHA = before[ref], oldSHA != newSHA else { continue }
            try await digests.append(digest(ref: ref, from: oldSHA, to: newSHA))
        }
        return digests
    }

    /// `refs/remotes/*` tips as short-ref → SHA. Symbolic refs
    /// (`origin/HEAD`, whose short form is just `origin`) are
    /// excluded via the `%(symref)` field — they shadow a branch
    /// that is already listed and would double-digest its movement.
    internal func remoteTrackingTips() async throws -> [String: String] {
        let output = try await runner.run([
            "for-each-ref",
            "--format=%(refname:short)\t%(objectname)\t%(symref)",
            "refs/remotes/"
        ])
        var tips: [String: String] = [:]
        for line in output.stdoutString.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let symref = parts.count >= 3 ? parts[2] : ""
            guard symref.isEmpty else { continue }
            tips[String(parts[0])] = String(parts[1])
        }
        return tips
    }

    /// One spawn per moved ref: `%an` lines give both counts. A
    /// non-fast-forward movement (remote rebased) makes `old..new`
    /// undercount; that's fine — the digest is a summary line, not an
    /// audit (the diverged report covers the rewrite case).
    internal func digest(ref: String, from oldSHA: String, to newSHA: String) async throws -> FetchDigest {
        let log = try await runner.run(
            ["log", "--format=%an", "\(oldSHA)..\(newSHA)"],
            throwOnNonZero: false
        )
        let authors = log.stdoutString
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return FetchDigest(
            ref: ref,
            oldSHA: oldSHA,
            newSHA: newSHA,
            commitCount: authors.count,
            authorCount: Set(authors).count
        )
    }
}
