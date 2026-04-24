# apps/windows/

Placeholder. The Windows port populates this directory post-1.0. See `/docs/architecture/cross-platform.md` for the design.

Expected contents when the port begins:

- `SprigApp/` — WinUI 3 or swift-cross-ui shell.
- `SprigAgent/` — Windows Service wrapper.
- `SprigExplorer/` — `IShellIconOverlayIdentifier` + `IContextMenu` shell extension.
- `Installer/` — MSIX manifest + WiX scripts.
