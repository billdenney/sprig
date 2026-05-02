import Foundation

/// Invokes the system `git` binary and captures its output.
///
/// This is the one and only place Sprig spawns `git`. Enforcing that rule (per
/// CLAUDE.md and ADR 0023) gives us a single seam for argv escaping, environment
/// scrubbing, encoding normalization, cancellation, timeouts, and the eventual
/// long-lived `cat-file --batch` cache.
///
/// The runner is portable Swift + Foundation. It works on macOS, Linux, and
/// Windows (Foundation's `Process` uses `posix_spawn` on POSIX and
/// `CreateProcessW` on Windows). Platform-quirky behaviors are handled here so
/// the rest of the codebase can call `run(_:)` without thinking about them.
public struct Runner: Sendable {
    /// Absolute path to the `git` executable, or `nil` to use `git` from `PATH`.
    public var gitPath: String?

    /// Default working directory for invocations that don't specify one.
    public var defaultWorkingDirectory: URL?

    /// Environment variables merged into the invocation. Nil values unset the
    /// corresponding variable. Sprig scrubs a few git-sensitive env vars by
    /// default (see ``scrubbedEnvironment(base:)``).
    public var environmentOverrides: [String: String?]

    /// Optional log that records every `git` invocation as a
    /// ``LoggedCommand``. When nil, no logging happens (the default
    /// preserves existing test/CLI behavior). When non-nil, the
    /// runner appends an entry on every ``run(_:cwd:stdin:throwOnNonZero:)``
    /// call after the process exits. Per ADR 0057, the agent owns
    /// one of these and shares it across every per-repo runner so
    /// the Commands panel sees the full agent-wide command history.
    public var log: RunnerLog?

    public init(
        gitPath: String? = nil,
        defaultWorkingDirectory: URL? = nil,
        environmentOverrides: [String: String?] = [:],
        log: RunnerLog? = nil
    ) {
        self.gitPath = gitPath
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.environmentOverrides = environmentOverrides
        self.log = log
    }

    /// Captured output of a completed invocation.
    public struct Output: Sendable {
        public var stdout: Data
        public var stderr: Data
        public var exitCode: Int32
        public var commandLine: [String]

        public var stdoutString: String {
            String(data: stdout, encoding: .utf8) ?? ""
        }

        public var stderrString: String {
            String(data: stderr, encoding: .utf8) ?? ""
        }
    }

    /// Spawn `git <arguments>` and await completion.
    ///
    /// - Parameters:
    ///   - arguments: argv, **not** a shell string. Each element becomes a
    ///     distinct argument; no shell interpolation happens.
    ///   - cwd: working directory, or `defaultWorkingDirectory` if nil.
    ///   - stdin: optional bytes fed to the child's stdin.
    /// - Returns: stdout/stderr/exit code.
    /// - Throws: ``GitError`` for binary-not-found, non-zero exits (only when
    ///   `throwOnNonZero` is true), signals, or I/O failures.
    ///
    /// **Multi-agent caveat (R15 audit, F1).** When another git agent
    /// (terminal `git add`, another GUI, CI on the same machine) is
    /// holding `.git/index.lock` / `.git/packed-refs.lock` / etc., a
    /// Sprig-initiated **write** op fails with stderr like
    /// `fatal: Unable to create '/path/.git/index.lock': File exists.`
    /// This surfaces as ``GitError/nonZeroExit``. Read-only ops
    /// (`git status`, `git log`) are unaffected — they read-lock the
    /// index briefly but don't conflict with concurrent writes.
    ///
    /// Until the planned `retryOnLockContention` parameter lands,
    /// callers initiating writes during likely-concurrent windows
    /// should either (a) check
    /// ``GitMetadataPaths/gitOperationInFlight(in:gitVersion:)`` first
    /// and defer, or (b) catch the `nonZeroExit` and retry.
    ///
    // TODO(R15-F1): add a `retryOnLockContention: RetryPolicy = .none`
    // parameter that auto-detects the `Unable to create '*.lock': File
    // exists` stderr signature and retries with exponential backoff.
    // Tracker: docs/planning/audit-followups.md
    public func run(
        _ arguments: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        throwOnNonZero: Bool = true
    ) async throws -> Output {
        let resolvedPath = try resolveGitPath()
        let resolvedCwd = cwd ?? defaultWorkingDirectory
        let result = try await spawnAndWait(
            executablePath: resolvedPath,
            arguments: arguments,
            cwd: resolvedCwd,
            stdin: stdin
        )

        // Record to the log on every exit path (success, non-zero,
        // signal). The log is a diagnostic record of *what was run*;
        // it's not gated on success. Only the throw paths below
        // surface errors to the caller; the log captures equally.
        await recordToLogIfConfigured(result: result)

        if result.terminationReason == .uncaughtSignal {
            throw GitError.signalled(
                command: arguments,
                signal: result.exitCode,
                stderr: result.stderrString
            )
        }
        if throwOnNonZero, result.exitCode != 0 {
            throw GitError.nonZeroExit(
                command: arguments,
                exitCode: result.exitCode,
                stderr: result.stderrString,
                stdout: result.stdoutString
            )
        }
        return Output(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            commandLine: result.argv
        )
    }

    /// Captured output of a single completed Process invocation.
    /// Internal — `Output` is the public-API equivalent (without the
    /// log-record fields).
    private struct SpawnResult {
        let argv: [String]
        let cwd: URL?
        let startedAt: Date
        let finishedAt: Date
        let exitCode: Int32
        let terminationReason: Process.TerminationReason
        let stdout: Data
        let stderr: Data

        var stdoutString: String {
            String(data: stdout, encoding: .utf8) ?? ""
        }

        var stderrString: String {
            String(data: stderr, encoding: .utf8) ?? ""
        }
    }

    /// Spawn a child process and capture its full output. Extracted
    /// from ``run(_:cwd:stdin:throwOnNonZero:)`` so that function
    /// stays under the function-body-length lint cap. Throws only
    /// for I/O failures during spawn or pipe reads — exit-status
    /// interpretation is the caller's job.
    private func spawnAndWait(
        executablePath: String,
        arguments: [String],
        cwd: URL?,
        stdin: Data?
    ) async throws -> SpawnResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = scrubbedEnvironment(base: ProcessInfo.processInfo.environment)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try inPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        // Pre-register termination signaling BEFORE `run()`. Plain
        // `Process.waitUntilExit()` deadlocks on macOS for fast-
        // exiting children (the `NSTaskDidTerminateNotification`
        // setup loses the race against the child's exit and the
        // runloop waits forever). See `ProcessExit.swift` for the
        // full diagnosis.
        let terminationGate = ProcessTerminationGate()
        process.terminationHandler = { _ in terminationGate.signal() }

        try process.run()
        let startedAt = Date()

        async let stdoutBytes = Self.readToEnd(outPipe.fileHandleForReading)
        async let stderrBytes = Self.readToEnd(errPipe.fileHandleForReading)
        let stdout = try await stdoutBytes
        let stderr = try await stderrBytes
        await terminationGate.wait(processIsRunning: { process.isRunning })
        let finishedAt = Date()

        return SpawnResult(
            argv: [executablePath] + arguments,
            cwd: cwd,
            startedAt: startedAt,
            finishedAt: finishedAt,
            exitCode: process.terminationStatus,
            terminationReason: process.terminationReason,
            stdout: stdout,
            stderr: stderr
        )
    }

    /// Append a ``LoggedCommand`` to ``log`` (no-op if `log` is nil).
    private func recordToLogIfConfigured(result: SpawnResult) async {
        guard let log else { return }
        let entry = LoggedCommand(
            argv: result.argv,
            cwd: result.cwd?.path,
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            exitCode: result.exitCode,
            stderrTail: LoggedCommand.truncateStderr(result.stderrString),
            stdoutByteCount: result.stdout.count
        )
        await log.record(entry)
    }

    /// Convenience: `git --version`, parsed.
    public func version() async throws -> GitVersion {
        let output = try await run(["--version"])
        guard let version = GitVersion.parse(output.stdoutString) else {
            throw GitError.parseFailure(
                context: "git --version",
                rawSnippet: output.stdoutString
            )
        }
        return version
    }

    // MARK: - Internals

    /// Scrub environment variables that would make git behave unpredictably.
    /// Callers can re-set any of these via `environmentOverrides`.
    ///
    /// - `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` removed: we always pass
    ///   these via arguments or `-C` so they don't leak from the parent shell.
    /// - `GIT_TERMINAL_PROMPT=0` set: never block on a tty prompt in Sprig
    ///   invocations; credentials flow through ``CredentialKit``.
    /// - `LC_ALL=C.UTF-8` set: ensures deterministic UTF-8 output and
    ///   porcelain-v2 byte-stability across locales.
    func scrubbedEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        env.removeValue(forKey: "GIT_INDEX_FILE")
        env.removeValue(forKey: "GIT_CONFIG")
        env.removeValue(forKey: "GIT_CONFIG_GLOBAL")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C.UTF-8"
        env["LANG"] = "C.UTF-8"

        for (key, value) in environmentOverrides {
            if let value { env[key] = value } else { env.removeValue(forKey: key) }
        }
        return env
    }

    func resolveGitPath() throws -> String {
        if let gitPath { return gitPath }

        // Explicit PATH search so we can give a clean GitError rather than let
        // Process throw a generic ENOENT.
        //
        // Windows env vars are case-insensitive at the OS level but
        // Foundation's `environment` dictionary is case-sensitive. Look up PATH
        // case-insensitively so `Path`, `PATH`, `pAtH` all resolve. POSIX
        // platforms are case-sensitive by convention but the same lookup
        // still works.
        let env = ProcessInfo.processInfo.environment
        let pathEnv = env.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
        let separator: Character
        #if os(Windows)
            separator = ";"
        #else
            separator = ":"
        #endif
        let candidateDirs = pathEnv.split(separator: separator).map(String.init)
        let exeName: String
        #if os(Windows)
            exeName = "git.exe"
        #else
            exeName = "git"
        #endif
        for dir in candidateDirs {
            let candidate = (dir as NSString).appendingPathComponent(exeName)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw GitError.binaryNotFound(probedPath: pathEnv)
    }

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
}
