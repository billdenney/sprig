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
    ],
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
                    dependencies: [.target(name: name)],
                    path: "packages/\(name)/Tests/\(name)Tests"
                )
            ]
        }

        + [
            .executableTarget(
                name: "sprigctl",
                dependencies: [
                    "GitCore",
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
)
