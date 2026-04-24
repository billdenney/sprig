#if os(Windows)
import Foundation

// Windows stub — part of the day-1 cross-platform scaffolding (ADR 0053).
// Real implementation lands when a Windows port is prioritized post-1.0.

enum NotifyKitWindowsImpl {
    static let platform = "Windows"
    static func notImplemented() -> Never {
        fatalError("NotifyKit Windows impl not yet available — see docs/architecture/cross-platform.md")
    }
}
#endif
