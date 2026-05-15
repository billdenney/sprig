// ConflictKindTests.swift
//
// Pure-function tests for the ConflictKind classifier. No git
// invocation; constructs synthetic `UnmergedEntry` values to exercise
// each classification rule.

@testable import ConflictKit
import Foundation
import GitCore
import Testing

@Suite("ConflictKind — classification rules")
struct ConflictKindTests {
    // Helpers
    private static let shaA = String(repeating: "a", count: 40)
    private static let shaB = String(repeating: "b", count: 40)
    private static let shaC = String(repeating: "c", count: 40)

    private func textEntry(path: String, hasBase: Bool = true) -> UnmergedEntry {
        var stages: [UnmergedStage] = []
        if hasBase {
            stages.append(UnmergedStage(stage: 1, mode: .regularFile, sha: Self.shaA))
        }
        stages.append(UnmergedStage(stage: 2, mode: .regularFile, sha: Self.shaB))
        stages.append(UnmergedStage(stage: 3, mode: .regularFile, sha: Self.shaC))
        return UnmergedEntry(path: path, stages: stages)
    }

    private func submoduleEntry(path: String) -> UnmergedEntry {
        UnmergedEntry(path: path, stages: [
            UnmergedStage(stage: 1, mode: .submodule, sha: Self.shaA),
            UnmergedStage(stage: 2, mode: .submodule, sha: Self.shaB),
            UnmergedStage(stage: 3, mode: .submodule, sha: Self.shaC)
        ])
    }

    // MARK: - Rule precedence

    @Test("submodule mode wins over every other classifier rule")
    func submoduleWinsOverEverything() {
        let entry = submoduleEntry(path: "sub")
        let probes = ConflictProbes(
            isLFSTracked: { _ in true },
            isBinary: { _ in true }
        )
        #expect(ConflictKind.classify(entry, probes: probes) == .submodule)
    }

    @Test("LFS-tracked probe wins over binary probe (LFS UX is more specific)")
    func lfsBeatsBinary() {
        let entry = textEntry(path: "asset.psd")
        let probes = ConflictProbes(
            isLFSTracked: { $0 == "asset.psd" },
            isBinary: { _ in true }
        )
        #expect(ConflictKind.classify(entry, probes: probes) == .lfsPointer)
    }

    @Test("binary probe wins when LFS is not tracked")
    func binaryWhenNotLFS() {
        let entry = textEntry(path: "image.png")
        let probes = ConflictProbes(
            isLFSTracked: { _ in false },
            isBinary: { $0 == "image.png" }
        )
        #expect(ConflictKind.classify(entry, probes: probes) == .binary)
    }

    @Test("addAdd (no base stage) is detected when probes don't match")
    func addAddWhenNoBase() {
        let entry = textEntry(path: "new.txt", hasBase: false)
        #expect(ConflictKind.classify(entry, probes: .none) == .addAdd)
    }

    @Test("text is the default when nothing else matches")
    func textIsDefault() {
        let entry = textEntry(path: "src/x.swift")
        #expect(ConflictKind.classify(entry, probes: .none) == .text)
    }

    @Test("text classification with disabled probes (nil isLFS / isBinary)")
    func textWithNoProbes() {
        let entry = textEntry(path: "src/x.swift")
        let probes = ConflictProbes(isLFSTracked: nil, isBinary: nil)
        #expect(ConflictKind.classify(entry, probes: probes) == .text)
    }

    // MARK: - Bulk classification

    @Test("classifyAll preserves order and per-entry classification")
    func bulkClassifyAll() {
        let entries = [
            textEntry(path: "a.txt"),
            submoduleEntry(path: "sub"),
            textEntry(path: "new.txt", hasBase: false)
        ]
        let probes = ConflictProbes(
            isLFSTracked: nil,
            isBinary: { $0 == "a.txt" }
        )
        let classified = ConflictKind.classifyAll(entries, probes: probes)
        #expect(classified.count == 3)
        #expect(classified.map(\.kind) == [.binary, .submodule, .addAdd])
        #expect(classified.map(\.entry.path) == ["a.txt", "sub", "new.txt"])
    }

    // MARK: - ConflictProbes.none

    @Test("ConflictProbes.none classifies submodule + addAdd but defaults the rest to text")
    func noneProbesShape() {
        let textE = textEntry(path: "x.swift")
        let subE = submoduleEntry(path: "sub")
        let addE = textEntry(path: "y.swift", hasBase: false)
        #expect(ConflictKind.classify(textE, probes: .none) == .text)
        #expect(ConflictKind.classify(subE, probes: .none) == .submodule)
        #expect(ConflictKind.classify(addE, probes: .none) == .addAdd)
    }
}
