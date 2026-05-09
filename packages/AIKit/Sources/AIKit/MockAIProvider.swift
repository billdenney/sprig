// MockAIProvider — a scripted ``AIProvider`` for testing.
//
// Ships in production code (not under a test-only target) so
// downstream modules' tests can `import AIKit` and use it without
// duplicating the boilerplate. Mirrors the convention WatcherKit
// established with `MockFileWatcher`.
//
// Tier 1 portable. Pure Foundation. Actor-isolated state so
// concurrent callers see consistent behavior in Swift 6 strict
// concurrency.

import Foundation

/// Scripted AIProvider for tests.
///
/// Two construction modes:
///
/// - ``init(identifier:outcomes:)`` — sequence mode. Each call to
///   ``complete(request:)`` consumes one entry from the script in
///   order. When the script runs out, the next call throws
///   ``AIError/providerUnavailable`` to surface the misuse loudly
///   rather than hanging or returning empty data.
/// - ``always(_:identifier:)`` — fixed-response mode. Every call
///   returns the same response.
///
/// Both modes record every observed request to ``requestLog`` so
/// callers can assert on prompt content.
public actor MockAIProvider: AIProvider {
    public nonisolated let identifier: String

    private var mode: Mode
    public private(set) var requestLog: [AIRequest] = []

    public enum Outcome: Sendable, Equatable {
        case response(AIResponse)
        case error(AIError)
    }

    private enum Mode {
        /// Sequence mode: consume one outcome per call.
        case script([Outcome])
        /// Always-mode: same response every call.
        case always(AIResponse)
    }

    /// Sequence-mode init. Each call consumes one outcome in order.
    public init(identifier: String = "mock", outcomes: [Outcome]) {
        self.identifier = identifier
        self.mode = .script(outcomes)
    }

    /// Always-mode convenience. Every call returns the same
    /// response.
    public static func always(
        _ response: AIResponse,
        identifier: String = "mock"
    ) -> MockAIProvider {
        MockAIProvider(identifier: identifier, fixed: response)
    }

    private init(identifier: String, fixed: AIResponse) {
        self.identifier = identifier
        self.mode = .always(fixed)
    }

    public func complete(request: AIRequest) async throws -> AIResponse {
        requestLog.append(request)
        switch mode {
        case let .always(response):
            return response
        case var .script(outcomes):
            guard !outcomes.isEmpty else {
                throw AIError.providerUnavailable(
                    provider: identifier,
                    underlying: "MockAIProvider script exhausted; the test under-provisioned outcomes"
                )
            }
            let next = outcomes.removeFirst()
            mode = .script(outcomes)
            switch next {
            case let .response(response):
                return response
            case let .error(error):
                throw error
            }
        }
    }
}
