# apps/windows/

Placeholder for the Windows GUI shell — a **1.0 deliverable** alongside the macOS shell (per [ADR 0054](../../docs/decisions/0054-1-0-platform-tier.md)). Currently empty; population begins at M2-Win.

**Today, the Windows engine experience is `sprigctl`.** It builds and runs natively on Windows (every PR's `ci-windows` job runs the full test suite there) and exposes the entire engine surface — `status`, `log`, `repos`, `watch`, `agent`, `recover`, `conflicts`. Windows users wanting to test Sprig before the shell lands can `swift build` and use the CLI directly.

## Planned contents

- **`SprigApp/`** — main app process. Hosts the task windows (CommitComposer, MergeConflictResolver, etc.) via [swift-cross-ui](https://github.com/stackotter/swift-cross-ui) per [ADR 0055](../../docs/decisions/0055-windows-gui-stack.md). Reuses the portable view-model code from `packages/TaskWindowKit/`.
- **`SprigAgent/`** — Windows Service wrapping `AgentKit.RepoAgent`. Long-lived per-user service; communicates with the shell extension over named pipes (`\\.\pipe\sprig-agent-<userSID>`).
- **`SprigExplorer/`** — C++/COM in-proc shell extension (`SprigExplorer.dll`) implementing `IShellIconOverlayIdentifier` (overlay badges), `IContextMenu` (legacy right-click), and `IExplorerCommand` (Windows 11 streamlined menu). Shares a single source of truth with the macOS FinderSync extension via the `IPCSchema` wire format.
- **`Installer/`** — MSIX package manifest + signing pipeline. Per-user install by default; optional per-machine variant for users who need overlay-icon priority over OneDrive.

## Reference docs

- [`docs/architecture/cross-platform.md`](../../docs/architecture/cross-platform.md) — three-tier package structure and CI matrix.
- [`docs/architecture/shell-integration.md`](../../docs/architecture/shell-integration.md) — badge model and right-click verbs (shared with macOS).
- [`docs/research/windows-shell-apis.md`](../../docs/research/windows-shell-apis.md) — the canonical implementation reference for the COM extension, MSIX packaging, and named-pipe IPC. Required reading before any code lands here.
- [`docs/decisions/0055-windows-gui-stack.md`](../../docs/decisions/0055-windows-gui-stack.md) — why swift-cross-ui for the task windows + C++/COM for the shell extension.
- [`docs/planning/milestones.md`](../../docs/planning/milestones.md) — M2-Win exit criteria.
