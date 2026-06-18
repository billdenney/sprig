import Foundation
@testable import SafetyKit
import Testing

@Suite("SnapshotRefName format + parser")
struct SnapshotRefNameTests {
    /// Build a UTC `Date` from explicit components without forcing
    /// the unwrap on `Calendar.date(from:)`. Bad components produce
    /// `Date.distantPast`, which is a clearly-wrong sentinel that
    /// makes any downstream test assertion fail loudly rather than
    /// silently pass.
    static func utcDate(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components) ?? .distantPast
    }

    /// Reference instant used across the format / parse tests:
    /// 2026-05-06 03:12:34 UTC.
    static let referenceDate = utcDate(year: 2026, month: 5, day: 6, hour: 3, minute: 12, second: 34)

    @Test("refName has the canonical refs/sprig/snapshots/<ts>/<op> shape")
    func refNameShape() throws {
        let ref = try #require(
            SnapshotRefName(timestamp: Self.referenceDate, op: SnapshotRefName.opMerge)
        )
        #expect(ref.refName == "refs/sprig/snapshots/20260506T031234Z/merge")
    }

    @Test("formatTimestamp pads single-digit fields with zeros")
    func timestampPadding() {
        let date = Self.utcDate(year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5)
        #expect(SnapshotRefName.formatTimestamp(date) == "20260102T030405Z")
    }

    @Test("round-trip: format → parse yields the original components")
    func roundTrip() throws {
        let original = try #require(
            SnapshotRefName(timestamp: Self.referenceDate, op: SnapshotRefName.opRebase)
        )
        let parsed = try #require(SnapshotRefName.parse(original.refName))
        #expect(parsed.op == original.op)
        #expect(parsed.timestamp == original.timestamp)
        #expect(parsed.refName == original.refName)
    }

    @Test("parse accepts every documented known-op constant")
    func knownOpsAllValid() throws {
        let knownOps: [String] = [
            SnapshotRefName.opMerge,
            SnapshotRefName.opRebase,
            SnapshotRefName.opResetHard,
            SnapshotRefName.opStashDrop,
            SnapshotRefName.opForcePush,
            SnapshotRefName.opCherryPick,
            SnapshotRefName.opRevert,
            SnapshotRefName.opBranchDelete,
            SnapshotRefName.opCheckoutDirty
        ]
        for op in knownOps {
            #expect(SnapshotRefName.isValidOp(op), "\(op) should be a valid op")
            let ref = try #require(SnapshotRefName(timestamp: Self.referenceDate, op: op))
            let parsed = try #require(SnapshotRefName.parse(ref.refName))
            #expect(parsed.op == op)
        }
    }

    @Test("uniquifier op suffixes (merge-2, reset-hard-3) are valid and round-trip")
    func uniquifierSuffixesRoundTrip() throws {
        // SnapshotWriter's same-second collision handling appends -2/-3/…
        // to the op segment; those names must stay valid ops and survive
        // a parse round trip so the read path can enumerate them.
        for op in ["merge-2", "merge-3", "reset-hard-2", "force-push-10"] {
            #expect(SnapshotRefName.isValidOp(op), "\(op) is the documented uniquifier shape")
            let ref = try #require(SnapshotRefName(timestamp: Self.referenceDate, op: op))
            let parsed = try #require(SnapshotRefName.parse(ref.refName))
            #expect(parsed.op == op)
        }
    }

    @Test("baseOp strips a trailing -<digits> uniquifier but leaves real ops intact")
    func baseOpStripsUniquifier() throws {
        func op(_ s: String) throws -> SnapshotRefName {
            try #require(SnapshotRefName(timestamp: Self.referenceDate, op: s))
        }
        // Uniquified ops collapse to their base (the Recover classifier
        // relies on this to route stash-drop-2 like stash-drop).
        #expect(try op("stash-drop-2").baseOp == "stash-drop")
        #expect(try op("merge-2").baseOp == "merge")
        #expect(try op("merge-10").baseOp == "merge")
        // Real ops that contain a dash but no numeric suffix are untouched.
        #expect(try op("merge").baseOp == "merge")
        #expect(try op("reset-hard").baseOp == "reset-hard")
        #expect(try op("force-push").baseOp == "force-push")
        #expect(try op("branch-delete").baseOp == "branch-delete")
        #expect(try op("checkout-dirty").baseOp == "checkout-dirty")
    }

    @Test("two snapshots one second apart sort lexicographically by time")
    func lexicographicOrderMatchesChronological() throws {
        let earlier = Self.referenceDate
        let later = earlier.addingTimeInterval(1)
        let earlierRef = try #require(SnapshotRefName(timestamp: earlier, op: "merge"))
        let laterRef = try #require(SnapshotRefName(timestamp: later, op: "merge"))
        #expect(earlierRef.refName < laterRef.refName)
    }

    // MARK: - Parse rejection cases

    @Test("parse rejects names without the snapshots prefix")
    func parseRejectsMissingPrefix() {
        #expect(SnapshotRefName.parse("refs/heads/main") == nil)
        #expect(SnapshotRefName.parse("refs/sprig/other/20260506T031234Z/merge") == nil)
        #expect(SnapshotRefName.parse("20260506T031234Z/merge") == nil)
    }

    @Test("parse rejects names missing the op segment")
    func parseRejectsMissingOp() {
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260506T031234Z") == nil)
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260506T031234Z/") == nil)
    }

    @Test("parse rejects names with extra path segments after the op")
    func parseRejectsExtraSegments() {
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260506T031234Z/merge/extra") == nil)
    }

    @Test("parse rejects malformed timestamps")
    func parseRejectsMalformedTimestamps() {
        // Wrong length.
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/2026/merge") == nil)
        // Missing T separator.
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260506X031234Z/merge") == nil)
        // Missing Z trailer.
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260506T031234N/merge") == nil)
        // Non-numeric date components.
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/abcdefghTabcdefZ/merge") == nil)
        // Calendar-invalid (Feb 30).
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260230T120000Z/merge") == nil)
    }

    @Test("parse rejects invalid op tags")
    func parseRejectsInvalidOps() {
        // Uppercase.
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260506T031234Z/Merge") == nil)
        // Underscore (not in the allowed alphabet).
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260506T031234Z/merge_one") == nil)
        // Starts with a digit.
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260506T031234Z/1merge") == nil)
        // Starts with a dash.
        #expect(SnapshotRefName.parse("refs/sprig/snapshots/20260506T031234Z/-merge") == nil)
    }

    // MARK: - isValidOp coverage

    @Test("isValidOp accepts well-formed tags")
    func isValidOpAccepts() {
        #expect(SnapshotRefName.isValidOp("a"))
        #expect(SnapshotRefName.isValidOp("merge"))
        #expect(SnapshotRefName.isValidOp("reset-hard"))
        #expect(SnapshotRefName.isValidOp("op-with-digits-123"))
        #expect(SnapshotRefName.isValidOp(String(repeating: "a", count: 64)))
    }

    @Test("isValidOp rejects malformed tags")
    func isValidOpRejects() {
        #expect(!SnapshotRefName.isValidOp(""))
        #expect(!SnapshotRefName.isValidOp(String(repeating: "a", count: 65)))
        #expect(!SnapshotRefName.isValidOp("Merge"))
        #expect(!SnapshotRefName.isValidOp("merge_op"))
        #expect(!SnapshotRefName.isValidOp("merge op"))
        #expect(!SnapshotRefName.isValidOp("-merge"))
        #expect(!SnapshotRefName.isValidOp("1merge"))
        #expect(!SnapshotRefName.isValidOp("merge/sub"))
        #expect(!SnapshotRefName.isValidOp("café"))
    }

    @Test("init returns nil for invalid op")
    func initRejectsInvalidOp() {
        #expect(SnapshotRefName(timestamp: Self.referenceDate, op: "") == nil)
        #expect(SnapshotRefName(timestamp: Self.referenceDate, op: "Bad Op") == nil)
    }
}
