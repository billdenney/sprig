// LFSBinaryTypesTests.swift
//
// ADR 0091 — the curated binary-type set + extension matching.

import Foundation
@testable import LFSKit
import Testing

@Suite("LFSBinaryTypes — curated type set + matching")
struct LFSBinaryTypesTests {
    let types = LFSBinaryTypes()

    @Test("matches curated extensions, case-insensitively, across nested paths")
    func matchesCurated() {
        #expect(types.matches(path: "art/logo.psd"))
        #expect(types.matches(path: "Report.DOCX"), "case-insensitive")
        #expect(types.matches(path: "deep/nested/dir/clip.mp4"))
        #expect(types.matches(path: "archive.zip"))
    }

    @Test("does not match text / code / unknown extensions")
    func ignoresNonBinary() {
        for path in ["main.swift", "README.md", "notes.txt", "data.json", "style.css"] {
            #expect(!types.matches(path: path), "\(path) should not match")
        }
    }

    @Test("dotfiles and extension-less names never match")
    func ignoresDotfilesAndExtensionless() {
        #expect(!types.matches(path: ".env"))
        #expect(!types.matches(path: ".gitignore"))
        #expect(!types.matches(path: "Makefile"))
        #expect(!types.matches(path: "bin/tool")) // dir named bin, file has no ext
    }

    @Test("suggestedPattern returns the *.ext glob, lowercased")
    func suggestedPattern() {
        #expect(types.suggestedPattern(for: "art/Logo.PSD") == "*.psd")
        #expect(types.suggestedPattern(for: "x.mp4") == "*.mp4")
        #expect(types.suggestedPattern(for: "main.swift") == nil)
        #expect(types.suggestedPattern(for: "Makefile") == nil)
    }

    @Test("the default set covers the ADR 0091 representative types")
    func defaultSetCoverage() {
        for ext in ["psd", "ai", "sketch", "zip", "iso", "mp4", "mov", "wav", "docx", "xlsx", "pptx", "pdf", "dmg", "bin"] {
            #expect(LFSBinaryTypes.defaultExtensions.contains(ext), "\(ext) should be curated")
        }
    }

    @Test("the type set is injectable — a custom set overrides the default")
    func injectableSet() {
        let custom = LFSBinaryTypes(extensions: ["blend"])
        #expect(custom.matches(path: "scene.blend"))
        #expect(!custom.matches(path: "art.psd"), "custom set replaces the default")
    }
}
