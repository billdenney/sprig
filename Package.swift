// swift-tools-version: 6.0
// Sprig — root SwiftPM manifest. See ADR 0053 for the three-tier structure
// this manifest enforces.

import PackageDescription

let tier1Targets: [String] = [
    "GitCore", "RepoState", "ConflictKit", "AIKit", "LFSKit",
    "SubmoduleKit", "SubtreeKit", "SafetyKit", "IPCSchema",
    "PlatformKit", "DiagKit", "StatusKit", "TaskWindowKit", "UIKitShared"
]

/// Per-target dependency overrides for Tier-1 packages. Default Tier-1
/// targets have no inter-package deps; entries here are explicit
/// cross-Tier-1 dependencies (always Tier-1 → Tier-1; never Tier-1 →
/// Tier-2 or Tier-3, which would violate ADR 0048's tier discipline).
let tier1Dependencies: [String: [Target.Dependency]] = [
    // RepoState consumes parsed `PorcelainV2Status` values from GitCore
    // when applying `git status` snapshots, and re-uses GitCore's
    // typed-error vocabulary. It also produces `AgentEvent` envelopes
    // (in `BadgeChangeBroadcaster`) using `IPCSchema`'s wire types,
    // and consumes `WatchEvent` (from PlatformKit) inside
    // `RepoRefreshDriver` to decide when filesystem activity warrants
    // a `git status` refresh. All four are portable Tier-1 packages,
    // so these dependencies are in-tier and add no platform coupling.
    "RepoState": ["GitCore", "IPCSchema", "PlatformKit"]
]

let tier2Targets: [String] = [
    "WatcherKit", "CredentialKit", "NotifyKit", "UpdateKit",
    "LauncherKit", "TransportKit", "AgentKit"
]

// Benchmarks are built only on macOS + Linux. package-benchmark does not
// support Windows (alphabetical-name-collision in threshold filenames per
// ordo-one/package-benchmark#308). Gating here keeps `swift build` green on
// the Windows CI job; see docs/architecture/performance.md and ADR 0021.
#if os(Windows)
    let benchmarkTargets: [Target] = []
    let benchmarkDependencies: [Package.Dependency] = []
#else
    let benchmarkTargets: [Target] = [
        .executableTarget(
            name: "SprigCoreBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                "GitCore",
                "PlatformKit",
                "WatcherKit"
            ],
            path: "Benchmarks/SprigCoreBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        )
    ]
    let benchmarkDependencies: [Package.Dependency] = [
        // package-benchmark depends on jemalloc as a system library (resolved
        // via pkg-config on both macOS and Linux — there's no vendored shim).
        // CI installs it: `apt-get install libjemalloc-dev` on Linux,
        // `brew install jemalloc` on macOS. We can't disable the Jemalloc
        // trait at this tools-version — package traits require swift-tools-
        // version 6.1, and bumping that breaks Xcode 16.0–16.2 in macOS CI.
        .package(
            url: "https://github.com/ordo-one/package-benchmark.git",
            from: "1.31.0"
        )
    ]
#endif

let package = Package(
    name: "Sprig",
    platforms: [.macOS(.v14)],
    products:
    (tier1Targets + tier2Targets).map { name in
        .library(name: name, targets: [name])
    }

        + [
            .executable(name: "sprigctl", targets: ["sprigctl"])
        ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.3.0"
        )
    ] + benchmarkDependencies,
    targets:
    tier1Targets.flatMap { name -> [Target] in
        let deps: [Target.Dependency] = tier1Dependencies[name] ?? []
        return [
            .target(
                name: name,
                dependencies: deps,
                path: "packages/\(name)/Sources/\(name)"
            ),
            .testTarget(
                name: "\(name)Tests",
                dependencies: [.target(name: name)] + deps,
                path: "packages/\(name)/Tests/\(name)Tests"
            )
        ]
    }

        +
        tier2Targets.flatMap { name -> [Target] in
            // Per-target test-only deps for Tier-2 packages. Test targets
            // can pull in additional Tier-1 packages without those becoming
            // production deps of the adapter.
            let extraTestDeps: [Target.Dependency] = switch name {
            case "TransportKit":
                // Integration tests demonstrate `Transport` + `IPCSchema`
                // composition end-to-end (encode envelope → send → receive
                // → decode envelope → respond).
                ["IPCSchema"]
            default:
                []
            }
            return [
                .target(
                    name: name,
                    dependencies: ["PlatformKit"],
                    path: "packages/\(name)/Sources",
                    sources: [name, "Mac", "Linux", "Windows"]
                ),
                .testTarget(
                    name: "\(name)Tests",
                    dependencies: [.target(name: name), "PlatformKit"] + extraTestDeps,
                    path: "packages/\(name)/Tests/\(name)Tests"
                )
            ]
        }

        + [
            .executableTarget(
                name: "sprigctl",
                dependencies: [
                    "GitCore",
                    "WatcherKit",
                    "PlatformKit",
                    .product(name: "ArgumentParser", package: "swift-argument-parser")
                ],
                path: "cli/sprigctl/Sources"
            ),
            .testTarget(
                name: "sprigctlTests",
                // GitCore for ProcessTerminationGate (race-safe replacement
                // for Process.waitUntilExit) used by SprigctlSupport.
                dependencies: ["sprigctl", "GitCore"],
                path: "cli/sprigctl/Tests"
            )
        ]
        + benchmarkTargets
)
