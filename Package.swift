// swift-tools-version: 6.0
// Sprig — root SwiftPM manifest. See ADR 0053 for the three-tier structure
// this manifest enforces.

import PackageDescription

let tier1Targets: [String] = [
    "GitCore", "RepoState", "ConflictKit", "AIKit", "LFSKit",
    "SubmoduleKit", "SubtreeKit", "SafetyKit", "IPCSchema",
    "PlatformKit", "DiagKit", "StatusKit", "TaskWindowKit", "UIKitShared"
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
                "PlatformKit"
            ],
            path: "Benchmarks/SprigCoreBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        )
    ]
    let benchmarkDependencies: [Package.Dependency] = [
        // package-benchmark pulls libjemalloc on Linux (vendored on macOS); the
        // Linux CI job + script/bootstrap install `libjemalloc-dev` so the
        // dependency resolves. We can't disable the Jemalloc trait at this
        // tools-version — package traits require swift-tools-version 6.1, and
        // bumping that breaks Xcode 16.0–16.2 in macOS CI (#11 history).
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
    tier1Targets.flatMap { name in
        [
            .target(name: name, path: "packages/\(name)/Sources/\(name)"),
            .testTarget(
                name: "\(name)Tests",
                dependencies: [.target(name: name)],
                path: "packages/\(name)/Tests/\(name)Tests"
            )
        ]
    }

        +
        tier2Targets.flatMap { name -> [Target] in
            [
                .target(
                    name: name,
                    dependencies: ["PlatformKit"],
                    path: "packages/\(name)/Sources",
                    sources: [name, "Mac", "Linux", "Windows"]
                ),
                .testTarget(
                    name: "\(name)Tests",
                    dependencies: [.target(name: name), "PlatformKit"],
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
                dependencies: ["sprigctl"],
                path: "cli/sprigctl/Tests"
            )
        ]
        + benchmarkTargets
)
