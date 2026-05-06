@testable import ConflictKit
import Testing

@Suite("ConflictedFile.applying — splice resolutions back into source")
struct ConflictedFileTests {
    // MARK: - Round-trip / clean

    @Test("a clean file has no regions and applying([]) returns the source unchanged")
    func cleanFileRoundTrip() throws {
        let source = "alpha\nbeta\ngamma\n"
        let file = ConflictedFile(source: source)
        #expect(file.isClean)
        #expect(file.regions.isEmpty)
        #expect(try file.applying([]) == source)
    }

    @Test("empty source applies cleanly to empty output")
    func emptySource() throws {
        let file = ConflictedFile(source: "")
        #expect(try file.applying([]) == "")
    }

    // MARK: - Single-region resolutions

    private static let twoWayConflict = """
    before
    <<<<<<< HEAD
    ours line 1
    ours line 2
    =======
    theirs line 1
    >>>>>>> feature
    after
    """

    @Test("apply .ours replaces the region with ours-side lines")
    func applyOurs() throws {
        let file = ConflictedFile(source: Self.twoWayConflict)
        #expect(file.regions.count == 1)
        let resolved = try file.applying([.ours])
        #expect(resolved == "before\nours line 1\nours line 2\nafter")
    }

    @Test("apply .theirs replaces the region with theirs-side lines")
    func applyTheirs() throws {
        let file = ConflictedFile(source: Self.twoWayConflict)
        let resolved = try file.applying([.theirs])
        #expect(resolved == "before\ntheirs line 1\nafter")
    }

    @Test("apply .custom replaces the region with arbitrary user lines")
    func applyCustom() throws {
        let file = ConflictedFile(source: Self.twoWayConflict)
        let resolved = try file.applying([.custom(["resolved line 1", "resolved line 2", "resolved line 3"])])
        #expect(resolved == "before\nresolved line 1\nresolved line 2\nresolved line 3\nafter")
    }

    @Test("apply .custom with empty array drops the region entirely")
    func applyCustomEmpty() throws {
        let file = ConflictedFile(source: Self.twoWayConflict)
        let resolved = try file.applying([.custom([])])
        #expect(resolved == "before\nafter")
    }

    @Test("apply .unresolved keeps the region's marker block verbatim")
    func applyUnresolved() throws {
        let file = ConflictedFile(source: Self.twoWayConflict)
        let resolved = try file.applying([.unresolved])
        #expect(resolved == Self.twoWayConflict)
    }

    // MARK: - diff3 / base

    private static let diff3Conflict = """
    head
    <<<<<<< HEAD
    ours
    ||||||| ancestor
    base
    =======
    theirs
    >>>>>>> feature
    tail
    """

    @Test("apply .base on a diff3 region restores the base content")
    func applyBaseDiff3() throws {
        let file = ConflictedFile(source: Self.diff3Conflict)
        let resolved = try file.applying([.base])
        #expect(resolved == "head\nbase\ntail")
    }

    @Test("apply .base on a 2-way region throws baseRequestedButMissing")
    func applyBaseOnTwoWayThrows() {
        let file = ConflictedFile(source: Self.twoWayConflict)
        #expect(throws: ConflictResolutionError.baseRequestedButMissing(regionIndex: 0)) {
            try file.applying([.base])
        }
    }

    // MARK: - Multi-region

    @Test("multi-region file applies a resolution per region in order")
    func multiRegion() throws {
        let source = """
        <<<<<<< HEAD
        first ours
        =======
        first theirs
        >>>>>>> branch-a
        between
        <<<<<<< HEAD
        second ours
        =======
        second theirs
        >>>>>>> branch-b
        end
        """
        let file = ConflictedFile(source: source)
        #expect(file.regions.count == 2)
        let resolved = try file.applying([.ours, .theirs])
        #expect(resolved == "first ours\nbetween\nsecond theirs\nend")
    }

    @Test("multi-region with mixed resolutions including .unresolved")
    func multiRegionMixed() throws {
        let source = """
        <<<<<<< HEAD
        a-ours
        =======
        a-theirs
        >>>>>>> A
        middle
        <<<<<<< HEAD
        b-ours
        =======
        b-theirs
        >>>>>>> B
        """
        let file = ConflictedFile(source: source)
        let resolved = try file.applying([.ours, .unresolved])
        #expect(resolved == """
        a-ours
        middle
        <<<<<<< HEAD
        b-ours
        =======
        b-theirs
        >>>>>>> B
        """)
    }

    // MARK: - Validation errors

    @Test("applying too few resolutions throws resolutionCountMismatch")
    func tooFewResolutions() {
        let file = ConflictedFile(source: Self.twoWayConflict)
        #expect(
            throws: ConflictResolutionError.resolutionCountMismatch(expected: 1, got: 0)
        ) {
            try file.applying([])
        }
    }

    @Test("applying too many resolutions throws resolutionCountMismatch")
    func tooManyResolutions() {
        let file = ConflictedFile(source: Self.twoWayConflict)
        #expect(
            throws: ConflictResolutionError.resolutionCountMismatch(expected: 1, got: 2)
        ) {
            try file.applying([.ours, .theirs])
        }
    }

    // MARK: - Trailing-newline preservation

    @Test("source with trailing newline keeps it after splicing")
    func trailingNewlinePreserved() throws {
        let source = """
        before
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> feature
        after

        """ // ends with \n
        let file = ConflictedFile(source: source)
        let resolved = try file.applying([.ours])
        #expect(resolved.hasSuffix("\n"))
        #expect(resolved == "before\nours\nafter\n")
    }

    @Test("source without trailing newline keeps it absent after splicing")
    func noTrailingNewlinePreserved() throws {
        let file = ConflictedFile(source: Self.twoWayConflict) // no trailing \n
        let resolved = try file.applying([.ours])
        #expect(!resolved.hasSuffix("\n"))
    }

    // MARK: - Pre-parsed regions initializer

    @Test("init(source:regions:) skips parsing and uses the supplied regions")
    func directInit() throws {
        let parsed = ConflictParser.parse(Self.twoWayConflict)
        let file = ConflictedFile(source: Self.twoWayConflict, regions: parsed)
        let resolved = try file.applying([.theirs])
        #expect(resolved == "before\ntheirs line 1\nafter")
    }
}
