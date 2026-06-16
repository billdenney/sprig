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

### D3. `URL(fileURLWithPath:relativeTo:)` resolution differs under swift-foundation

- **Symptom** — relative paths resolved against a directory base land **one directory too high** (or, with `.path` on the still-relative URL, don't resolve at all) on swift-foundation toolchains (observed on the `main-snapshot-2026-05-27` / 6.5-dev pin; corelibs-foundation ≤6.3.x behaves the old way). In this repo: `gitdir: ../.git/modules/sub` from worktree `<super>/sub` resolved to `<tmp>/.git/modules/sub` instead of `<super>/.git/modules/sub`, so `resolveGitDir` threw `gitdirPointerTargetMissing` for every submodule-shaped pointer.
- **Root cause** — two stacked differences. (1) swift-foundation's `.path` on a relative URL no longer resolves against `baseURL`. (2) Its relative resolution follows strict RFC 3986: a base of `file:///a/b` (no trailing slash) has its last component **stripped** before applying the relative path — corelibs treated the base as a directory regardless. Both behaviors are version-dependent, so any `relativeTo:`-built file URL is a portability hazard.
- **Fix pattern** — don't compose directory-relative paths with `relativeTo:`. Append components explicitly and let `.standardized` collapse `..`/`.`, which is contract-stable on both implementations:
  ```swift
  // ❌ resolves differently across Foundation implementations
  let url = URL(fileURLWithPath: rel, relativeTo: dir).standardized

  // ✅ identical everywhere (git normalizes pointer separators to "/")
  var url = dir
  for component in rel.split(separator: "/") {
      url.appendPathComponent(String(component))
  }
  url = url.standardized
  ```
  Absolute inputs: branch on `(rel as NSString).isAbsolutePath` (handles `C:\`/UNC on Windows and `/` on POSIX) and construct directly.
- **Where in the repo** — `packages/GitCore/Sources/GitCore/GitMetadataPaths.swift` (`resolveGitDir`). That was the only `relativeTo:` call site; the SwiftLint-less guard is this catalog entry — grep for `relativeTo:` when bumping toolchains.
- **U:** Behavior delta between corelibs-foundation and swift-foundation; check whether swift-foundation considers it intentional (FoundationEssentials migration notes) before filing.

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
- **Root cause** — `start(paths:)` synchronously opens directory `HANDLE`s and spawns one detached `Task` per root. The Task body issues the first `ReadDirectoryChangesW`. There's a gap between `start` returning and the syscall actually entering, dominated by `Task.detached` scheduling. `ReadDirectoryChangesW` does NOT buffer events from before the call registers — anything that happens in that gap is silently dropped. On hosted Windows runners under load, the gap can exceed 500ms.
- **Fix pattern** — `FileWatcher.awaitReady() async`. Each watcher impl that has an async registration step (currently only `ReadDirectoryChangesWatcher`) signals "ready" from inside its per-root Task's preamble, just before its first kernel call. Tests `await watcher.awaitReady()` between `start()` and firing the mutation. Watchers whose `start()` is synchronously-live (`FSEventsWatcher`, `MockFileWatcher`) inherit a default no-op extension method, so the API is uniform across impls without forcing trivial overrides.
  ```swift
  let stream = watcher.start(paths: [root])
  await watcher.awaitReady()           // deterministic — replaces Task.sleep(N)
  try Data("…").write(to: file)
  ```
  The remaining gap between "ready signal fires" and "syscall enters" is userspace-only and microsecond-scale; any test client firing a mutation immediately afterward has hundreds of µs of Foundation overhead before the write hits the kernel.
- **Where in the repo** — `packages/PlatformKit/Sources/PlatformKit/FileWatcher.swift` (protocol + default impl); `packages/WatcherKit/Sources/Windows/WatcherKitWindows.swift` (override + `markRootReady()` callback); `packages/WatcherKit/Tests/WatcherKitTests/ReadDirectoryChangesWatcherTests.swift` (test usage).
- **U:** Not a bug — `ReadDirectoryChangesW` semantics are documented. The pattern of "watcher exposes an explicit readiness signal for tests" would be worth pulling into a Swift-on-server file-watcher library if one ever forms.

### E2. `Foundation.Data.write(to:)` on Windows uses `CREATE_ALWAYS`

- **Symptom** — a test that writes once to a pre-existing file, then asserts on receiving a `.modified` event from `ReadDirectoryChangesWatcher`, intermittently sees `.created` (or `.created` *and* `.modified`) on Windows.
- **Root cause** — Foundation's `Data.write(to:options:)` with the default empty options opens the file with `CREATE_ALWAYS` semantics on Windows, which truncates an existing file (effectively delete-then-create). The kernel may emit `FILE_ACTION_ADDED` (for the truncated recreate), `FILE_ACTION_MODIFIED` (for the subsequent write), or both, depending on driver and buffering state. macOS / Linux see a plain `O_WRONLY|O_TRUNC` → `.modified`.
- **Fix pattern** — write the test predicate against "any event for this file path," not against a specific `WatchEventKind`:
  ```swift
  // ❌ Flakes on Windows
  until: { evs in evs.contains { $0.kind == .modified } }

  // ✅ Robust everywhere; consumers re-stat regardless of kind anyway
  until: { evs in evs.contains { $0.path.lastPathComponent == "a.txt" } }
  ```
  Production consumers (badges, `RepoAgent`'s coalescer) re-stat on every event regardless of kind, so the kind is rarely load-bearing in real code — only in tests asserting on it.
- **Where in the repo** — `packages/WatcherKit/Tests/WatcherKitTests/ReadDirectoryChangesWatcherTests.swift` (`modifyDetected`).
- **U:** Not a bug — `CREATE_ALWAYS` is the documented Win32 semantics. Foundation could plausibly use `OPEN_EXISTING|O_TRUNC` equivalents to match Unix semantics, but that's a behaviour change with its own compat fallout. Live with it.

### E3. `FILE_NOTIFY_CHANGE_LAST_WRITE` / `..._SIZE` notifications delayed by kernel cache flush

- **Symptom** — `ReadDirectoryChangesW` emits create/remove events in milliseconds but write events arrive several seconds later, especially on hosted runners under I/O pressure.
- **Root cause** — Microsoft's `ReadDirectoryChangesW` documentation notes that `FILE_NOTIFY_CHANGE_LAST_WRITE` and `FILE_NOTIFY_CHANGE_SIZE` notifications are deferred until the kernel actually flushes the file's write cache to disk. `FILE_NOTIFY_CHANGE_FILE_NAME` (create / delete / rename) events fire immediately and are not subject to this delay.
- **Fix pattern** — give write-dependent tests headroom (10 s is comfortable on hosted runners); structurally prefer create / remove assertions when possible:
  ```swift
  private static let eventTimeoutSec: Double = 10.0  // kernel cache-flush headroom
  ```
- **Where in the repo** — `packages/WatcherKit/Tests/WatcherKitTests/ReadDirectoryChangesWatcherTests.swift` (`eventTimeoutSec`).
- **U:** Documented Win32 behaviour. Not actionable upstream.

### E4. Hosted-Windows agent process startup consumes seconds, not milliseconds

- **Symptom** — sprigctl CLI tests with `--duration 1.5` or shorter never observe a periodic stderr emission (stats lines, ready markers, etc.) on Windows hosted runners; the same tests pass instantly on macOS / Linux.
- **Root cause** — hosted-Windows agent startup (process spawn + Swift runtime init + Foundation init + git init + first refresh against a fresh fixture repo) routinely consumes 1–3 seconds under load, before any periodic tick is observable. The slow path is the combination of Windows process-creation overhead and Foundation cold-start. macOS / Linux settle in ~200 ms.
- **Fix pattern** — budget `--duration ≥ 5.0` on any sprigctl test that asserts on periodic output. macOS / Linux exit at the `--duration` cutoff regardless, so the runtime cost is uniform — there's no penalty for being generous on the Windows ceiling.
- **Where in the repo** — `cli/sprigctl/Tests/SprigctlAgentTests.swift` (`statsIntervalPrintsLines`).
- **U:** Not actionable upstream; it's the cost of hosted-Windows runners under load. A self-hosted Windows runner would tighten this materially but isn't planned.

### E5. macOS `Process.waitUntilExit()` deadlocks on fast-exiting children

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

### E6. `shutdown(2)` on a LISTENING socket wakes `accept(2)` on Linux but NOT on Darwin

- **Symptom** — both `lint-build-test (macos-14)` and `(macos-15)` froze ~30 s into `swift test` and were hard-killed by the 780 s watchdog (job then times out at `timeout-minutes: 15`). Red on `main`, identically, for every commit once the UDS server-close tests landed — not attributable to any one PR. The watchdog's `sample` dumps showed threads parked in `__accept` (`UnixSocketServer.startAcceptThread`, `UnixSocketServer.swift:144`); ~1166/1172 tests had closed, then the log stopped advancing because a couple of tests were `await`-parked forever (a parked async task occupies no thread — *not* an fd/CPU exhaustion signature; lsof showed a flat ~30 fds throughout).
- **Root cause** — `UnixSocketServer` runs a *detached* accept thread blocked in `accept(2)`, and `close()` woke it by calling `shutdown(listenFD, SHUT_RDWR)`. On **Linux** that unblocks the parked `accept()` (it returns `EINVAL`). On **Darwin** `shutdown()` on a *listening* (non-connected) socket fails `ENOTCONN` and leaves `accept()` parked. So on macOS `close()` never stopped the accept thread, the `connections` `AsyncStream` never `finish()`ed, and any test doing `await connections.next() == nil` (`serverCloseSemantics`, `rejectedPeerNeverServed`, the agent UDS teardown) parked forever — and since Swift Testing waits for *all* tests, the whole run hung. (`shutdown()` on a *connected* socket DOES wake a blocked `read(2)` on both platforms, so `UnixSocketTransport`'s reader close was fine — only the listening `accept` diverged.)
- **Fix pattern** — don't block in `accept()` and depend on a wake at all. Make the listen fd **non-blocking** and `poll(2)` it with a timeout, re-checking a `closed` flag each tick; `close()` just flips the flag (+ unlinks):
  ```swift
  // init: fcntl(listenFD, F_SETFL, ... | O_NONBLOCK)
  // accept loop:
  while true {
      if self?.isClosed != false { return }
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pfd, 1, 250 /* ms */)
      if ready <= 0 { if ready < 0, errno != EINTR { return }; continue }
      let client = accept(fd, nil, nil)
      if self?.isClosed != false { if client >= 0 { _ = systemClose(client) }; return }
      if client < 0 { if [EAGAIN, EWOULDBLOCK, EINTR, ECONNABORTED].contains(errno) { continue }; return }
      // … peer policy + yield
  }
  // close()/deinit: markClosed(); unlink(socketPath)   // no wake syscall, no fd alloc
  ```
  A self-connection wake also works portably but allocates a fresh fd at `close()` time, which can fail under the very fd pressure teardown must survive — the poll-timeout needs nothing at close but the flag flip. The mechanism has no Linux/macOS divergence, so the Linux regression test exercises exactly what macOS runs.
  - **Sub-gotcha the non-blocking listener forces:** on **BSD/Darwin, `accept(2)` INHERITS the listener's `O_NONBLOCK`** (Linux does not), so each accepted fd must be set back to blocking (`fcntl(client, F_SETFL, flags & ~O_NONBLOCK)`) — otherwise the accepted transport's reader `read(2)` returns `EAGAIN` immediately and the connection closes the instant it opens (surfaced macOS-only as `Caught error: closed` across the round-trip tests + the agent UDS e2e). This is invisible on Linux, so the only proof is hosted-macOS CI.
- **Where in the repo** — `packages/TransportKit/Sources/Linux/UnixSocketServer.swift` (`O_NONBLOCK` listen fd + the `poll`-timeout accept loop); regression tests in `UnixSocketTransportTests.swift` ("a server dropped without close() finishes connections …").
- **U:** Well-documented BSD-vs-Linux divergence, not an upstream bug. Relying on `shutdown(listenfd)` to wake a listening `accept()` is a Linux-ism; the portable answers are a `poll`-with-timeout loop (used here) or a self-pipe/self-connection wake. Mirror this for any future listening-socket loop.

---

## F. Known upstream bugs we work around

### F1. `Foundation.findMaximumOpenFromProcSelfFD()` SIGSEGV on Linux

- **Symptom** — `*** Program crashed: Bad pointer dereference ...` during Linux test execution. The crashing thread's stack always involves `Process.run()` or `Process.setup()`; the explicit `findMaximumOpenFromProcSelfFD() + 261` frame may or may not appear, depending on how deep into the spawn sequence the corruption surfaces (we've observed crashes at `Process.run() + 6428` and bare libc frames where `findMaximumOpenFromProcSelfFD` had already returned but corrupted memory bit later). The *other* threads in the dump are typically blocked in `FileHandle._readDataOfLength` waiting on child pipes — that's a red herring, not the crash site. Linux-only — Apple Foundation and Windows Foundation gate this code behind `#if !canImport(Darwin) && !os(Windows)`.
- **Root cause** — `Sources/Foundation/Process.swift` in swift-corelibs-foundation does a 256-byte struct-copy of `dirEntPtr.pointee.d_name`. glibc's `readdir(3)` returns dirents sized to `d_reclen` (24–32 bytes for short filenames like `/proc/self/fd` integers); the bulk copy overruns into the next (potentially unmapped) page. The hit rate scales with concurrent `Process.run()` activity — observed in this repo at ~5 % per CI run, rising when long-duration test fixtures keep many child processes in flight (e.g. `sprigctl agent --duration 5.0` polling git status repeatedly).
- **Fix pattern** — the upstream fix (`_direntName` / `_direntNameLength` helpers, the same pattern PR #4892 applied to `FileManager+POSIX.swift`) **merged to corelibs-foundation `main` as `81eb85a` on 2026-05-19**, originating from our fork branch. No stable toolchain contains it yet (6.3.2 predates it by 73 commits; `release/6.4.x` branched 6 commits before it), so the Linux toolchain is **pinned to a main snapshot**: `.swift-version` → `main-snapshot-2026-05-27` (swiftly-managed local dev) and the ci-linux.yml container → a pinned `swiftlang/swift:nightly-main-noble` digest. Verified locally: 3 consecutive full-suite runs green under the snapshot, where 6.3.1 crashed 3-of-3. The workflow's retry block (max 3 attempts) stays as belt-and-suspenders until the pin moves back to a stable release — tracked as `UP-5472` in `docs/planning/audit-followups.md`.
- **What did NOT work** — serializing all `process.run()` launches behind a global lock (the "concurrent scans trigger it" theory). Implemented and disproven 2026-06-09: the crash reproduced with launches fully serialized (`__memmove_avx_unaligned_erms` under `Process.run()`, inside the lock). The over-read needs only fd-table geometry, which a ~900-test suite provides regardless of launch concurrency. Don't resurrect that approach.
- **Where in the repo** — `.swift-version`, `.github/workflows/ci-linux.yml` (image pin + the retry block, currently `max=3`).
- **Diagnostic check** — when triaging a Linux build-portable failure: look for `Process.run` / `Process.setup` frames in any thread's stack. If present, it's F1. The retry-script's "Likely the upstream Foundation findMaximumOpenFromProcSelfFD() flake" warning is optimistic — it fires on every first-attempt failure, not on signature match.
- **U:** Filed as `swiftlang/swift-corelibs-foundation#5472`; fixed upstream by `81eb85a` (from `billdenney/swift-corelibs-foundation:fix/process-d_name-buffer-overrun`). Watch for a 6.3.x cherry-pick or the `release/6.4.x` automerge to absorb it, then re-pin to stable and drop the workflow retry (`UP-5472`).

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

### F3. Async-test hang from a lost AsyncStream finish (exposed by main-snapshot scheduling)

- **Symptom** — `swift test` stalls indefinitely: one async test never completes (observed:
  WatcherKit's "stream yields emitted events in order"), its runner never exits, the
  remaining test products never run, and the orphaned runner holds the `.build` lock —
  stalling later `swift build` in the same checkout. Intermittent (~1 in 5 full local runs
  on the UP-5472 snapshot pin); effectively never on 6.3.x, whose scheduler rarely hit the
  window.
- **Diagnostic trap** — the hung runner shows main in `sigsuspend` + one idle `ep_poll`
  worker (`/proc/<pid>/task/*/wchan`, no ptrace needed). That is NOT proof the tests
  finished: a parked async test awaiting a never-resumed continuation occupies **no thread**
  and looks identical. Diff `◇ started` vs `✔ passed` test names in the log to find the
  actual unfinished test before blaming the exit path (we mis-attributed this first).
- **Root cause** — an in-repo race, not the toolchain: `MockFileWatcher.start(paths:)`
  attached its continuation via an unstructured Task (async actor hop); a fast `stop()`
  could win the actor first, the nil-continuation `finish()` was lost, and the late attach
  installed a continuation nobody would ever finish → consumer `for await` hangs forever.
  The newer toolchain's scheduling merely widened the window.
- **Fix pattern** — latch the finish: `finish()` sets a flag; `attach` replays pending
  events and immediately finishes when the latch is set. Any "create stream → attach
  continuation asynchronously" shape needs this. Regression-tested with a 500-iteration
  race hammer (`stopBeforeAttachStillFinishes`).
- **Where in the repo** — `packages/WatcherKit/Sources/WatcherKit/MockFileWatcher.swift`;
  ci-linux.yml carries `timeout-minutes: 30` as a general anti-hang failsafe. After any
  timed-out local run: `pkill -f test-runner; pkill -f swift-test` (orphans hold the
  package lock) — and mind that a careless `pkill -f` pattern can match your own wrapper
  shell.
- **U:** None — in-repo bug, fixed. The lesson generalizes: audit other lazily-attached
  AsyncStream continuations for lost-finish races when toolchain bumps shift scheduling.

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

## G. Git environment differences

### G1. Git for Windows defaults `core.autocrlf=true` — worktree bytes differ per OS

- **Symptom** — a test writes `"line\n"` (LF), drives git through any worktree-writing operation (`stash push`'s implicit reset, `stash apply`/`pop`, `checkout`, `reset --hard`, merge), then reads the file back and gets `"line\r\n"`. Asserting byte-exact LF content fails on Windows only — deterministically, not load-dependent (which distinguishes it from E1/E3 at a glance, though the failure *reads* similarly: "file content isn't what I just made git produce").
- **Root cause** — Git for Windows ships `core.autocrlf=true` in its **system** gitconfig. Every checkout-path write runs the smudge conversion LF → CRLF for files git classifies as text. Fixture repos created with `git init` inherit it; macOS/Linux git defaults to no conversion, so the same test passes there.
- **Fix pattern** — fixture repos whose tests assert post-checkout bytes pin the conversion off at creation: `git config core.autocrlf false`. This keeps assertions byte-exact (strict) on every OS instead of loosening them to tolerate `\r`. Production code is unaffected — Sprig defers to the user's git and never reads worktree bytes around these operations.
- **Where in the repo** — `packages/GitCore/Tests/GitCoreTests/StashOpsBrowseTests.swift`, `packages/TaskWindowKit/Tests/TaskWindowKitTests/StashViewModelTests.swift` (both `makeRepo` helpers; ADR 0079 slice — the first byte-exact post-checkout reads in the suite).
- **U:** Not a bug — documented, intentional Git for Windows packaging default. Documentation only.

### G2. git 2.54 (Windows build): `credential.helper=""` no longer resets the helper chain

- **Symptom** — credential fixtures that "reset" the helper chain with a local empty-string entry (`git config credential.helper ""` then `--add` the test helper) still consult the SYSTEM-scope helper. On hosted `windows-2022` (working Git Credential Manager) this leaked stored secrets ACROSS fixtures: "retrieve with nothing stored" returned an earlier test's secret, and one `clone --browse` test found a stale token and reached the real GitHub API. Hosted Windows CI was red from the moment the credential tests landed (#145) through #150. The local VM (same git 2.54, same system `helper = manager`) stayed green only because GCM is non-functional over its SSH session — silent luck, not isolation.
- **Root cause (empirically pinned)** — with a fake system scope via `GIT_CONFIG_SYSTEM` pointing at a poison `store` helper: git 2.43 (Linux) honors the documented reset (poison never written); **git 2.54.0.windows.1 writes the poison file** — the earlier-scope helper runs despite the local `""` entry. (Whether this is a 2.54 regression or an intentional semantics change upstream is unconfirmed; the fix below doesn't depend on the answer.) Git for Windows additionally reads a ProgramData config scope, so there can be TWO system-level helper entries.
- **Fix pattern** — isolate at the ENVIRONMENT level, which is version-proof: `GIT_CONFIG_NOSYSTEM=1` (disables both Windows system scopes) plus global-config redirection — `GIT_CONFIG_GLOBAL=<null device>` when driving git through `Runner.environmentOverrides` (they apply after the scrub), or `HOME`/`USERPROFILE`/`XDG_CONFIG_HOME` → an empty fixture dir when the git runs inside a spawned sprigctl (the Runner scrubs `GIT_CONFIG_GLOBAL` from inherited env, so the home redirect is the reliable cross-process carrier). Verified on git 2.54: `git config --show-origin --get-all credential.helper` then lists exactly the fixture's local entry — and that listing is now a pinned test.
- **Where in the repo** — `packages/CredentialKit/Tests/.../GitCredentialChainStoreTests.swift` (fixture + the `--show-origin` pin), `cli/sprigctl/Tests/SprigctlSupport.swift` (`credentialIsolationEnvironment(home:)` + the `Sprigctl.run` environment parameter), the credential/forge/clone CLI fixtures.
- **U:** Worth an upstream question — gitcredentials(7) documents the empty-string reset; if 2.54 changed it deliberately the docs lag, if not it's a regression. File against git-for-windows with the two-version repro once triaged against a 2.54 Linux build (to separate "2.54" from "Windows build").

---

## Upstream suggestion shortlist

Distilling the `U:` items above, ranked by where filing a fix would have the highest leverage:

1. **`swiftlang/swift-corelibs-foundation#5472`** — already filed (F1). The `Process.swift` `d_name` buffer overrun. Fix exists on a fork. Tracking re-enablement of the CI workflow's retry-removal once the fix ships in a Swift release.
2. **`swiftlang/swift-corelibs-foundation`** — align `Bundle.urls(forResourcesWithExtension:subdirectory:)` return type with Apple's `[URL]?` (B2). Small, contained, would close a Linux-only quirk.
3. **`swiftlang/swift-package-manager`** — emit `Bundle.module` as `public` (or generate a `Bundle.<TargetName>` accessor that's public) so library APIs can default a `Bundle:` parameter to their own bundled resources (B1). Bigger surface change; would need a Swift Evolution discussion.
4. **`swiftlang/swift`** — investigate `UnsafeRawPointer.load` argument-order strictness mismatch between Linux + Windows toolchains of the same Swift version (D1). Likely a forum question first, then a JIRA if confirmed.
5. **`swiftlang/swift`** — investigate `NSLock.lock()/unlock()` async-availability difference (error on Windows, warning on Linux) for the same Swift version (D2). Same shape as D1.

If we land contributions for any of these, mark the entry "U:" line with the PR / issue number and the "filed" date.
