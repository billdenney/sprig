// TaskWindowVocabularyTests.swift
//
// ADR 0072 amendment — pins the task-window string table. These are
// user-facing wire-ish values (VM tests and shells read
// `Failure.description`), so changes here are deliberate copy edits,
// not drive-by rewording. House-style rules are asserted as a class:
// trailing period, no git flags, no (git:) parentheticals (none of
// these strings is a ratified teaching point).

@testable import TaskWindowKit
import Testing

@Suite("TaskWindowVocabulary — string table")
struct TaskWindowVocabularyTests {
    private var allStrings: [String] {
        [
            TaskWindowVocabulary.pickABranchFirst,
            TaskWindowVocabulary.resolveConflictedFirst(count: 2),
            TaskWindowVocabulary.nothingToCommit,
            TaskWindowVocabulary.enterCommitSubject,
            TaskWindowVocabulary.enterRepositoryURL,
            TaskWindowVocabulary.chooseTargetDirectory,
            TaskWindowVocabulary.shallowDepthMustBePositive,
            TaskWindowVocabulary.noConflictAtPath("a.txt"),
            TaskWindowVocabulary.pickASideFirst("a.txt"),
            TaskWindowVocabulary.nothingToApply,
            TaskWindowVocabulary.noConflictsToFinalize,
            TaskWindowVocabulary.stillUnresolved(count: 3),
            TaskWindowVocabulary.noMidstreamToFinalize,
            TaskWindowVocabulary.noMidstreamToAbort,
            TaskWindowVocabulary.notInStaleList("feature/x"),
            TaskWindowVocabulary.useSafetyCopyCleanup("feature/x", unpushed: 2),
            TaskWindowVocabulary.switchAwayBeforeCleanup("feature/x"),
            TaskWindowVocabulary.refusedNotFullyMerged("feature/x"),
            TaskWindowVocabulary.checkedOutSwitchAway("feature/x"),
            TaskWindowVocabulary.stashEntryGone("On main: WIP"),
            TaskWindowVocabulary.stashConflicted("On main: WIP"),
            TaskWindowVocabulary.cancelled("Clone"),
            TaskWindowVocabulary.cancelled()
        ]
    }

    @Test("house style: non-empty, ends with a period, no flags, no parentheticals")
    func houseStyle() {
        for string in allStrings {
            #expect(!string.isEmpty)
            #expect(string.hasSuffix("."), "missing trailing period: \(string)")
            #expect(!string.contains("--"), "CLI flag leaked into copy: \(string)")
            #expect(!string.contains("(git:"), "unratified teaching parenthetical: \(string)")
        }
    }

    @Test("parameterized strings interpolate their arguments")
    func interpolation() {
        #expect(
            TaskWindowVocabulary.resolveConflictedFirst(count: 2)
                == "Resolve 2 conflicted file(s) before committing."
        )
        #expect(
            TaskWindowVocabulary.noConflictAtPath("src/a.txt")
                == "No conflict at path 'src/a.txt'."
        )
        #expect(
            TaskWindowVocabulary.stillUnresolved(count: 3)
                == "3 path(s) still unresolved."
        )
        #expect(
            TaskWindowVocabulary.useSafetyCopyCleanup("feature/x", unpushed: 2)
                == "feature/x has 2 unpushed commit(s); use the keep-a-safety-copy cleanup instead."
        )
    }

    @Test("cancelled() composes the operation noun, or stands bare")
    func cancelledShapes() {
        #expect(TaskWindowVocabulary.cancelled("Clone") == "Clone cancelled.")
        #expect(TaskWindowVocabulary.cancelled("Preferences save") == "Preferences save cancelled.")
        #expect(TaskWindowVocabulary.cancelled() == "Cancelled.")
    }

    @Test("guidance strings name the next step, not just the refusal")
    func guidanceNamesNextStep() {
        // The midstream strings dropped the developer-speak ("Call
        // refresh() first", "midstream operation") for plain words;
        // pin the new copy so it can't regress to jargon.
        #expect(
            TaskWindowVocabulary.noMidstreamToFinalize
                == "No merge or rebase in progress to finalize — refresh first."
        )
        #expect(
            TaskWindowVocabulary.noMidstreamToAbort
                == "No merge or rebase in progress to abort — refresh first."
        )
        #expect(TaskWindowVocabulary.nothingToApply == "Nothing to apply — pick sides first.")
    }
}
