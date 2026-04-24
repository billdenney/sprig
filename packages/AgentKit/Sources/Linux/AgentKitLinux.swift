#if os(Linux)
import Foundation

// Linux stub — part of the day-1 cross-platform scaffolding (ADR 0053).
// Real implementation lands when a Linux port is prioritized post-1.0.

enum AgentKitLinuxImpl {
    static let platform = "Linux"
    static func notImplemented() -> Never {
        fatalError("AgentKit Linux impl not yet available — see docs/architecture/cross-platform.md")
    }
}
#endif
