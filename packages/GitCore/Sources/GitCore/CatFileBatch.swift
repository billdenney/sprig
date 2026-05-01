import Foundation

/// Long-lived `git cat-file --batch` wrapper for cheap object reads.
///
/// Each call to ``read(_:)`` writes the object name to the child's stdin
/// and reads back the response — a ~one-syscall round-trip on top of an
/// already-running process. Compare to spawning `git cat-file -p <sha>`
/// per request, which forks + execs git for every read; on a 100k-file
/// diff that's the difference between O(seconds) and O(milliseconds).
///
/// CLAUDE.md mandates that all git invocations go through GitCore. This
/// is the second authorized spawn pattern (alongside ``Runner``):
/// stateful, long-lived, single-purpose.
///
/// Thread safety: the actor isolates the request/response cycle so two
/// concurrent `read(_:)` calls are serialized correctly. Stale calls
/// against a `close()`'d instance throw ``GitError/closed(_:)``.
///
/// Protocol reference: see git-cat-file(1) "BATCH OUTPUT". For each
/// object name written to stdin, git emits one of:
/// - `<sha> <type> <size>\n<content bytes>\n` for found objects
/// - `<input> missing\n` for unknown ones
///
/// ## Multi-agent caveat (R15 audit, F2)
///
/// `git cat-file --batch` mmaps pack files when it first reads
/// pack-resident objects. When **another git agent** (`git gc` from
/// the terminal, a CI run, another GUI) rewrites or removes those
/// packs, our process keeps the stale mappings. Subsequent reads can:
///
/// - Return wrong bytes (mmap'd region of an orphaned pack).
/// - Fail with `objectNotFound` (the object got moved to a new pack).
/// - Race the rewrite and corrupt content silently.
///
/// This is a documented git limitation. Callers must restart the
/// `CatFileBatch` instance after a known repacking event. The agent
/// will wire this to watcher events on `<gitDir>/objects/pack/` once
/// the M2 agent code lands; until then, callers are responsible for
/// ``close()``-ing and re-initializing on any suspicion of repack.
/// A future `restart()` convenience method (close + re-init in one
/// call) is tracked in `docs/planning/multi-agent-audit-2026-05.md`.
public actor CatFileBatch {
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var terminationGate: ProcessTerminationGate?

    /// Open `git cat-file --batch` against the given working directory.
    ///
    /// - Parameter repoURL: must be a directory inside a git repository
    ///   (or the worktree root). `git cat-file` resolves the repo via
    ///   the standard `.git` discovery walk.
    /// - Parameter gitPath: optional explicit path to the git binary.
    ///   When nil, falls back to the same PATH search ``Runner`` uses.
    public init(repoURL: URL, gitPath: String? = nil) async throws {
        let resolved = try Self.resolveGitPath(explicit: gitPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = ["cat-file", "--batch"]
        process.currentDirectoryURL = repoURL
        process.environment = Self.scrubbedEnvironment()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Wire termination signaling BEFORE `run()` so `close()` can
        // await child exit race-safely instead of using
        // `waitUntilExit()` (which deadlocks for fast exits on macOS —
        // see ProcessExit.swift).
        let gate = ProcessTerminationGate()
        process.terminationHandler = { _ in gate.signal() }

        try process.run()

        self.process = process
        terminationGate = gate
        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
    }

    /// Read one object by name (sha, ref, ref-with-path, etc — anything
    /// `git cat-file` would accept).
    public func read(_ objectName: String) async throws -> CatFileObject {
        guard let stdin, let stdout else {
            throw GitError.closed("CatFileBatch")
        }
        precondition(
            !objectName.contains("\n"),
            "CatFileBatch.read object name must not contain newlines"
        )

        // Send the query. The trailing \n is the record terminator git
        // expects; the preconditionFailure above guards against
        // accidental multi-line names that would confuse the parser.
        try stdin.write(contentsOf: Data((objectName + "\n").utf8))

        // Header line: "<sha> <type> <size>\n" or "<input> missing\n".
        let header = try Self.readLine(from: stdout)
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: false)

        if parts.count == 2, parts[1] == "missing" {
            throw GitError.objectNotFound(String(parts[0]))
        }
        guard parts.count == 3,
              let kind = ObjectKind(rawValue: String(parts[1])),
              let size = Int(parts[2])
        else {
            throw GitError.parseFailure(
                context: "cat-file --batch header",
                rawSnippet: trimmed
            )
        }

        let sha = String(parts[0])
        let content = try Self.readExactly(size, from: stdout)
        // Trailing newline after the binary blob.
        _ = try Self.readExactly(1, from: stdout)

        return CatFileObject(sha: sha, kind: kind, content: content)
    }

    /// Close stdin (so the child sees EOF and exits) and wait for it
    /// to terminate. Subsequent ``read(_:)`` calls throw
    /// ``GitError/closed(_:)``. Idempotent.
    public func close() async {
        guard let process else { return }
        try? stdin?.close()
        stdin = nil
        // Race-safe wait via the gate set up in init() — never call
        // `process.waitUntilExit()` here; it deadlocks on macOS for
        // fast exits (the child exits as soon as it sees stdin EOF).
        await terminationGate?.wait(processIsRunning: { process.isRunning })
        try? stdout?.close()
        stdout = nil
        terminationGate = nil
        self.process = nil
    }

    deinit {
        if let stdin {
            try? stdin.close()
        }
        if let process, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Internals

    /// Read bytes from `handle` until and including the first `\n`. The
    /// returned string includes the newline. Git header lines are always
    /// ASCII; non-UTF-8 input becomes the "<non-UTF-8>" placeholder
    /// rather than crashing.
    private static func readLine(from handle: FileHandle) throws -> String {
        var buffer = Data()
        while true {
            guard let chunk = try handle.read(upToCount: 1), !chunk.isEmpty else {
                let snippet = String(data: buffer, encoding: .utf8) ?? "<non-UTF-8>"
                throw GitError.parseFailure(
                    context: "cat-file --batch: unexpected EOF reading header",
                    rawSnippet: snippet
                )
            }
            buffer.append(chunk)
            if chunk[0] == 0x0A { break }
        }
        return String(data: buffer, encoding: .utf8) ?? "<non-UTF-8>"
    }

    /// Read exactly `count` bytes, looping over partial reads (pipes
    /// frequently return short).
    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            let remaining = count - out.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                throw GitError.parseFailure(
                    context: "cat-file --batch: short read (got \(out.count) of \(count))",
                    rawSnippet: ""
                )
            }
            out.append(chunk)
        }
        return out
    }

    /// Mirror of ``Runner/scrubbedEnvironment(base:)`` — keep behavior
    /// consistent across all git invocations from GitCore.
    private static func scrubbedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        env.removeValue(forKey: "GIT_INDEX_FILE")
        env.removeValue(forKey: "GIT_CONFIG")
        env.removeValue(forKey: "GIT_CONFIG_GLOBAL")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C.UTF-8"
        env["LANG"] = "C.UTF-8"
        return env
    }

    /// Same case-insensitive PATH walk Runner uses (Windows env vars
    /// are case-insensitive at the OS level but Foundation exposes a
    /// case-sensitive Swift Dictionary).
    private static func resolveGitPath(explicit: String?) throws -> String {
        if let explicit { return explicit }
        let env = ProcessInfo.processInfo.environment
        let pathEnv = env.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        let separator: Character
        #if os(Windows)
            separator = ";"
        #else
            separator = ":"
        #endif
        let exeName: String
        #if os(Windows)
            exeName = "git.exe"
        #else
            exeName = "git"
        #endif
        for dir in pathEnv.split(separator: separator).map(String.init) {
            let candidate = (dir as NSString).appendingPathComponent(exeName)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw GitError.binaryNotFound(probedPath: pathEnv)
    }
}
