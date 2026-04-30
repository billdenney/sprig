// ProcessExit.swift
//
// Race-safe replacement for `Process.waitUntilExit()`.
//
// Why this exists
// ---------------
// `Process.waitUntilExit()` spins a CFRunLoop on the calling thread and
// blocks until `NSTaskDidTerminateNotification` fires. When the child
// exits *faster* than Foundation finishes setting up the task-monitor
// dispatch source — common for `git add`, `git checkout -b`, and other
// sub-100 ms commands — the notification is missed entirely and the
// runloop waits forever. This was diagnosed via `sample(1)` stack traces
// captured by the macOS CI watchdog (PR #16) showing every Sprig test
// process wedged in `[NSConcreteTask waitUntilExit]` →
// `CFRunLoopRunSpecific` → `mach_msg2_trap`.
//
// The fix
// -------
// Pre-register `process.terminationHandler` *before* `process.run()`
// (terminationHandler is honored even for fast exits) and await a
// continuation it resumes. Belt-and-suspenders: also poll `isRunning`
// at await time, in case Foundation drops the handler invocation.

import Foundation

/// One-shot signal that a `Process` has terminated.
///
/// Usage protocol:
///   1. Caller creates a `ProcessTerminationGate`.
///   2. Caller assigns
///      ``swift
///      process.terminationHandler = { _ in gate.signal() }
///      ``
///      **before** `process.run()` is called.
///   3. After running (and optionally draining stdout/stderr), caller
///      does `await gate.wait(processIsRunning: { process.isRunning })`.
///
/// `signal()` may be called before, during, or after `wait(...)`; the
/// `wait` method re-checks `processIsRunning` to cover the case where
/// the handler fired before the awaiter parked. Safe to call from any
/// thread.
public final class ProcessTerminationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    public init() {}

    /// Marks the process as terminated. Idempotent. Resumes a pending
    /// `wait()` if one is already parked.
    public func signal() {
        lock.lock()
        if signaled {
            lock.unlock()
            return
        }
        signaled = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }

    /// Awaits `signal()`. Returns immediately if already signaled or if
    /// `processIsRunning()` reports the process has already exited
    /// (defense-in-depth for missed handler invocations).
    public func wait(processIsRunning: () -> Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signaled {
                lock.unlock()
                cont.resume()
                return
            }
            if !processIsRunning() {
                signaled = true
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}

public extension Process {
    /// Race-safe replacement for the
    /// `try process.run(); process.waitUntilExit()` pattern.
    ///
    /// Sets `terminationHandler` first, then `run()`s, then awaits exit
    /// via a ``ProcessTerminationGate``. Use this whenever the child's
    /// stdio is consumed elsewhere (e.g. routed to `/dev/null`, or to
    /// pipes that the caller drains separately). For the
    /// run-and-capture-pipes pattern, set up the gate manually so the
    /// pipe drains can run between `run()` and the `wait`.
    ///
    /// **Replaces deadlock-prone:**
    /// ``swift
    /// try process.run()
    /// process.waitUntilExit()  // can hang on macOS for fast exits
    /// ``
    func runAndAwaitExit() async throws {
        let gate = ProcessTerminationGate()
        terminationHandler = { _ in gate.signal() }
        try run()
        await gate.wait(processIsRunning: { [weak self] in
            self?.isRunning ?? false
        })
    }
}
