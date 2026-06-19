// OperationProvenance.swift
//
// ADR 0088 prerequisite (deferred from ADR 0056) — the "did Sprig
// author this?" signal. The agent-review surface (ADR 0088) flags
// commits / ref movements that arrived from OUTSIDE Sprig (a terminal,
// an AI coding agent, a teammate's tooling). To do that without
// flagging the user's own GUI commits, Sprig records what IT did:
//
//   - the commit SHAs it authored (so a new commit not in the set is
//     external), and
//   - a checkpoint of the ref → SHA state after its own operations (so a
//     HEAD that moved to a different *existing* commit is external too).
//
// **Why a file, not a ref.** Snapshot/backup refs (ADR 0033/0075)
// deliberately *pin* commits to keep them recoverable; provenance must
// do the OPPOSITE — it must never keep an abandoned commit reachable
// (that would bloat the repo and defeat `git gc`). Storing SHAs as plain
// text in a file under the git dir pins nothing, stays local (provenance
// is this-machine state, never pushed/shared), and is a cheap append +
// membership check. It lives under the **common** git dir
// (`--git-common-dir`) so a commit authored in one linked worktree is
// recognized as Sprig-authored from any worktree (a commit's provenance
// is a property of the commit, repo-wide — not of a worktree's HEAD).
//
// Concurrency: load → modify → atomic-write (`Data` `.atomic` = temp +
// rename). The atomic rename makes each *write* all-or-nothing, but the
// read-modify-write window is NOT locked, so genuinely concurrent
// recorders (two Sprig processes, or reentrant async calls racing across
// the `git rev-parse` suspension) can clobber each other — a lost SHA is
// permanent until that commit is recorded again. The blast radius is
// only cosmetic: a Sprig commit momentarily reads as "external" in ADR
// 0088's review UI (a dismissable false positive), never lost user work.
// Today's sole producer (`CommitComposerViewModel`) serializes its
// commits, so it never races itself. A verb that records MANY commits at
// once (merge/rebase/squash/cherry-pick, per ADR 0088) MUST use the
// batch ``recordAuthored(_:)-([String])`` so all N land in one atomic
// cycle rather than N racing ones.
//
// Tier 1, portable. All git access via ``Runner``.

import Foundation

/// Records and queries which commits / ref states Sprig itself produced,
/// so external (non-Sprig) changes can be told apart (ADR 0088).
public struct OperationProvenance: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    private struct Record: Codable {
        var authored: [String] = []
        var heads: [String: String] = [:]
    }

    // MARK: - Producer side (Sprig's verbs record what they did)

    /// Record that Sprig authored `sha` (a commit one of its verbs just
    /// created). No-op for an empty string.
    public func recordAuthored(_ sha: String) async throws {
        try await recordAuthored([sha])
    }

    /// Record many authored commits in ONE atomic load-modify-write — the
    /// safe path for a verb that emits several commits at once (a rewrite:
    /// merge / rebase / squash / cherry-pick). Recording them one at a
    /// time would race the read-modify-write window and drop most.
    /// Empty / whitespace-only entries are ignored.
    public func recordAuthored(_ shas: [String]) async throws {
        let cleaned = shas
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        var record = try await load()
        var set = Set(record.authored)
        let before = set.count
        for sha in cleaned {
            set.insert(sha)
        }
        guard set.count != before else { return } // nothing new
        record.authored = set.sorted()
        try await save(record)
    }

    /// Checkpoint the current ref → SHA state after a Sprig operation, so
    /// a later move Sprig didn't make is detectable.
    public func recordHeads(_ heads: [String: String]) async throws {
        var record = try await load()
        record.heads = heads
        try await save(record)
    }

    // MARK: - Consumer side (ADR 0088 detector)

    /// Every commit SHA Sprig has recorded authoring.
    public func authoredCommits() async throws -> Set<String> {
        try await Set(load().authored)
    }

    /// The ref → SHA state from the last ``recordHeads(_:)``.
    public func lastKnownHeads() async throws -> [String: String] {
        try await load().heads
    }

    /// Of `candidates` (e.g. commits in `oldHead..newHead`), those Sprig
    /// did NOT author — the externally-authored set ADR 0088 reviews.
    /// Order is preserved.
    public func externalCommits(among candidates: [String]) async throws -> [String] {
        let authored = try await authoredCommits()
        return candidates.filter { !authored.contains($0) }
    }

    // MARK: - Storage

    /// `<git-common-dir>/sprig/provenance.json`, absolute + worktree-safe.
    private func storeURL() async throws -> URL {
        let output = try await runner.run(["rev-parse", "--path-format=absolute", "--git-common-dir"])
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: output)
            .appendingPathComponent("sprig")
            .appendingPathComponent("provenance.json")
    }

    private func load() async throws -> Record {
        let url = try await storeURL()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return Record() }
        return (try? JSONDecoder().decode(Record.self, from: data)) ?? Record()
    }

    private func save(_ record: Record) async throws {
        let url = try await storeURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(record)
        // Direct (non-atomic) write with a short retry. `.atomic`'s
        // temp-file + rename is the pattern Windows transiently rejects
        // with ERROR_SHARING_VIOLATION (an antivirus/indexer briefly
        // holding a handle on a freshly-created `.git` subdir — hosted CI
        // reproduces it). A torn write (process killed mid-write) is the
        // already-handled corrupt-file case: `load` fails-open to empty.
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
}
