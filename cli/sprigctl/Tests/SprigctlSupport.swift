import Foundation
import GitCore // for ProcessTerminationGate

/// Test helpers shared across the sprigctl test suites. Kept namespaced
/// in an enum so they can be invoked as `Sprigctl.run(...)` without one
/// big test struct that trips SwiftLint's type-body-length cap.
enum Sprigctl {
    struct Captured {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    struct BinaryNotFound: Error {}

    /// Locate the built sprigctl binary. Walks up from cwd to find
    /// `Package.swift`, then probes `.build/{debug,release}/sprigctl[.exe]`.
    /// Honors the `SPRIGCTL_BIN` env override when set.
    static func locateBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["SPRIGCTL_BIN"] {
            return URL(fileURLWithPath: override)
        }
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0 ..< 10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        #if os(Windows)
            let exeNames = ["sprigctl.exe", "sprigctl"]
        #else
            let exeNames = ["sprigctl"]
        #endif
        for config in ["debug", "release"] {
            for exeName in exeNames {
                let candidate = dir
                    .appendingPathComponent(".build")
                    .appendingPathComponent(config)
                    .appendingPathComponent(exeName)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        throw BinaryNotFound()
    }

    /// Run the sprigctl binary with `args`, capture stdout/stderr/exit.
    ///
    /// Uses the `ProcessTerminationGate` pattern (see GitCore's
    /// ProcessExit.swift) instead of `process.waitUntilExit()` — the
    /// latter deadlocks on macOS for fast-exiting children. Pipes are
    /// also drained via async tasks BEFORE the wait; doing it after
    /// (the previous code) risks a separate pipe-buffer deadlock when
    /// stdout/stderr exceeds ~64 KB and the child blocks writing.
    static func run(_ args: [String], cwd: URL? = nil) async throws -> Captured {
        let binary = try locateBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.currentDirectoryURL = cwd
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let gate = ProcessTerminationGate()
        process.terminationHandler = { _ in gate.signal() }

        try process.run()

        async let outBytes = readToEnd(outPipe.fileHandleForReading)
        async let errBytes = readToEnd(errPipe.fileHandleForReading)
        let out = try await outBytes
        let err = try await errBytes
        await gate.wait(processIsRunning: { process.isRunning })

        return Captured(
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Async pipe drain — same shape as GitCore.Runner's private helper
    /// but inlined here so the test target doesn't need `@testable
    /// import GitCore`.
    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global().async {
                do {
                    let data = try handle.readToEnd() ?? Data()
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func mkRepo(_ label: String) throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-sprigctl-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    static func initRepo(at url: URL) async throws {
        try await spawnGit(["init", "-b", "main"], cwd: url)
        try await spawnGit(["config", "user.email", "test@sprig.app"], cwd: url)
        try await spawnGit(["config", "user.name", "Sprig Test"], cwd: url)
        try await spawnGit(["config", "commit.gpgsign", "false"], cwd: url)
    }

    static func spawnGit(_ args: [String], cwd: URL) async throws {
        let process = Process()
        process.executableURL = try URL(fileURLWithPath: gitBinaryPath())
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // `try await process.runAndAwaitExit()` — race-safe replacement
        // for `try process.run(); process.waitUntilExit()`. Even though
        // we route stdio to /dev/null and don't risk pipe-buffer
        // deadlocks here, the underlying `waitUntilExit()` race against
        // fast-exiting children still bites (`git config <key> <val>`
        // exits in <50 ms).
        try await process.runAndAwaitExit()
    }

    /// Resolve git via case-insensitive PATH walk — same approach
    /// `GitCore.Runner` uses, so behavior is consistent across all OSes
    /// including Windows.
    static func gitBinaryPath() throws -> String {
        let env = ProcessInfo.processInfo.environment
        let pathEnv = env.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        let separator: Character
        #if os(Windows)
            separator = ";"
            let exeName = "git.exe"
        #else
            separator = ":"
            let exeName = "git"
        #endif
        for dir in pathEnv.split(separator: separator).map(String.init) {
            let candidate = (dir as NSString).appendingPathComponent(exeName)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw BinaryNotFound()
    }

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
