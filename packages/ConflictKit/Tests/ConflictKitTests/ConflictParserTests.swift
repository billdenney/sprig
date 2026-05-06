@testable import ConflictKit
import Testing

@Suite("ConflictParser — git marker layouts")
struct ConflictParserTests {
    // MARK: - Empty / clean input

    @Test("empty input produces no regions")
    func empty() {
        #expect(ConflictParser.parse("").isEmpty)
    }

    @Test("clean input with no markers produces no regions")
    func cleanInput() {
        let source = """
        line 1
        line 2
        line 3
        """
        #expect(ConflictParser.parse(source).isEmpty)
    }

    // MARK: - Standard 2-way conflict

    @Test("classic 2-way conflict parses ours / theirs and labels")
    func classic2Way() {
        let source = """
        before
        <<<<<<< HEAD
        ours line 1
        ours line 2
        =======
        theirs line 1
        >>>>>>> feature-branch
        after
        """
        let regions = ConflictParser.parse(source)
        #expect(regions.count == 1)
        let region = regions[0]
        #expect(region.oursLabel == "HEAD")
        #expect(region.baseLabel == nil)
        #expect(region.theirsLabel == "feature-branch")
        #expect(region.ours == ["ours line 1", "ours line 2"])
        #expect(region.base == nil)
        #expect(region.theirs == ["theirs line 1"])
        // Lines 2 (`<<<`) through 7 (`>>>`) — 1-indexed inclusive.
        #expect(region.lineRange == 2 ... 7)
    }

    @Test("multiple conflict regions in the same file are all parsed")
    func multipleRegions() {
        let source = """
        <<<<<<< HEAD
        first ours
        =======
        first theirs
        >>>>>>> branch-a
        middle
        <<<<<<< HEAD
        second ours
        =======
        second theirs
        >>>>>>> branch-b
        """
        let regions = ConflictParser.parse(source)
        #expect(regions.count == 2)
        #expect(regions[0].theirsLabel == "branch-a")
        #expect(regions[0].ours == ["first ours"])
        #expect(regions[0].theirs == ["first theirs"])
        #expect(regions[1].theirsLabel == "branch-b")
        #expect(regions[1].ours == ["second ours"])
        #expect(regions[1].theirs == ["second theirs"])
    }

    @Test("empty ours / theirs sections parse to empty arrays")
    func emptySections() {
        let source = """
        <<<<<<< HEAD
        =======
        only theirs
        >>>>>>> branch
        """
        let regions = ConflictParser.parse(source)
        #expect(regions.count == 1)
        #expect(regions[0].ours.isEmpty)
        #expect(regions[0].theirs == ["only theirs"])
    }

    // MARK: - diff3 layout

    @Test("diff3 conflict parses the base section and label")
    func diff3Layout() {
        let source = """
        <<<<<<< HEAD
        ours
        ||||||| merged common ancestors
        base content
        line 2 of base
        =======
        theirs
        >>>>>>> feature
        """
        let regions = ConflictParser.parse(source)
        #expect(regions.count == 1)
        let region = regions[0]
        #expect(region.oursLabel == "HEAD")
        #expect(region.baseLabel == "merged common ancestors")
        #expect(region.theirsLabel == "feature")
        #expect(region.ours == ["ours"])
        #expect(region.base == ["base content", "line 2 of base"])
        #expect(region.theirs == ["theirs"])
    }

    @Test("diff3 with empty base section parses with base == []")
    func diff3EmptyBase() {
        let source = """
        <<<<<<< HEAD
        ours
        ||||||| base-label
        =======
        theirs
        >>>>>>> feature
        """
        let regions = ConflictParser.parse(source)
        #expect(regions.count == 1)
        let region = regions[0]
        #expect(region.baseLabel == "base-label")
        #expect(region.base == [])
    }

    // MARK: - Marker labels

    @Test("unlabeled markers parse to empty-string labels")
    func unlabeledMarkers() {
        let source = """
        <<<<<<<
        ours
        =======
        theirs
        >>>>>>>
        """
        let regions = ConflictParser.parse(source)
        #expect(regions.count == 1)
        #expect(regions[0].oursLabel == "")
        #expect(regions[0].theirsLabel == "")
    }

    @Test("labels containing spaces and special chars are captured verbatim")
    func labelsWithWeirdChars() {
        let source = """
        <<<<<<< some commit subject (12abc34)
        ours
        =======
        theirs
        >>>>>>> origin/feature/foo bar
        """
        let regions = ConflictParser.parse(source)
        #expect(regions.count == 1)
        #expect(regions[0].oursLabel == "some commit subject (12abc34)")
        #expect(regions[0].theirsLabel == "origin/feature/foo bar")
    }

    // MARK: - Malformed input

    @Test("a leading <<<<<<< with no closing >>>>>>> is silently dropped")
    func unterminatedRegionSkipped() {
        let source = """
        before
        <<<<<<< HEAD
        ours
        =======
        theirs but no end marker
        """
        #expect(ConflictParser.parse(source).isEmpty)
    }

    @Test("a leading <<<<<<< with no ======= is silently dropped")
    func noTheirsMarkerSkipped() {
        let source = """
        <<<<<<< HEAD
        ours
        >>>>>>> feature
        """
        #expect(ConflictParser.parse(source).isEmpty)
    }

    @Test("malformed region followed by a well-formed one — only the well-formed parses")
    func mixedMalformedAndWellFormed() {
        let source = """
        <<<<<<< HEAD
        bad region with no end
        and more
        <<<<<<< HEAD
        good ours
        =======
        good theirs
        >>>>>>> feature
        """
        // The first `<<<` opens a region that runs into a nested
        // `<<<` before any `=======` — parser abandons the outer
        // region, restarts at the nested `<<<`, and parses the
        // well-formed inner region cleanly. This recovery matters in
        // practice: a half-resolved merge often has stray markers
        // from earlier conflict-resolution attempts that we don't
        // want to drop the rest of the file for.
        let regions = ConflictParser.parse(source)
        #expect(regions.count == 1)
        #expect(regions[0].ours == ["good ours"])
        #expect(regions[0].theirs == ["good theirs"])
        #expect(regions[0].theirsLabel == "feature")
    }

    // MARK: - Marker prefix matcher

    @Test("matchMarker returns the trailing label after a single space")
    func matchMarkerLabel() {
        #expect(ConflictParser.matchMarker("<<<<<<< HEAD", prefix: ConflictParser.oursMarker) == "HEAD")
        #expect(ConflictParser.matchMarker("<<<<<<<", prefix: ConflictParser.oursMarker) == "")
    }

    @Test("matchMarker rejects lines that don't match the exact marker")
    func matchMarkerRejectsNonMatching() {
        #expect(ConflictParser.matchMarker("hello", prefix: ConflictParser.oursMarker) == nil)
        // Indented marker: not at column 0, rejected.
        #expect(ConflictParser.matchMarker("  <<<<<<<", prefix: ConflictParser.oursMarker) == nil)
        // 8-char marker isn't a valid 7-char marker — we don't match a longer
        // run as "marker plus content," conservative against typos.
        #expect(ConflictParser.matchMarker("<<<<<<<<", prefix: ConflictParser.oursMarker) == nil)
        // Marker without the required space separator before the label.
        #expect(ConflictParser.matchMarker("<<<<<<<HEAD", prefix: ConflictParser.oursMarker) == nil)
    }
}
