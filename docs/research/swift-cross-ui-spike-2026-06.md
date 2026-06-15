# Spike findings: swift-cross-ui on the Windows toolchain (R1/R16)

**Date:** 2026-06-11 · **Branch:** `spike/swift-cross-ui-win` (`spikes/crossui-win/`,
standalone package — root manifest untouched) · **Rig:** the local dockur/windows
Server 2022 VM mirroring the `windows-2022` CI runner, Swift main-snapshot toolchain.
**Verdict up front: R1's compile-risk is retired; the WinUI 3 fallback (ADR 0055) does
not need to be exercised on toolchain grounds.**

## What was asked

- **R1:** does swift-cross-ui (current `main`) resolve and **build** on the exact
  Windows snapshot toolchain Sprig ships on?
- **R16 (compile half):** does the TaskWindowKit binding shape — an actor view model
  with async verbs, driven from UI action closures — compile against swift-cross-ui?

## Findings

1. **Builds clean.** `SwiftCrossUI` + `DefaultBackend` (→ `WinUIBackend` on Windows)
   resolved and built to a linked `SpikeApp.exe`: 1,529 build steps, **774 s cold**,
   zero errors on the snapshot toolchain. The WinUI bindings layer compiles as-is.
2. **Actor binding compiles** (phase B-lite): `Button { Task { count = await
   viewModel.increment() } }` against an actor with the TaskWindowKit VM shape builds
   without ceremony (76 s incremental). The compile-level half of R16 is green.
3. **SPM identity trap (incidental, generalizable):** a *directory* named
   `swift-cross-ui` gave the spike package the same SPM identity as the dependency and
   shadowed it — "product 'SwiftCrossUI' … not found in package 'swift-cross-ui'".
   Never name a package directory after a dependency.
4. **Heavy dependency tree:** the cold build pulls and compiles Java-interop build
   plugins (via the Android backend's dependency graph) among ~1,500 steps. Plan for
   double-digit-minute cold CI builds for the Windows shell, or prune backends via a
   products-level dependency if upstream supports it by then.
5. **Launch needs the Windows App Runtime + an interactive session.** `SpikeApp.exe`
   fail-fasts with `0xC0000409` on the bare VM over SSH — the WinUI 3 runtime
   (WindowsAppRuntime redistributable) isn't installed there and session-0 has no
   desktop. This is a *distribution* fact, not a toolchain one: MSIX packaging bundles
   the runtime (ADR 0055's plan already assumes MSIX). Runtime behavior — including
   whether `@State` mutation from a `Task` refreshes the UI correctly — therefore
   remains for the **interactive** M3-Win spike on a desktop session.

## What this changes

- **R1** drops from "framework may not even build on our toolchain" to "runtime
  behavior + widget coverage unverified" — re-scored in the risk register. The
  ADR 0055 WinUI-3-fallback trigger is now runtime/maturity findings, not compile.
- **R16** keeps its M3 spike-first gate, with the compile half pre-cleared; the open
  half is runtime state propagation and main-thread semantics, which needs a desktop.
- The next M3-Win step when scheduled: install WindowsAppRuntime on the VM (or run on
  any Windows desktop), launch interactively, verify the actor round-trip updates the
  UI, then bind a real `TaskWindowKit` VM via a path dependency to the root package.

## Reproduce

```
git switch spike/swift-cross-ui-win
SPRIG_REPO_ROOT=$PWD /home/bill/sprig-windows-vm/test-windows.sh -- package describe  # sync
ssh -p 2222 Docker@localhost 'powershell -NoProfile -Command \
  "Set-Location C:\sprig\spikes\crossui-win; swift build"'
```
