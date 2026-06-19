import Foundation
import GitCore
@testable import SubmoduleKit
import Testing

@Suite("SubmoduleSuggestionThrottle — per-repo last-shown store")
struct SubmoduleSuggestionThrottleTests {
    /// A clock the test advances by hand, so the throttle window is
    /// exercised without sleeping.
    private final class ScriptedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) {
            current = start
        }

        func now() -> Date {
            lock.withLock { current }
        }

        func advance(hours: Double) {
            lock.withLock { current += hours * 3600 }
        }
    }

    private func makeRepo() async throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-skit-throttle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(defaultWorkingDirectory: dir)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "x@test"])
        _ = try await runner.run(["config", "user.name", "x"])
        _ = try await runner.run(["config", "commit.gpgsign", "false"])
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("x.txt"))
        _ = try await runner.run(["add", "x.txt"])
        _ = try await runner.run(["commit", "-m", "x"])
        return dir.standardized
    }

    @Test("fires when never shown, then suppressed within the window, then fires again after")
    func firesSuppressesThenFiresAgain() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        let clock = ScriptedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let throttle = SubmoduleSuggestionThrottle(runner: runner, clock: { clock.now() })

        // Never shown → may show.
        #expect(try await throttle.mayShow(throttleHours: 4))

        // Record now; within the 4h window it's suppressed.
        try await throttle.recordShown()
        #expect(try await throttle.mayShow(throttleHours: 4) == false)
        clock.advance(hours: 3.9)
        #expect(try await throttle.mayShow(throttleHours: 4) == false)

        // Past the window it fires again.
        clock.advance(hours: 0.2) // now 4.1h elapsed
        #expect(try await throttle.mayShow(throttleHours: 4))
    }

    @Test("recordShown persists across a fresh throttle instance")
    func persistsAcrossInstances() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        let clock = ScriptedClock(Date(timeIntervalSince1970: 1_700_000_000))

        let first = SubmoduleSuggestionThrottle(runner: runner, clock: { clock.now() })
        try await first.recordShown()

        // A brand-new instance reads the on-disk timestamp.
        let second = SubmoduleSuggestionThrottle(runner: runner, clock: { clock.now() })
        #expect(try await second.mayShow(throttleHours: 4) == false)
        let stored = try await second.lastShownTimestamp()
        #expect(stored == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("the store file lands under <git-common-dir>/sprig/")
    func storeLandsUnderGitDir() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        let throttle = SubmoduleSuggestionThrottle(runner: runner)
        try await throttle.recordShown()

        let expected = dir
            .appendingPathComponent(".git")
            .appendingPathComponent(SubmoduleSuggestionThrottle.stateSubdirectory)
            .appendingPathComponent(SubmoduleSuggestionThrottle.fileName)
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test("throttleHours <= 0 disables throttling")
    func nonPositiveHoursDisablesThrottle() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        let throttle = SubmoduleSuggestionThrottle(runner: runner)
        try await throttle.recordShown()
        // Even immediately after recording, a non-positive window always
        // permits the suggestion.
        #expect(try await throttle.mayShow(throttleHours: 0))
    }

    @Test("missing store file reads as never-shown")
    func missingFileIsNeverShown() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(defaultWorkingDirectory: dir)
        let throttle = SubmoduleSuggestionThrottle(runner: runner)
        #expect(try await throttle.lastShownTimestamp() == nil)
        #expect(try await throttle.mayShow(throttleHours: 4))
    }
}
