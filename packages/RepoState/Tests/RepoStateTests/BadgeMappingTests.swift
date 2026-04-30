import Foundation
import GitCore
@testable import RepoState
import Testing

@Suite("BadgeIdentifier.init(porcelainEntry:) — Entry → BadgeIdentifier mapping")
struct BadgeMappingTests {
    private func ordinary(index: StatusCode, worktree: StatusCode, path: String = "f.txt") -> Entry {
        let zero = String(repeating: "0", count: 40)
        return .ordinary(Ordinary(
            xy: StatusXY(index: index, worktree: worktree),
            submodule: .notSubmodule,
            modeHead: 0o100644,
            modeIndex: 0o100644,
            modeWorktree: 0o100644,
            hashHead: zero,
            hashIndex: zero,
            path: path
        ))
    }

    private func renamed(index: StatusCode, worktree: StatusCode) -> Entry {
        let zero = String(repeating: "0", count: 40)
        return .renamed(Renamed(
            xy: StatusXY(index: index, worktree: worktree),
            submodule: .notSubmodule,
            modeHead: 0o100644,
            modeIndex: 0o100644,
            modeWorktree: 0o100644,
            hashHead: zero,
            hashIndex: zero,
            op: .renamed,
            score: 100,
            path: "new.txt",
            origPath: "old.txt"
        ))
    }

    // MARK: simple kinds

    @Test("untracked entry maps to .untracked")
    func untracked() {
        #expect(BadgeIdentifier(porcelainEntry: .untracked(path: "new.txt")) == .untracked)
    }

    @Test("ignored entry maps to .ignored")
    func ignored() {
        #expect(BadgeIdentifier(porcelainEntry: .ignored(path: "build/")) == .ignored)
    }

    @Test("unmerged entry maps to .conflict regardless of XY")
    func unmerged() {
        let zero = String(repeating: "0", count: 40)
        let entry: Entry = .unmerged(Unmerged(
            xy: StatusXY(index: .updatedUnmerged, worktree: .updatedUnmerged),
            submodule: .notSubmodule,
            modeStage1: 0o100644,
            modeStage2: 0o100644,
            modeStage3: 0o100644,
            modeWorktree: 0o100644,
            hashStage1: zero,
            hashStage2: zero,
            hashStage3: zero,
            path: "c.txt"
        ))
        #expect(BadgeIdentifier(porcelainEntry: entry) == .conflict)
    }

    // MARK: ordinary entries — worktree-changed cases all map to .modified

    @Test(".M (worktree-modified only) → .modified")
    func dotMmapsModified() {
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .unmodified, worktree: .modified)) == .modified)
    }

    @Test("MM (staged + worktree-modified) → .modified (worktree wins)")
    func mmMapsModified() {
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .modified, worktree: .modified)) == .modified)
    }

    @Test(".D (worktree delete) → .modified")
    func dotDmapsModified() {
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .unmodified, worktree: .deleted)) == .modified)
    }

    @Test("AM (staged-add + worktree-modified) → .modified (worktree wins)")
    func amMapsModified() {
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .added, worktree: .modified)) == .modified)
    }

    // MARK: ordinary entries — index-only cases

    @Test("M. (staged-modified only) → .staged")
    func mDotMapsStaged() {
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .modified, worktree: .unmodified)) == .staged)
    }

    @Test("D. (staged delete only) → .staged")
    func dDotMapsStaged() {
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .deleted, worktree: .unmodified)) == .staged)
    }

    @Test("A. (staged add only) → .added")
    func aDotMapsAdded() {
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .added, worktree: .unmodified)) == .added)
    }

    @Test("T. (staged typechange only) → .staged")
    func tDotMapsStaged() {
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .typeChanged, worktree: .unmodified)) == .staged)
    }

    // MARK: renamed entries follow the same XY semantics

    @Test("renamed entry with worktree-modified → .modified")
    func renamedWithWorktreeChange() {
        #expect(BadgeIdentifier(porcelainEntry: renamed(index: .renamed, worktree: .modified)) == .modified)
    }

    @Test("renamed entry with worktree-clean → .staged")
    func renamedClean() {
        #expect(BadgeIdentifier(porcelainEntry: renamed(index: .renamed, worktree: .unmodified)) == .staged)
    }

    // MARK: defensive paths

    @Test("U. (defensive: unexpected unmerged in ordinary) → .conflict")
    func unmergedInOrdinary() {
        // Shouldn't happen in well-formed porcelain output (unmerged
        // entries come through Entry.unmerged), but if a future git
        // version emits it, we route it as a conflict rather than
        // misclassify into a less-actionable state.
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .updatedUnmerged, worktree: .unmodified)) == .conflict)
    }

    @Test(".. (defensive: clean-clean ordinary) → .staged fallback")
    func cleanClean() {
        // Clean-clean ordinary shouldn't appear in porcelain-v2 output
        // at all. If we see one, default to .staged so the user is
        // prompted to investigate rather than silently treating it as
        // clean.
        #expect(BadgeIdentifier(porcelainEntry: ordinary(index: .unmodified, worktree: .unmodified)) == .staged)
    }
}
