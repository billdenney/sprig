import Foundation
@testable import RepoState
import Testing

@Suite("BadgeIdentifier — wire stability + priority semantics")
struct BadgeIdentifierTests {
    // MARK: wire stability

    @Test("rawValue strings are wire-stable and match docs/architecture/shell-integration.md")
    func rawValuesMatchSpec() {
        // These are LOAD-BEARING — they appear in IPC envelopes between the
        // agent and the shell extension, and in registry / asset-catalog
        // identifiers on disk. Renaming any of them is a breaking change.
        #expect(BadgeIdentifier.clean.rawValue == "clean")
        #expect(BadgeIdentifier.modified.rawValue == "modified")
        #expect(BadgeIdentifier.added.rawValue == "added")
        #expect(BadgeIdentifier.staged.rawValue == "staged")
        #expect(BadgeIdentifier.untracked.rawValue == "untracked")
        #expect(BadgeIdentifier.conflict.rawValue == "conflict")
        #expect(BadgeIdentifier.ignored.rawValue == "ignored")
        #expect(BadgeIdentifier.lfsPointer.rawValue == "lfs-pointer")
        #expect(BadgeIdentifier.submoduleInitNeeded.rawValue == "submodule-init-needed")
        #expect(BadgeIdentifier.submoduleOutOfDate.rawValue == "submodule-out-of-date")
    }

    @Test("CaseIterable contains all 10 documented states")
    func allCasesSize() {
        #expect(BadgeIdentifier.allCases.count == 10)
    }

    @Test("rawValues are unique across all cases")
    func rawValuesUnique() {
        let raw = Set(BadgeIdentifier.allCases.map(\.rawValue))
        #expect(raw.count == BadgeIdentifier.allCases.count)
    }

    @Test("init from rawValue round-trips for every case")
    func rawValueRoundTrip() {
        for badge in BadgeIdentifier.allCases {
            let reconstructed = BadgeIdentifier(rawValue: badge.rawValue)
            #expect(reconstructed == badge)
        }
    }

    // MARK: priority semantics

    @Test("priorities are unique — strict total ordering")
    func prioritiesAreTotalOrder() {
        let priorities = BadgeIdentifier.allCases.map(\.priority)
        #expect(Set(priorities).count == priorities.count, "two states share a priority — order is ambiguous")
    }

    @Test("conflict has the highest priority — ADR 0019 'conflict always wins'")
    func conflictWinsAlways() {
        for badge in BadgeIdentifier.allCases where badge != .conflict {
            #expect(
                BadgeIdentifier.conflict.priority > badge.priority,
                "conflict should outrank \(badge)"
            )
        }
    }

    @Test("clean has the lowest priority — falls through everything actionable")
    func cleanLosesAlways() {
        for badge in BadgeIdentifier.allCases where badge != .clean {
            #expect(
                BadgeIdentifier.clean.priority < badge.priority,
                "clean should rank below \(badge)"
            )
        }
    }

    @Test("submodule states rank above ordinary file states")
    func submoduleStatesOutrankFileStates() {
        let submoduleBadges: [BadgeIdentifier] = [.submoduleInitNeeded, .submoduleOutOfDate]
        let fileBadges: [BadgeIdentifier] = [.modified, .staged, .added, .untracked, .lfsPointer, .ignored, .clean]
        for sub in submoduleBadges {
            for file in fileBadges {
                #expect(
                    sub.priority > file.priority,
                    "\(sub) should outrank \(file) (submodule render replaces file render)"
                )
            }
        }
    }

    @Test("modified > staged > added > untracked > clean — actionable-state hierarchy")
    func actionableHierarchy() {
        #expect(BadgeIdentifier.modified.priority > BadgeIdentifier.staged.priority)
        #expect(BadgeIdentifier.staged.priority > BadgeIdentifier.added.priority)
        #expect(BadgeIdentifier.added.priority > BadgeIdentifier.untracked.priority)
        #expect(BadgeIdentifier.untracked.priority > BadgeIdentifier.clean.priority)
    }

    @Test("highestPriority(of:) picks the most-actionable badge")
    func highestPriorityHelper() {
        // Conflict wins against everything else.
        let mixed: [BadgeIdentifier] = [.modified, .conflict, .untracked, .clean]
        #expect(BadgeIdentifier.highestPriority(of: mixed) == .conflict)

        // No conflict — modified outranks the ambient states.
        let actionable: [BadgeIdentifier] = [.untracked, .modified, .ignored]
        #expect(BadgeIdentifier.highestPriority(of: actionable) == .modified)

        // Empty input returns nil so callers default explicitly.
        let empty: [BadgeIdentifier] = []
        #expect(BadgeIdentifier.highestPriority(of: empty) == nil)
    }

    // MARK: reveal-level filtering (ADR 0019)

    @Test("Minimal level shows the 5 most-actionable badges only")
    func minimalRevealLevel() {
        let visible = BadgeIdentifier.allCases.filter { $0.isVisible(at: .minimal) }
        #expect(Set(visible) == Set([.clean, .modified, .staged, .untracked, .conflict]))
        #expect(visible.count == 5)
    }

    @Test("Rich level shows 8 badges (everything except submodule states)")
    func richRevealLevel() {
        let visible = BadgeIdentifier.allCases.filter { $0.isVisible(at: .rich) }
        #expect(visible.count == 8)
        #expect(!visible.contains(.submoduleInitNeeded))
        #expect(!visible.contains(.submoduleOutOfDate))
        // Rich is a strict superset of Minimal.
        let minimal = BadgeIdentifier.allCases.filter { $0.isVisible(at: .minimal) }
        for badge in minimal {
            #expect(visible.contains(badge))
        }
    }

    @Test("Full level shows all 10 badges")
    func fullRevealLevel() {
        let visible = BadgeIdentifier.allCases.filter { $0.isVisible(at: .full) }
        #expect(Set(visible) == Set(BadgeIdentifier.allCases))
        #expect(visible.count == 10)
    }

    @Test("Default reveal level is Rich (per ADR 0019)")
    func defaultRevealLevel() {
        #expect(BadgeRevealLevel.default == .rich)
    }
}
