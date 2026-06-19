@testable import AIKit
import Foundation
import Testing

@Suite("DeterministicSituationExplainer")
struct DeterministicSituationExplainerTests {
    @Test("clean + in-sync explains plainly and suggests no destructive verb")
    func cleanInSync() {
        let situation = RepoSituation(branchName: "main", upstreamName: "origin/main")
        let explanation = DeterministicSituationExplainer.explain(situation)

        #expect(explanation.source == .deterministic)
        #expect(explanation.text.contains("in sync"))
        #expect(explanation.suggestions.map(\.verb) == [.fetch])
        // No destructive verbs for a clean repo.
        let verbs = Set(explanation.suggestions.map(\.verb))
        #expect(verbs.isDisjoint(with: [.abort, .recover, .resolve]))
    }

    @Test("dirty working tree leads with Commit")
    func dirtyLeadsWithCommit() {
        let situation = RepoSituation(unstagedCount: 2, untrackedCount: 1)
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.suggestions.first?.verb == .commit)
        #expect(explanation.text.contains("unsaved changes"))
    }

    @Test("behind upstream leads with Pull and names the count")
    func behindLeadsWithPull() {
        let situation = RepoSituation(upstreamName: "origin/main", behind: 4)
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.suggestions.first?.verb == .pull)
        #expect(explanation.text.contains("4 commit"))
    }

    @Test("ahead of upstream leads with Push and names the count")
    func aheadLeadsWithPush() {
        let situation = RepoSituation(upstreamName: "origin/x", ahead: 2)
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.suggestions.first?.verb == .push)
        #expect(explanation.text.contains("2 commit"))
    }

    @Test("diverged leads with Pull, offers Fetch, names 'diverged'")
    func divergedLeadsWithPull() {
        let situation = RepoSituation(upstreamName: "origin/main", ahead: 1, behind: 3)
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.suggestions.first?.verb == .pull)
        #expect(explanation.suggestions.map(\.verb).contains(.fetch))
        #expect(explanation.text.contains("diverged"))
    }

    @Test("a parked merge leads with Continue then Abort")
    func parkedMergeLeadsWithContinue() {
        let situation = RepoSituation(conflictedCount: 2, parkedOperation: .merge)
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.suggestions.map(\.verb) == [.continueOperation, .abort])
        #expect(explanation.text.contains("merge"))
        #expect(explanation.text.contains("paused"))
    }

    @Test("parked op takes priority over conflicts in the headline")
    func parkedOpBeatsConflicts() {
        // Both a parked rebase AND conflicts: the rebase headline wins.
        let situation = RepoSituation(conflictedCount: 1, parkedOperation: .rebase)
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.suggestions.first?.verb == .continueOperation)
        #expect(explanation.text.contains("rebase"))
    }

    @Test("conflicts without a parked op lead with Resolve")
    func conflictsLeadWithResolve() {
        let situation = RepoSituation(conflictedCount: 1)
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.suggestions.map(\.verb) == [.resolve])
        #expect(explanation.text.contains("conflicting edits"))
    }

    @Test("detached HEAD is named in the headline")
    func detachedHead() {
        let situation = RepoSituation(isDetachedHead: true)
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.text.contains("not on a branch"))
        #expect(explanation.text.contains("detached HEAD"))
    }

    @Test("detached HEAD leads with Switch (the verb that resolves it), not a no-op Fetch")
    func detachedHeadLeadsWithSwitch() {
        let situation = RepoSituation(isDetachedHead: true)
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.suggestions.first?.verb == .switchBranch)
        // A read-only Fetch would leave the user just as stuck.
        #expect(!explanation.suggestions.map(\.verb).contains(.fetch))
    }

    @Test("diverged AND dirty leads with Commit so the Pull won't be refused")
    func divergedAndDirtyLeadsWithCommit() {
        let situation = RepoSituation(
            upstreamName: "origin/main", ahead: 1, behind: 2, unstagedCount: 2
        )
        let explanation = DeterministicSituationExplainer.explain(situation)
        // git refuses to pull/merge into a dirty tree → Commit must lead.
        #expect(explanation.suggestions.first?.verb == .commit)
        #expect(explanation.suggestions.map(\.verb).contains(.pull))
        #expect(explanation.text.contains("diverged"))
    }

    @Test("upstream gone is called out")
    func upstreamGone() {
        let situation = RepoSituation(
            branchName: "old",
            upstreamName: "origin/old",
            upstreamGone: true
        )
        let explanation = DeterministicSituationExplainer.explain(situation)
        #expect(explanation.text.contains("server is gone"))
    }

    @Test("every situation yields a non-empty explanation and at least one suggestion")
    func totalityOverEnumeratedShapes() {
        // Exhaustively cover the parked-op enum plus a clean baseline,
        // proving the explainer never returns an empty result.
        var situations = ParkedOperation.allCases.map {
            RepoSituation(branchName: "main", parkedOperation: $0)
        }
        situations.append(RepoSituation(isDetachedHead: true))
        situations.append(RepoSituation(conflictedCount: 1))
        for situation in situations {
            let explanation = DeterministicSituationExplainer.explain(situation)
            #expect(!explanation.text.isEmpty)
            #expect(!explanation.suggestions.isEmpty)
        }
    }
}
