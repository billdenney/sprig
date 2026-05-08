#if os(Windows)
    import Foundation

    // Windows stub — part of the day-1 cross-platform scaffolding (ADR 0053).
    // Real implementation lands as part of M2-Win (Windows GUI shell;
    // 1.0 deliverable per ADR 0054).

    enum NotifyKitWindowsImpl {
        static let platform = "Windows"
        static func notImplemented() -> Never {
            fatalError("NotifyKit Windows impl not yet available — see docs/architecture/cross-platform.md")
        }
    }
#endif
