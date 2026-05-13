// DestructiveOpTierTests.swift
//
// Pure-data tests for `DestructiveOpTier` and `UndoBannerPolicy` — slice
// S5 of ADR 0033. No git invocation; the type is policy data, not git.

import Foundation
@testable import SafetyKit
import Testing

@Suite("DestructiveOpTier — tier classification and policy accessors")
struct DestructiveOpTierTests {
    // MARK: - requiresSnapshot

    @Test("requiresSnapshot is false for .low, true for .medium and .high")
    func requiresSnapshotSemantics() {
        #expect(DestructiveOpTier.low.requiresSnapshot == false)
        #expect(DestructiveOpTier.medium.requiresSnapshot == true)
        #expect(DestructiveOpTier.high.requiresSnapshot == true)
    }

    // MARK: - requiresTypedPhrase

    @Test("requiresTypedPhrase is true only for .high")
    func requiresTypedPhraseSemantics() {
        #expect(DestructiveOpTier.low.requiresTypedPhrase == false)
        #expect(DestructiveOpTier.medium.requiresTypedPhrase == false)
        #expect(DestructiveOpTier.high.requiresTypedPhrase == true)
    }

    // MARK: - undoBannerPolicy

    @Test(".low → .none, .medium → .autoDismiss(24h), .high → .persistent")
    func undoBannerPolicySemantics() {
        #expect(DestructiveOpTier.low.undoBannerPolicy == .none)
        #expect(
            DestructiveOpTier.medium.undoBannerPolicy ==
                .autoDismiss(after: .seconds(24 * 60 * 60))
        )
        #expect(DestructiveOpTier.high.undoBannerPolicy == .persistent)
    }

    // MARK: - tier(for:) — registered op tags

    @Test("low-tier op tags map to .low (reset --mixed, unstaged discard)")
    func lowTierLookup() {
        #expect(DestructiveOpTier.tier(for: "reset-mixed") == .low)
        #expect(DestructiveOpTier.tier(for: "discard-unstaged") == .low)
    }

    @Test("medium-tier op tags map to .medium (every medium SnapshotRefName.opXxx constant)")
    func mediumTierLookup() {
        #expect(DestructiveOpTier.tier(for: SnapshotRefName.opMerge) == .medium)
        #expect(DestructiveOpTier.tier(for: SnapshotRefName.opRebase) == .medium)
        #expect(DestructiveOpTier.tier(for: SnapshotRefName.opResetHard) == .medium)
        #expect(DestructiveOpTier.tier(for: SnapshotRefName.opStashDrop) == .medium)
        #expect(DestructiveOpTier.tier(for: SnapshotRefName.opCherryPick) == .medium)
        #expect(DestructiveOpTier.tier(for: SnapshotRefName.opRevert) == .medium)
        #expect(DestructiveOpTier.tier(for: SnapshotRefName.opBranchDelete) == .medium)
        #expect(DestructiveOpTier.tier(for: SnapshotRefName.opCheckoutDirty) == .medium)
    }

    @Test("high-tier op tags map to .high (force-push and friends)")
    func highTierLookup() {
        #expect(DestructiveOpTier.tier(for: SnapshotRefName.opForcePush) == .high)
    }

    // MARK: - tier(for:) — fail-closed semantics

    @Test("unknown op-tags return nil (fail-closed, no silent .low default)")
    func unknownOpReturnsNil() {
        #expect(DestructiveOpTier.tier(for: "totally-unregistered-op") == nil)
        #expect(DestructiveOpTier.tier(for: "") == nil)
        // Even syntactically valid op-tags with no tier classification fail closed.
        // SnapshotRefName.isValidOp would accept this, but DestructiveOpTier.tier(for:)
        // must reject it until a tier is decided.
        #expect(SnapshotRefName.isValidOp("filter-repo"))
        #expect(
            DestructiveOpTier.tier(for: "filter-repo") == nil,
            "filter-repo is a future-tier op — must require explicit classification before use"
        )
    }

    // MARK: - CaseIterable + Equatable

    @Test("DestructiveOpTier exposes all three cases via CaseIterable")
    func caseIterableShape() {
        let all = DestructiveOpTier.allCases
        #expect(all.count == 3)
        #expect(all.contains(.low))
        #expect(all.contains(.medium))
        #expect(all.contains(.high))
    }

    @Test("DestructiveOpTier is Hashable — usable as a dictionary key")
    func hashableUsage() {
        let counts: [DestructiveOpTier: Int] = [.low: 1, .medium: 2, .high: 3]
        #expect(counts[.low] == 1)
        #expect(counts[.medium] == 2)
        #expect(counts[.high] == 3)
    }

    // MARK: - UndoBannerPolicy

    @Test("UndoBannerPolicy is Hashable and value-equal on its associated values")
    func undoBannerPolicyEquality() {
        let a: UndoBannerPolicy = .autoDismiss(after: .seconds(10))
        let b: UndoBannerPolicy = .autoDismiss(after: .seconds(10))
        let c: UndoBannerPolicy = .autoDismiss(after: .seconds(20))
        #expect(a == b)
        #expect(a != c)
        #expect(UndoBannerPolicy.none == .none)
        #expect(UndoBannerPolicy.persistent == .persistent)
        #expect(UndoBannerPolicy.none != .persistent)

        let set: Set<UndoBannerPolicy> = [a, b, c, .none, .persistent]
        #expect(set.count == 4, "a and b dedupe; c, .none, .persistent are distinct")
    }
}
