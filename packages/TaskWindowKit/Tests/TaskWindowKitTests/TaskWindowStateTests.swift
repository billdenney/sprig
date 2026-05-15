// TaskWindowStateTests.swift
//
// Pure-data tests for `TaskWindowState` and its `Failure` companion.
// No git invocation; no actors; no platform deps.

import Foundation
@testable import TaskWindowKit
import Testing

@Suite("TaskWindowState — lifecycle enum + accessors")
struct TaskWindowStateTests {
    // MARK: - isBusy / isTerminal

    @Test("isBusy is true only for .busy")
    func isBusySemantics() {
        #expect(TaskWindowState<Int>.idle.isBusy == false)
        #expect(TaskWindowState<Int>.busy(progress: nil).isBusy == true)
        #expect(TaskWindowState<Int>.busy(progress: 0.5).isBusy == true)
        #expect(TaskWindowState<Int>.success(42).isBusy == false)
        #expect(TaskWindowState<Int>.failure(.init(description: "boom")).isBusy == false)
    }

    @Test("isTerminal is true for .success and .failure only")
    func isTerminalSemantics() {
        #expect(TaskWindowState<Int>.idle.isTerminal == false)
        #expect(TaskWindowState<Int>.busy(progress: nil).isTerminal == false)
        #expect(TaskWindowState<Int>.success(42).isTerminal == true)
        #expect(TaskWindowState<Int>.failure(.init(description: "boom")).isTerminal == true)
    }

    // MARK: - successValue / failure

    @Test("successValue unwraps .success only")
    func successValueUnwrap() {
        #expect(TaskWindowState<Int>.idle.successValue == nil)
        #expect(TaskWindowState<Int>.busy(progress: nil).successValue == nil)
        #expect(TaskWindowState<Int>.success(42).successValue == 42)
        #expect(TaskWindowState<Int>.failure(.init(description: "boom")).successValue == nil)
    }

    @Test("failure accessor unwraps .failure only")
    func failureUnwrap() {
        let f = TaskWindowState<Int>.Failure(description: "boom")
        #expect(TaskWindowState<Int>.idle.failure == nil)
        #expect(TaskWindowState<Int>.busy(progress: nil).failure == nil)
        #expect(TaskWindowState<Int>.success(42).failure == nil)
        #expect(TaskWindowState<Int>.failure(f).failure == f)
    }

    // MARK: - Equatable

    @Test("Equatable: same state values compare equal")
    func equatableSameState() {
        #expect(TaskWindowState<Int>.idle == .idle)
        #expect(TaskWindowState<Int>.busy(progress: nil) == .busy(progress: nil))
        #expect(TaskWindowState<Int>.busy(progress: 0.5) == .busy(progress: 0.5))
        #expect(TaskWindowState<Int>.success(42) == .success(42))
    }

    @Test("Equatable: different cases or values compare not-equal")
    func equatableMismatch() {
        #expect(TaskWindowState<Int>.idle != .busy(progress: nil))
        #expect(TaskWindowState<Int>.busy(progress: 0.5) != .busy(progress: 0.7))
        #expect(TaskWindowState<Int>.success(42) != .success(43))
        #expect(TaskWindowState<Int>.success(42) != .idle)
    }

    @Test("Equatable on Failure uses description + underlyingTypeName")
    func failureEquatable() {
        let a = TaskWindowState<Int>.Failure(description: "boom")
        let b = TaskWindowState<Int>.Failure(description: "boom")
        let c = TaskWindowState<Int>.Failure(description: "kaboom")
        #expect(a == b)
        #expect(a != c)
        // underlyingTypeName participates: same description, different type → not equal
        let aTyped = TaskWindowState<Int>.Failure(description: "boom", underlyingTypeName: "GitError")
        let bTyped = TaskWindowState<Int>.Failure(description: "boom", underlyingTypeName: "GitError")
        let dTyped = TaskWindowState<Int>.Failure(description: "boom", underlyingTypeName: "OtherError")
        #expect(aTyped == bTyped)
        #expect(aTyped != dTyped)
        #expect(a != aTyped) // nil vs "GitError"
    }

    // MARK: - Failure(from:) ergonomics

    @Test("Failure(from:) captures description + underlying type name")
    func failureFromError() {
        struct DemoError: Error { let tag: String }
        let f = TaskWindowState<Int>.Failure(from: DemoError(tag: "x"))
        // The exact description varies with Swift's error printing, but
        // the type name should mention DemoError unambiguously.
        #expect(f.underlyingTypeName?.contains("DemoError") == true)
        #expect(f.description.isEmpty == false)
    }

    // MARK: - Sendable sanity

    @Test("TaskWindowState is Sendable — instances cross actor boundaries")
    func sendableCrossActor() async {
        actor Holder<T: Sendable> {
            var value: T
            init(_ value: T) {
                self.value = value
            }

            func store(_ v: T) {
                value = v
            }
        }

        let holder = Holder<TaskWindowState<Int>>(.idle)
        await holder.store(.success(42))
        let read = await holder.value
        #expect(read == .success(42))
    }
}
