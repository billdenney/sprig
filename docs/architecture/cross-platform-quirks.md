# Cross-Platform Quirks Catalog

A working catalogue of behaviour differences and toolchain footguns we've hit while keeping Sprig's engine green on macOS + Linux + Windows. Companion to [`cross-platform.md`](cross-platform.md) — that doc covers the architecture (tiers, hard rules, IO conventions); this one covers the *operational* surprises: what compiled-and-passed on one toolchain but broke on another, and what's actionable as an upstream fix vs. just a quirk to work around.

## How to use this doc

When a CI failure surfaces on one platform but not another, search this file. If the symptom isn't here, **add an entry as part of the fix PR**. The entry should give the next maintainer enough context to recognise the same trap in 30 seconds.

Each entry follows a consistent shape:

- **Symptom** — what you see in CI logs / compile errors / runtime crashes.
- **Root cause** — the actual underlying mechanism.
- **Fix pattern** — the idiom we settled on, with the file path of a real example.
- **Upstream signal** — is this an upstream bug worth filing? A by-design semantic? A toolchain mismatch we just live with?

Entries are grouped by category. Items prefixed `U:` are candidates for upstream fixes; we may file or contribute these.

---

## A. Module import differences

### A1. `URLSession` lives in `FoundationNetworking` on Linux/Windows

- **Symptom** — `error: value of type 'URLSession' (aka 'AnyObject') has no member 'data'` when compiling code that uses `URLSession.data(for:)` on Linux.
- **Root cause** — swift-corelibs-foundation splits the larger Foundation surface into submodules. `URLSession`, `URLRequest`, `URLResponse`, `HTTPURLResponse`, `URLError` are in `FoundationNetworking`. Apple's Foundation has them in the umbrella module.
- **Fix pattern** — capability check, not OS check:
  ```swift
  import Foundation
  #if canImport(FoundationNetworking)
      import FoundationNetworking
  #endif
  ```
  `canImport` is allowed under CLAUDE.md hard rule 2's "trivial cross-platform constants" carve-out (it's a capability check, not behaviour branching).
- **Where in the repo** — `packages/AIKit/Sources/AIKit/HTTPClient.swift`, `packages/AIKit/Tests/AIKitTests/OllamaProviderTests.swift`.
- **U:** Foundation modularity is intentional; not an upstream bug.

---

## B. Bundle / resource quirks

### B1. `Bundle.module` is `internal`, not `public`

- **Symptom** — `error: static property 'module' is not '@usableFromInline' or public` when a public function signature defaults a parameter to `Bundle.module`.
- **Root cause** — SwiftPM generates `Bundle.module` as `extension Foundation.Bundle { static let module: Bundle = { ... }() }` with `internal` visibility. It can't appear in the public ABI of consuming modules.
- **Fix pattern** — keep the bundle as an implementation detail; don't expose a `Bundle` parameter on public APIs. Provide named "bundled" variants instead:
  ```swift
  // ❌ Wrong — leaks Bundle.module into public signature
  public static func load(in bundle: Bundle = .module) throws -> Prompt { ... }

  // ✅ Right — bundle stays internal
  public static func loadBundled(named name: String) throws -> Prompt {
      let url = Bundle.module.url(forResource: name, withExtension: "md")
      ...
  }
  ```
- **Where in the repo** — `packages/AIKit/Sources/AIKit/PromptLoader.swift` (`loadBundled(named:)` vs the directory-based `load(named:from:)`).
- **U:** `swiftlang/swift-package-manager`: could SwiftPM emit `Bundle.module` as `public` (or generate a `Bundle.<TargetName>` accessor that's public)? Would close the "library wants to expose its own bundled resources" hole without per-library workarounds.

### B2. `Bundle.urls(forResourcesWithExtension:subdirectory:)` returns `[NSURL]?` on Linux

- **Symptom** — `error: 'NSURL' is not implicitly convertible to 'URL'; did you mean to use 'as' to explicitly convert?` after passing the result to anything expecting `URL`.
- **Root cause** — swift-corelibs-foundation's `Bundle` method returns `[NSURL]?` even though Apple's returns `[URL]?`. Foundation-on-Apple did the bridging years ago; the open-source port hasn't caught up.
- **Fix pattern** — `.map { $0 as URL }`:
  ```swift
  let nsurls = Bundle.module.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
  let urls = nsurls.map { $0 as URL }
  ```
- **Where in the repo** — `packages/AIKit/Sources/AIKit/PromptLoader.swift` (`loadAllBundled()`).
- **U:** `swiftlang/swift-corelibs-foundation`: align `Bundle.urls(...)` return type with Apple's `[URL]?`. **Filable.**

### B3. SwiftPM `.process("Subdir")` flattens resources into bundle root

- **Symptom** — `Bundle.module.urls(forResourcesWithExtension: "md", subdirectory: "Prompts")` returns nil, even though the files are in `Sources/AIKit/Prompts/`.
- **Root cause** — `.process(_:)` resource declaration processes (potentially transforms) the listed directory's contents and stores them at the bundle root with their original filenames. `.copy(_:)` preserves the directory structure. SwiftPM's behaviour here is documented but counter-intuitive.
- **Fix pattern** — pass `subdirectory: nil` when locating bundled resources declared via `.process`:
  ```swift
  Bundle.module.urls(forResourcesWithExtension: "md", subdirectory: nil)
  ```
- **Where in the repo** — `Package.swift`'s AIKit target uses `resources: [.process("Prompts")]`; the loader queries with `subdirectory: nil`.
- **U:** SwiftPM docs could clearer on `.process` vs `.copy` semantics for resource directories.

---

## C. Win32 type mapping (Swift on Windows)

### C1. Win32 `BOOL` maps to Swift `Bool`, not `Int`

- **Symptom** — `error: binary operator '==' cannot be applied to operands of type 'Bool' and 'Int'` after calling a Win32 API like `ReadDirectoryChangesW`, `CancelIoEx`, `CloseHandle`.
- **Root cause** — Windows's `BOOL` is `typedef int BOOL` in `winnt.h`. The Swift WinSDK shim maps it to Swift's native `Bool` (more idiomatic than `WindowsBool` would be).
- **Fix pattern** — treat as `Bool`:
  ```swift
  let success = ReadDirectoryChangesW(handle, buffer, /* ... */)
  if !success {  // NOT: if success == 0
      let err = GetLastError()
      ...
  }
  ```
- **Where in the repo** — `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (`runWatchLoop`).
- **U:** Not a bug. Document it inline at any Win32 callsite.

### C2. UTF-16 strings need explicit null-termination

- **Symptom** — `CreateFileW` returns `INVALID_HANDLE_VALUE`; `GetLastError()` returns `ERROR_PATH_NOT_FOUND` for a path that exists.
- **Root cause** — Win32 `LPCWSTR` is a null-terminated UTF-16 string. Swift's `String.utf16` view doesn't include a null terminator; passing `&utf16Array` to a `WCHAR*` parameter reads garbage past the last code unit until it hits a stack zero (or doesn't).
- **Fix pattern** — append explicit `0` before passing the pointer:
  ```swift
  var wide = Array(pathString.utf16)
  wide.append(0)  // explicit null terminator for LPCWSTR

  wide.withUnsafeBufferPointer { buf in
      CreateFileW(buf.baseAddress, ...)
  }
  ```
- **Where in the repo** — `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (`openDirectoryHandle`).
- **U:** Could `WinSDK` provide an LPCWSTR-aware bridge from `String`? Probably out of scope for the binding layer.

### C3. `FILE_NOTIFY_INFORMATION` filename is *not* null-terminated

- **Symptom** — garbage tail bytes on parsed filenames from `ReadDirectoryChangesW`.
- **Root cause** — the `FileName[1]` member at the end of `FILE_NOTIFY_INFORMATION` is a variable-length array (the `[1]` is just to give it a name; the real length is `FileNameLength / 2` WCHARs). It's NOT null-terminated.
- **Fix pattern** — copy WCHARs into an array of size `nameWordCount + 1`, leave the trailing slot as `0`, then `String(decodingCString: chars, as: UTF16.self)`:
  ```swift
  var chars = [UInt16](repeating: 0, count: nameWordCount + 1)
  chars.withUnsafeMutableBufferPointer { dst in
      dst.baseAddress!.update(
          from: nameStart.assumingMemoryBound(to: UInt16.self),
          count: nameWordCount
      )
  }
  let name = String(decodingCString: chars, as: UTF16.self)
  ```
- **Where in the repo** — `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (`parseAndEmit`).

---

## D. Strict toolchain differences

These are cases where the same Swift source code compiles on one platform's toolchain but fails on another's. They're not behaviour bugs in Swift — they're stricter enforcement in a newer/different toolchain.

### D1. `UnsafeRawPointer.load` argument order strictness

- **Symptom** — `error: argument 'fromByteOffset' must precede argument 'as'` on Windows Swift 6.3.1; same code compiles on Linux 6.3.1 and macOS 6.3.
- **Root cause** — `UnsafeRawPointer.load<T>(fromByteOffset:as:)` declares the labels in that order. Swift normally enforces argument-label ordering strictly at call sites, but some toolchain combinations have apparently relaxed it for stdlib generics. The Windows toolchain enforces.
- **Fix pattern** — match the declared order:
  ```swift
  // ❌ Compiles on Linux, fails on Windows
  recordPtr.load(as: DWORD.self, fromByteOffset: 0)

  // ✅ Strict-form correct everywhere
  recordPtr.load(fromByteOffset: 0, as: DWORD.self)
  ```
- **Where in the repo** — `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (`parseAndEmit`).
- **U:** `swiftlang/swift`: investigate whether Linux's toolchain version skipped a label-order check it should have applied. Worth a forum question.

### D2. `NSLock.lock()` / `.unlock()` async-context availability

- **Symptom** — `error: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead` on Windows Swift 6.3.1. Linux only *warns*.
- **Root cause** — Swift 6's strict concurrency forbids bare lock/unlock pairs inside `async` functions (the actor scheduler can reschedule between them, causing deadlock). Windows's toolchain enforces as error; Linux's same-version toolchain emits a warning.
- **Fix pattern** — use the scoped `withLock` API:
  ```swift
  // ❌ unavailable from async — Windows error, Linux warning
  public func stop() async {
      lock.lock()
      let snap = state
      lock.unlock()
  }

  // ✅ async-safe
  public func stop() async {
      let snap = lock.withLock { state }
  }
  ```
- **Where in the repo** — `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (`stop()`).
- **U:** Toolchain inconsistency between Linux + Windows of the same Swift version. Worth a `swiftlang/swift` issue.

---

## E. Filesystem semantics

### E1. Windows `FindFirstFile` visibility lag (up to seconds)

- **Symptom** — a freshly-`Data.write(to:)`'d file isn't returned by `FileManager.contentsOfDirectory` for 2–5+ seconds on hosted Windows runners under load. Polling watchers miss the create; status snapshots see the pre-write state.
- **Root cause** — Windows directory enumeration goes through the user-mode `FindFirstFile`/`FindNextFile` APIs which read from a cached directory snapshot. The NT kernel updates lazily; the cache can lag noticeably under I/O pressure.
- **Fix pattern** — two-fold:
  1. **For production code that needs realtime updates**: use `ReadDirectoryChangesW` (kernel-pushed notifications, milliseconds) instead of polling. See `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift`.
  2. **For tests that intentionally exercise the polling fallback**: give them ≥ 5 s of budget on Windows, or `#if !os(Windows)`-guard them as "live FS coverage for the platforms where the polling watcher is the production path."
- **Where in the repo** — `packages/WatcherKit/Tests/WatcherKitTests/PollingFileWatcherTests.swift` (live-FS suite skipped on Windows per `disabled-tests.md`); `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (`ReadDirectoryChangesWatcher`, the reactive replacement).
- **U:** Not a bug — `FindFirstFile`'s caching is documented Win32 behaviour. Documentation only.

### E1a. Test fixture race against `ReadDirectoryChangesW` registration

- **Symptom** — `ReadDirectoryChangesWatcher` test sees `events: []` for a file mutation fired shortly after `watcher.start(paths:)`. Symptom-identical to E1 but the underlying cause is different: the registration race, not the visibility lag.
- **Root cause** — `start(paths:)` synchronously opens directory `HANDLE`s and spawns one detached `Task` per root. The Task body issues the first `ReadDirectoryChangesW`. There's a gap between `start` returning and the syscall actually entering, dominated by `Task.detached` scheduling. `ReadDirectoryChangesW` does NOT buffer events from before the call registers — anything that happens in that gap is silently dropped. On hosted Windows runners under load, the gap can exceed 500ms (see PR #89's CI runs 25689125187 + 25689738154 + previous-iteration history).
- **Fix pattern** — `FileWatcher.awaitReady() async`. Each watcher impl that has an async registration step (currently only `ReadDirectoryChangesWatcher`) signals "ready" from inside its per-root Task's preamble, just before its first kernel call. Tests `await watcher.awaitReady()` between `start()` and firing the mutation. Watchers whose `start()` is synchronously-live (`FSEventsWatcher`, `MockFileWatcher`) inherit a default no-op extension method, so the API is uniform across impls without forcing trivial overrides.
  ```swift
  let stream = watcher.start(paths: [root])
  await watcher.awaitReady()           // deterministic — replaces Task.sleep(N)
  try Data("…").write(to: file)
  ```
  The remaining gap between "ready signal fires" and "syscall enters" is userspace-only and microsecond-scale; any test client firing a mutation immediately afterward has hundreds of µs of Foundation overhead before the write hits the kernel.
- **Where in the repo** — `packages/PlatformKit/Sources/PlatformKit/FileWatcher.swift` (protocol + default impl); `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (override + `markRootReady()` callback); `packages/WatcherKit/Tests/WatcherKitTests/ReadDirectoryChangesWatcherTests.swift` (test usage).
- **U:** Not a bug — `ReadDirectoryChangesW` semantics are documented. The pattern of "watcher exposes an explicit readiness signal for tests" would be worth pulling into a Swift-on-server file-watcher library if one ever forms.

### E2. macOS `Process.waitUntilExit()` deadlocks on fast-exiting children

- **Symptom** — `Process.run(); process.waitUntilExit()` hangs indefinitely when the spawned child exits in < 50ms.
- **Root cause** — race in Foundation's `Process` cleanup machinery: the termination handler fires *before* `waitUntilExit()` registers the wait, then the wait never wakes.
- **Fix pattern** — `GitCore.ProcessTerminationGate` — register the gate via `terminationHandler` *before* `run()`, then `await gate.wait(processIsRunning:)`:
  ```swift
  let gate = ProcessTerminationGate()
  process.terminationHandler = { _ in gate.signal() }
  try process.run()
  await gate.wait(processIsRunning: { process.isRunning })
  ```
- **Where in the repo** — `packages/GitCore/Sources/GitCore/ProcessExit.swift`; used by `cli/sprigctl/Tests/SprigctlSupport.swift` and `packages/GitCore/Sources/GitCore/Runner.swift`.
- **U:** Pre-existing Foundation issue; `ProcessTerminationGate` is the standard workaround pattern in Swift-on-server ecosystems.

---

## F. Known upstream bugs we work around

### F1. `Foundation.findMaximumOpenFromProcSelfFD()` SIGSEGV on Linux

- **Symptom** — `*** Program crashed: Bad pointer dereference ...` with `findMaximumOpenFromProcSelfFD() + 60 in libFoundation.so` in the stack. ~5 % flake rate during test suites that spawn many `Process` instances. Linux-only — Apple Foundation and Windows Foundation gate this code behind `#if !canImport(Darwin) && !os(Windows)`.
- **Root cause** — `Sources/Foundation/Process.swift` in swift-corelibs-foundation does a 256-byte struct-copy of `dirEntPtr.pointee.d_name`. glibc's `readdir(3)` returns dirents sized to `d_reclen` (24–32 bytes for short filenames like `/proc/self/fd` integers); the bulk copy overruns into the next (potentially unmapped) page.
- **Fix pattern** — at the workflow level: one automatic retry in `.github/workflows/ci-linux.yml`. At the source level: use the existing `_direntName` / `_direntNameLength` helpers in `ForSwiftFoundationOnly.h` (the same pattern PR #4892 applied to `FileManager+POSIX.swift`).
- **Where in the repo** — `.github/workflows/ci-linux.yml` (the retry-once block).
- **U:** Filed as `swiftlang/swift-corelibs-foundation#5472`. Fix on a fork at `billdenney/swift-corelibs-foundation:fix/process-d_name-buffer-overrun`. Drop the workflow retry when a Swift toolchain release picks up the fix.

### F2. `ordo-one/package-benchmark` unsupported on Windows

- **Symptom** — `swift build` failures on Windows around benchmark-target resource files.
- **Root cause** — `package-benchmark` writes per-platform threshold JSON files with names that collide alphabetically on Windows's case-insensitive default filesystem. Tracked as ordo-one/package-benchmark#308.
- **Fix pattern** — gate the benchmark target out on Windows in `Package.swift`:
  ```swift
  #if os(Windows)
      let benchmarkTargets: [Target] = []
  #else
      let benchmarkTargets: [Target] = [...]
  #endif
  ```
- **Where in the repo** — `Package.swift` (top of the file, after `tier2Targets`).
- **U:** Tracked upstream. Re-include benchmark target on Windows when ordo-one/package-benchmark#308 lands.

---

## G. CI / tooling gaps

### G1. `swift:6.3.1-noble` Docker image doesn't ship `git`

- **Symptom** — `GitCore` integration tests fail with "command not found" in Linux CI.
- **Root cause** — the official Swift Linux images are minimal Ubuntu base + Swift; `git` is not in the closure.
- **Fix pattern** — install in the workflow before tests:
  ```yaml
  - name: Install git
    run: |
      apt-get update
      apt-get install -y --no-install-recommends git
  ```
- **Where in the repo** — `.github/workflows/ci-linux.yml`, `.github/workflows/ai-evals.yml`.

### G2. Linux needs `libjemalloc-dev` for `package-benchmark`

- **Symptom** — `'jemalloc/jemalloc.h' file not found` during `swift build` on Linux when package-benchmark is in the build graph.
- **Root cause** — `package-benchmark` links jemalloc as a system library on Linux + macOS for accurate malloc tracking; bundled on macOS, system dep on Linux. Even `swift test --filter X` builds every target in the package, including benchmarks, so the dependency is unavoidable.
- **Fix pattern** — install in any CI workflow that runs `swift build` or `swift test` on Linux:
  ```yaml
  - run: apt-get install -y --no-install-recommends libjemalloc-dev
  ```
- **Where in the repo** — `.github/workflows/ci-linux.yml`, `.github/workflows/ai-evals.yml`.

### G3. SwiftLint binary on Linux Swift 6.3.1 SIGILLs

- **Symptom** — Direct invocation of the SwiftLint binary on Linux Swift 6.3.1 crashes with SIGILL inside `libFoundation.so`.
- **Root cause** — interaction between SwiftLint's stripped binary and the Swift 6.3.1 Linux runtime. The same SwiftLint binary works fine in a Docker container with a different runtime.
- **Fix pattern** — `script/lint` (and `script/format`) prefer Docker on Linux, fall back to the host binary on macOS:
  ```bash
  if [[ "$(uname -s)" == "Linux" ]] && command -v docker >/dev/null 2>&1; then
      docker run --rm -v "$PWD:/work" -w /work ghcr.io/realm/swiftlint:0.63.2 swiftlint ...
  else
      swiftlint ...
  fi
  ```
- **Where in the repo** — `script/lint`, `script/format`.

### G4. `swift test --filter X` still builds *all* targets

- **Symptom** — `swift test --filter AIKit` fails because an unrelated target (e.g., `SprigCoreBenchmarks` needing jemalloc) failed to compile.
- **Root cause** — SwiftPM's `--filter` only narrows *which tests run*, not which targets compile. The whole package builds first.
- **Fix pattern** — system-level deps for the whole graph must be present even when filtering. Either install them in CI (see G2) or temporarily exclude the offending target via conditional `Package.swift`.

---

## H. Lint / format conflicts

SwiftLint and SwiftFormat disagree on a few stylistic choices that show up in the same source files. Each conflict has a documented Sprig idiom.

### H1. Multi-clause `if` brace placement

- **Conflict** — SwiftFormat puts `{` on its own line for multi-clause `if` (`if A, B { ... }`); SwiftLint's `opening_brace` rule rejects that and wants `{` on the same line as the declaration.
- **Sprig idiom** — collapse the conditions into a single Bool, or convert to a `guard` chain with early return:
  ```swift
  // ❌ Both forms fail one or the other
  if cond1,
     cond2
  {
      doThing()
  }

  // ✅ Collapse to single condition
  let canDoThing = cond1 && cond2
  if canDoThing {
      doThing()
  }
  ```
- **Where in the repo** — `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (`parseAndEmit`).

### H2. SwiftLint nesting (max 1 level)

- **Symptom** — `error: Nesting Violation: Types should be nested at most 1 level deep (nesting)`.
- **Sprig idiom** — move the inner type to a sibling of the would-be outer type:
  ```swift
  // ❌ 2 levels deep
  public struct EnvironmentReport {
      public struct GitTooling {
          public struct GitSemver { ... }  // ← violation
      }
  }

  // ✅ Sibling
  public struct EnvironmentReport {
      public struct GitTooling { let version: GitSemver }
      public struct GitSemver { ... }
  }
  ```
- **Where in the repo** — `packages/DiagKit/Sources/DiagKit/EnvironmentReport.swift`, `packages/AIKit/Sources/AIKit/OllamaWire.swift`.

### H3. SwiftLint `large_tuple` (max 2 elements)

- **Symptom** — `error: Large Tuple Violation: Tuples should have at most 2 members`.
- **Sprig idiom** — introduce a small `private struct Fixture { ... }` (or return the existing value type that already has those fields):
  ```swift
  // ❌
  func mkFixture() -> (parent: URL, helper: URL, nested: URL?) { ... }

  // ✅
  private struct Fixture { var parent: URL; var helper: URL; var nested: URL? }
  func mkFixture() -> Fixture { ... }
  ```
- **Where in the repo** — `packages/SubmoduleKit/Tests/SubmoduleKitTests/SubmoduleStatusTests.swift`, `cli/sprigctl/Tests/SprigctlSubmoduleTests.swift`, `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (`stop()` returns the existing `State` snapshot value type).

### H4. SwiftLint `force_try` (no `try!`)

- **Symptom** — `error: Force Try Violation: Force tries should be avoided`.
- **Sprig idiom** — propagate via `throws` (even in test helpers, since Swift Testing supports throwing test functions out of the box). For genuinely-cannot-fail cases, switch to `try? ... ?? fallback` with a sane default.
- **Where in the repo** — `packages/AIKit/Tests/AIKitTests/OllamaProviderTests.swift` (`okResponseBody` is `throws` rather than `try!`).

### H5. SwiftLint `line_length` (140 chars)

- **Symptom** — `error: Line Length Violation: Line should be 140 characters or less`.
- **Sprig idiom** — break long `@Argument(help: ...)` strings via multi-line `"""` literals:
  ```swift
  @Argument(
      help: """
      Repository worktree root (defaults to the current directory). Used as the runner's cwd; \
      doesn't affect the report shape.
      """
  )
  var path: String?
  ```
- **Where in the repo** — `cli/sprigctl/Sources/DiagnoseCommand.swift`.

---

## Upstream suggestion shortlist

Distilling the `U:` items above, ranked by where filing a fix would have the highest leverage:

1. **`swiftlang/swift-corelibs-foundation#5472`** — already filed (F1). The `Process.swift` `d_name` buffer overrun. Fix exists on a fork. Tracking re-enablement of the CI workflow's retry-removal once the fix ships in a Swift release.
2. **`swiftlang/swift-corelibs-foundation`** — align `Bundle.urls(forResourcesWithExtension:subdirectory:)` return type with Apple's `[URL]?` (B2). Small, contained, would close a Linux-only quirk.
3. **`swiftlang/swift-package-manager`** — emit `Bundle.module` as `public` (or generate a `Bundle.<TargetName>` accessor that's public) so library APIs can default a `Bundle:` parameter to their own bundled resources (B1). Bigger surface change; would need a Swift Evolution discussion.
4. **`swiftlang/swift`** — investigate `UnsafeRawPointer.load` argument-order strictness mismatch between Linux + Windows toolchains of the same Swift version (D1). Likely a forum question first, then a JIRA if confirmed.
5. **`swiftlang/swift`** — investigate `NSLock.lock()/unlock()` async-availability difference (error on Windows, warning on Linux) for the same Swift version (D2). Same shape as D1.

If we land contributions for any of these, mark the entry "U:" line with the PR / issue number and the "filed" date.
