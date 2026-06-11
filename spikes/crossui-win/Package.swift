// swift-tools-version: 6.0
// SPIKE — not product code (see spikes/swift-cross-ui/README.md).
//
// R1/R16 de-risk (master-plan §8, risk register): does swift-cross-ui
// resolve and build on the Windows snapshot toolchain we actually
// ship on, and what do its binding ergonomics look like against our
// actor-based view models? A standalone package so the root manifest
// and its dependency resolution are untouched.

import PackageDescription

let package = Package(
    name: "SprigSpikeCrossUI",
    dependencies: [
        .package(url: "https://github.com/stackotter/swift-cross-ui", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "SpikeApp",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui")
            ]
        )
    ]
)
