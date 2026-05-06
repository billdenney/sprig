// SnapshotIndexTestSupport.swift
//
// Shared fixtures for `SnapshotIndexTests` + `SnapshotIndexPruneTests`.
// Pulled out so the test struct in either file stays under SwiftLint's
// `type_body_length` cap as the SnapshotIndex surface grows.

import Foundation
import GitCore
import SafetyKit

enum SnapshotIndexTestSupport {
    /// Build a tempdir, `git init` it with deterministic config, and
    /// return the path + a Runner pointed at it.
    static func mkRepo(_ tag: String) async throws -> (URL, Runner) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-snapshot-index-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "test@sprig.app"])
        _ = try await runner.run(["config", "user.name", "Sprig Test"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        return (tmp, runner)
    }

    /// Drop a single committed file into the repo so HEAD resolves.
    static func seedCommit(at repo: URL, runner: Runner) async throws {
        try Data("seed\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        _ = try await runner.run(["add", "a.txt"])
        _ = try await runner.run(["commit", "-m", "seed"])
    }

    /// Write a snapshot ref via `git update-ref` directly. Mirrors what
    /// `SafetyKit.SnapshotWriter` will do once it merges; using the raw
    /// form here keeps these tests independent of that branch.
    @discardableResult
    static func writeSnapshot(
        at timestamp: Date,
        op: String,
        runner: Runner,
        target: String = "HEAD"
    ) async throws -> SnapshotRefName {
        guard let name = SnapshotRefName(timestamp: timestamp, op: op) else {
            throw SnapshotIndexTestError.invalidRefName(timestamp: timestamp, op: op)
        }
        _ = try await runner.run(["update-ref", name.refName, target])
        return name
    }

    /// Build a UTC `Date` from explicit components without forcing the
    /// unwrap on `Calendar.date(from:)`. Bad components produce
    /// `Date.distantPast`, a clearly-wrong sentinel that makes any
    /// downstream test assertion fail loudly rather than silently pass.
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
}

enum SnapshotIndexTestError: Error {
    case invalidRefName(timestamp: Date, op: String)
}
