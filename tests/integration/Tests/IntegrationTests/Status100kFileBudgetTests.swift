// Status100kFileBudgetTests.swift
//
// M1 → M2 exit gate (the 100k-file half): wall-clock budget for
// `git status --porcelain=v2 -z` + `PorcelainV2Parser.parse(_:)` on a
// synthesized 100 000-file repo. ADR 0021's full budget set (CPU%, RSS,
// status latency) requires a self-hosted runner for stable measurement;
// this test is the opt-in smoke that catches catastrophic regressions
// (orders-of-magnitude blow-outs in parse time, accidental O(N²) walks).
//
// **Opt-in by design.** This suite is gated behind the
// `SPRIG_RUN_SCALE_TESTS=1` environment variable and **does not run on
// default `swift test` or any hosted-CI workflow**. Reason: 100 k file
// synthesis dominates per-job wall-clock time on hosted CI runners
// (~10–30 s on macOS/Linux SSDs; potentially several minutes on
// Windows where individual filesystem ops can take ~2 s per the
// cross-platform-quirks catalog). Running it on every PR would
// quintuple or worse the CI bill for a smoke check that catches the
// same regressions the smaller fixture tests already do. The benchmark
// ladder in `Benchmarks/SprigCoreBenchmarks.swift` carries the official
// 100 k perf-comparison budget; that workflow targets the self-hosted
// runner and goes nightly-green once it's online.
//
// **When this DOES run:**
//   - Locally, ad-hoc: `SPRIG_RUN_SCALE_TESTS=1 swift test --filter Status100kFileBudgetTests`
//   - On the future self-hosted nightly workflow (it can set the env
//     var alongside the benchmark invocation).
//   - On a manually-triggered hosted CI workflow if we ever decide to
//     spot-check (e.g. before a release tag).
//
// **What this asserts** (when enabled):
//   - 100k-file repo can be synthesized + queried within a generous
//     wall-clock budget.
//   - One `git status` walk against that repo, plus a full parse of its
//     porcelain-v2 output, completes inside the 60 s measured-window
//     ceiling (synthesis time runs before the clock starts).
//   - The parsed model is non-trivial (entries reflect the ~10 % dirty
//     subset the synthesizer creates).
//
// **What this does NOT assert** (those still need the self-hosted
// runner — see `docs/ci/self-hosted.md`):
//   - Sustained CPU % under load.
//   - Peak RSS / steady-state memory.
//   - Status latency *after* an fsmonitor warm-up (ADR 0024).

import Foundation
import GitCore
import IntegrationSupport
import Testing

@Suite(
    "M1 → M2 gate (100k-file fixture): git status + parse wall-clock budget",
    .enabled(
        if: ProcessInfo.processInfo.environment["SPRIG_RUN_SCALE_TESTS"] == "1",
        "Opt-in via SPRIG_RUN_SCALE_TESTS=1 (disabled on hosted CI — see file header)"
    ),
    .timeLimit(.minutes(15))
)
struct Status100kFileBudgetTests {
    /// Files to commit. ADR 0021 calibrates the perf budgets at this
    /// scale ("Linux-kernel scale").
    private static let fileCount = 100_000

    /// Wall-clock ceiling for the measured (git status + parse) window
    /// only. Excludes the synthesis setup time — that runs before the
    /// clock starts and isn't budgeted here.
    ///
    /// Healthy 100 k-file `git status` on hosted CI runs in 5–15 s cold
    /// (no fsmonitor warm-up); 60 s is ~4–10× that, which absorbs
    /// hosted-runner variance, Linux Foundation flake, and Windows
    /// filesystem scheduling without flaking.
    private static let wallClockBudget: Duration = .seconds(60)

    @Test("synthesized 100k-file repo: git status + porcelain-v2 parse inside the wall-clock budget")
    func statusOn100kFileRepo() async throws {
        let (dir, runner) = try await FixtureSynthesizer.makeRepoWithFileCount(Self.fileCount)
        defer { FixtureSynthesizer.cleanup(dir) }

        let start = ContinuousClock.now
        let output = try await runner.run([
            "status",
            "--porcelain=v2",
            "--branch",
            "--show-stash",
            "-z",
            "--untracked-files=all"
        ])
        let status = try PorcelainV2Parser.parse(output.stdout)
        let elapsed = ContinuousClock.now - start

        #expect(
            elapsed < Self.wallClockBudget,
            "100k-file status + parse took \(elapsed); budget is \(Self.wallClockBudget)"
        )
        // ~10% dirty fraction (synthesizer default); leave a wide
        // tolerance — the exact count varies with the 2-level fanout
        // bookkeeping. The point is that the parser sees thousands of
        // entries, not zero. Catches a regression where status would
        // emit the entries but the parser drops them silently.
        #expect(
            status.entries.count > Self.fileCount / 20,
            "expected the parser to surface > \(Self.fileCount / 20) modified entries; got \(status.entries.count)"
        )
        #expect(status.branch?.head == "main")
    }
}
