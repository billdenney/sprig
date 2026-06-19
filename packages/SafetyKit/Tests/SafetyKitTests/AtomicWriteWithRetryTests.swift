// AtomicWriteWithRetryTests.swift
//
// ADR 0090 — the Windows-tolerant atomic write helper that every
// working-tree write in SafetyKit/TaskWindowKit routes through. The
// load-bearing claims here are the platform-agnostic ones (the Windows
// retry path only triggers under a real `MoveFileEx` sharing violation,
// which we can't reproduce on hosted POSIX CI): bytes land exactly for
// text and binary, an existing file is fully replaced (no torn tail of
// the old content), and a directory that doesn't exist yet is a hard
// failure rather than a silent miss.

import Foundation
@testable import SafetyKit
import Testing

@Suite("AtomicWriteWithRetry — working-tree write helper")
struct AtomicWriteWithRetryTests {
    private func tempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-atomicwrite-\(label)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Data overload writes the exact bytes to a fresh path")
    func writesDataExactly() async throws {
        let dir = try tempDir("data")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.txt")

        try await AtomicWriteWithRetry.run(Data("hello\n".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("hello\n".utf8))
    }

    @Test("String overload UTF-8 encodes then writes")
    func writesStringExactly() async throws {
        let dir = try tempDir("string")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.txt")

        try await AtomicWriteWithRetry.run("héllo — ☕️\n", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "héllo — ☕️\n")
    }

    @Test("overwriting longer content with shorter leaves only the new bytes (atomic replace, no torn tail)")
    func atomicReplaceLeavesNoTail() async throws {
        let dir = try tempDir("replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.txt")

        try await AtomicWriteWithRetry.run(Data("a long original line\n".utf8), to: url)
        try await AtomicWriteWithRetry.run(Data("short\n".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("short\n".utf8))
    }

    @Test("binary content with NUL/high bytes round-trips byte-for-byte")
    func writesBinaryExactly() async throws {
        let dir = try tempDir("binary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blob.bin")
        let bytes = Data([0x00, 0x01, 0xFF, 0x00, 0x7F, 0x80])

        try await AtomicWriteWithRetry.run(bytes, to: url)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("a non-existent parent directory throws (the caller must create it first)")
    func missingParentThrows() async throws {
        let dir = try tempDir("noparent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("does/not/exist/out.txt")

        await #expect(throws: (any Error).self) {
            // Single attempt: the failure is a missing-directory error,
            // not the `.fileWriteNoPermission` the retry loop absorbs, so
            // it surfaces immediately rather than backing off ~64 s.
            try await AtomicWriteWithRetry.run(Data("x".utf8), to: url, attempts: 1)
        }
    }
}
