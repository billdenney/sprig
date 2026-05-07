@testable import ConflictKit
import Testing

@Suite("AutoResolution — heuristic per-region resolutions")
struct AutoResolutionTests {
    private func region(
        ours: [String],
        theirs: [String],
        base: [String]? = nil
    ) -> ConflictRegion {
        ConflictRegion(
            oursLabel: "HEAD",
            baseLabel: base.map { _ in "ancestor" },
            theirsLabel: "feature",
            ours: ours,
            base: base,
            theirs: theirs,
            lineRange: 1 ... (3 + ours.count + theirs.count + (base?.count ?? 0))
        )
    }

    // MARK: - .identical

    @Test("identical ours/theirs auto-resolves to .ours under .identical")
    func identicalMatches() {
        let r = region(ours: ["alpha", "beta"], theirs: ["alpha", "beta"])
        #expect(r.autoResolution(strategies: [.identical]) == .ours)
    }

    @Test("differing ours/theirs returns nil under .identical")
    func differingDoesNotMatch() {
        let r = region(ours: ["alpha"], theirs: ["beta"])
        #expect(r.autoResolution(strategies: [.identical]) == nil)
    }

    @Test("empty strategy set never matches")
    func emptyStrategiesNeverMatch() {
        let r = region(ours: ["x"], theirs: ["x"])
        #expect(r.autoResolution(strategies: []) == nil)
    }

    // MARK: - .whitespaceOnly

    @Test("trailing-whitespace difference matches under .whitespaceOnly only")
    func trailingWhitespace() {
        let r = region(ours: ["hello ", "world"], theirs: ["hello", "world"])
        // .identical alone — no match (lines aren't byte-equal).
        #expect(r.autoResolution(strategies: [.identical]) == nil)
        // With .whitespaceOnly — match.
        #expect(r.autoResolution(strategies: [.whitespaceOnly]) == .ours)
        // Combined set — also match.
        #expect(r.autoResolution(strategies: [.identical, .whitespaceOnly]) == .ours)
    }

    @Test("leading-whitespace difference matches under .whitespaceOnly")
    func leadingWhitespace() {
        let r = region(ours: ["    hello"], theirs: ["\thello"])
        #expect(r.autoResolution(strategies: [.whitespaceOnly]) == .ours)
    }

    @Test("differences in non-whitespace characters don't match .whitespaceOnly")
    func realContentDifferenceNoMatch() {
        let r = region(ours: ["hello"], theirs: ["world"])
        #expect(r.autoResolution(strategies: [.whitespaceOnly]) == nil)
    }

    @Test("internal-whitespace difference doesn't match (only leading/trailing strip)")
    func internalWhitespaceNoMatch() {
        // "hello world" vs "hello  world" — internal whitespace differs;
        // trimmingCharacters(in: .whitespaces) only affects ends, so
        // these stay distinct after trim.
        let r = region(ours: ["hello world"], theirs: ["hello  world"])
        #expect(r.autoResolution(strategies: [.whitespaceOnly]) == nil)
    }

    @Test("different line count never matches whitespaceOnly")
    func differentLineCount() {
        let r = region(ours: ["one", "two"], theirs: ["one"])
        #expect(r.autoResolution(strategies: [.whitespaceOnly]) == nil)
        #expect(r.autoResolution(strategies: [.identical]) == nil)
    }

    // MARK: - File-level helpers

    @Test("autoResolutions returns one resolution per region with .unresolved fallback")
    func autoResolutionsAcrossRegions() {
        let source = """
        <<<<<<< HEAD
        same
        =======
        same
        >>>>>>> A
        middle
        <<<<<<< HEAD
        ours-only
        =======
        theirs-only
        >>>>>>> B
        """
        let file = ConflictedFile(source: source)
        #expect(file.regions.count == 2)
        let res = file.autoResolutions(strategies: [.identical])
        #expect(res.count == 2)
        #expect(res[0] == .ours) // identical content
        #expect(res[1] == .unresolved) // genuine divergence
    }

    @Test("isFullyAutoResolvable returns true only when every region matches")
    func fullyAutoResolvable() {
        let allMatchSource = """
        <<<<<<< HEAD
        same
        =======
        same
        >>>>>>> A
        middle
        <<<<<<< HEAD
        also same
        =======
        also same
        >>>>>>> B
        """
        let mixedSource = """
        <<<<<<< HEAD
        same
        =======
        same
        >>>>>>> A
        middle
        <<<<<<< HEAD
        ours-only
        =======
        theirs-only
        >>>>>>> B
        """
        let allMatch = ConflictedFile(source: allMatchSource)
        let mixed = ConflictedFile(source: mixedSource)
        #expect(allMatch.isFullyAutoResolvable(strategies: [.identical]))
        #expect(!mixed.isFullyAutoResolvable(strategies: [.identical]))
    }

    @Test("autoResolutions composes with applying to produce a clean file")
    func endToEndAutoResolveAndApply() throws {
        let source = """
        head
        <<<<<<< HEAD
        line a
        line b
        =======
        line a
        line b
        >>>>>>> feature
        between
        <<<<<<< HEAD
            indented
        =======
        indented
        >>>>>>> feature
        tail
        """
        let file = ConflictedFile(source: source)
        let resolutions = file.autoResolutions(strategies: [.identical, .whitespaceOnly])
        #expect(resolutions == [.ours, .ours])
        let resolved = try file.applying(resolutions)
        #expect(resolved == """
        head
        line a
        line b
        between
            indented
        tail
        """)
    }
}
