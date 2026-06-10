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
    // a `git status` refresh. `SnapshotIndex` (per ADR 0033's amendment)
    // re-uses SafetyKit's `SnapshotRefName` format type when listing
    // `refs/sprig/snapshots/...` entries from `git for-each-ref`. All
    // five are portable Tier-1 packages, so these dependencies are
    // in-tier and add no platform coupling.
    "RepoState": ["GitCore", "IPCSchema", "PlatformKit", "SafetyKit"],
    // SafetyKit's `SnapshotWriter` invokes `git update-ref` to create
    // the ADR 0033 snapshot refs that make destructive operations
    // reversible. That's the only dependency it has on GitCore today;
    // the format type (`SnapshotRefName`) is pure-Foundation and
    // doesn't need it.
    "SafetyKit": ["GitCore"],
    // LFSKit's `LFSAttributeChecker` wraps `git check-attr filter` to
    // get the authoritative answer for "is this path LFS-tracked?",
    // covering the full glob/path-pattern semantics of
    // `.gitattributes`. Pure-Foundation pieces (the pointer-file
    // parser and the .gitattributes scanner) don't need GitCore.
    "LFSKit": ["GitCore"],
    // SubmoduleKit's `SubmoduleStatus` async wrapper invokes
    // `git submodule status` through `GitCore.Runner`. The pure
    // parser (`SubmoduleStatusParser`) and value type
    // (`SubmoduleEntry`) don't need GitCore, but they live in the
    // same Tier-1 module and the convenience of one dep covers both.
    "SubmoduleKit": ["GitCore"],
    // DiagKit's `EnvironmentCollector` probes git via
    // `GitCore.Runner` (`git --version` and `git lfs version`) so
    // diagnostics envelopes carry the actually-resolved tool
    // versions, not just whatever was on PATH at compile time. The
    // value-type `EnvironmentReport` is pure-Foundation; the dep
    // is needed by the collector.
    "DiagKit": ["GitCore"],
    // TaskWindowKit's `CloneDialogViewModel` (and future
    // task-window view models per ADR 0048) invokes git via
    // `GitCore.Runner` for the actual operation each window
    // represents (clone, commit, push, …). `TaskWindowState` itself
    // is pure-Foundation; the dep is needed by the VMs.
    // M4's `MergeConflictResolverViewModel` additionally pulls in
    // `ConflictKit` for `ClassifiedConflict` / `ConflictedPathChoice`
    // — both Tier-1 cross-deps so no platform coupling.
    // ADR 0070's `PreflightChecks` adds `LFSKit` for the
    // large-staged-file-without-LFS guard rail
    // (`LFSAttributeChecker`, the `git check-attr` wrapper).
    "TaskWindowKit": ["GitCore", "ConflictKit", "LFSKit"],
    // ConflictKit re-exports `GitCore.UnmergedEntry` /
    // `UnmergedStage` / `GitFileMode` via classification helpers
    // (`ConflictKind.classify(_:)`) so M4 MergeConflictResolver can
    // route each unmerged entry to its UI affordance. The marker-
    // parser side of ConflictKit stays pure-Foundation; the dep is
    // needed for the new typed-classifier surface.
    "ConflictKit": ["GitCore"]
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
        // Per-target resource overrides. AIKit ships its prompts
        // (ADR 0037) as `.process`'d resources so `Bundle.module`
        // can locate them at runtime; the loader stays directory-
        // based for the user-overridable case but defaults to the
        // bundled set. Other Tier-1 packages have no resources.
        let resources: [Resource] = switch name {
        case "AIKit":
            [.process("Prompts")]
        default:
            []
        }
        return [
            .target(
                name: name,
                dependencies: deps,
                path: "packages/\(name)/Sources/\(name)",
                resources: resources
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
            // Per-target production deps for Tier-2 packages beyond the
            // default `PlatformKit`. AgentKit composes Tier-1 RepoState +
            // GitCore + IPCSchema with Tier-2 WatcherKit + TransportKit
            // to host the single-process agent loop and bridge it to a
            // Transport-backed sink (see `AgentKit/RepoAgent` +
            // `AgentKit/TransportBadgeEventSink`).
            let extraDeps: [Target.Dependency] = switch name {
            case "AgentKit":
                ["GitCore", "RepoState", "IPCSchema", "WatcherKit", "TransportKit"]
            default:
                []
            }
            // Per-target test-only deps for Tier-2 packages. Test targets
            // can pull in additional Tier-1 packages without those becoming
            // production deps of the adapter.
            let extraTestDeps: [Target.Dependency] = switch name {
            case "TransportKit":
                // Integration tests demonstrate `Transport` + `IPCSchema`
                // composition end-to-end (encode envelope → send → receive
                // → decode envelope → respond).
                ["IPCSchema"]
            case "AgentKit":
                // AgentKit's integration tests exercise the full pipeline
                // against real git, so they need the Tier-1 packages used
                // in the production deps plus their helpers. SafetyKit is
                // a test-only addition for `RepoAgent`'s snapshot-prune
                // tests, which write `refs/sprig/snapshots/...` refs via
                // `SnapshotRefName` to set up fixtures.
                ["GitCore", "RepoState", "IPCSchema", "WatcherKit", "TransportKit", "SafetyKit"]
            default:
                []
            }
            return [
                .target(
                    name: name,
                    dependencies: ["PlatformKit"] + extraDeps,
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
                    "RepoState",
                    "IPCSchema",
                    "AgentKit",
                    "SafetyKit",
                    "ConflictKit",
                    "LFSKit",
                    "SubmoduleKit",
                    "DiagKit",
                    .product(name: "ArgumentParser", package: "swift-argument-parser")
                ],
                path: "cli/sprigctl/Sources"
            ),
            .testTarget(
                name: "sprigctlTests",
                // GitCore for ProcessTerminationGate (race-safe replacement
                // for Process.waitUntilExit) used by SprigctlSupport;
                // RepoState + IPCSchema + AgentKit for AgentCommand tests;
                // SafetyKit for RecoverCommand tests (snapshot ref names);
                // ConflictKit for ConflictsCommand tests;
                // LFSKit for LFSCommand tests;
                // SubmoduleKit for SubmoduleCommand tests;
                // DiagKit for DiagnoseCommand tests.
                dependencies: [
                    "sprigctl",
                    "GitCore",
                    "RepoState",
                    "IPCSchema",
                    "AgentKit",
                    "SafetyKit",
                    "ConflictKit",
                    "LFSKit",
                    "SubmoduleKit",
                    "DiagKit"
                ],
                path: "cli/sprigctl/Tests"
            ),
            // ---- Integration tests — M1 → M2 exit gate (ADR 0021) ----
            //
            // `IntegrationSupport` is the shared library of fixture
            // synthesizers (real `git init` + `git commit` per state).
            // `IntegrationTests` wires the two M1 → M2 gates doable on
            // hosted CI today: PorcelainV2Parser fidelity across the
            // documented repo states (the literal M1 byte-match
            // criterion interpreted as parser correctness; sprigctl
            // status emits human/JSON output, not raw porcelain, so
            // byte equality of binaries is impossible by design — see
            // `milestones.md` commentary), and the EventCoalescer
            // 10k-event wall-clock budget (proxy for ADR 0021's <2 %
            // CPU watcher target). The 100k-file benchmark gate stays
            // deferred to a self-hosted runner (see
            // `docs/ci/self-hosted.md`).
            .target(
                name: "IntegrationSupport",
                dependencies: ["GitCore"],
                path: "tests/integration/Sources/IntegrationSupport"
            ),
            .testTarget(
                name: "IntegrationTests",
                dependencies: [
                    "IntegrationSupport",
                    "GitCore",
                    "PlatformKit"
                ],
                path: "tests/integration/Tests/IntegrationTests"
            )
        ]
        + benchmarkTargets
)
