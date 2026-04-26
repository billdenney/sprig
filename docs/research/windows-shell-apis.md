# Windows Explorer shell extension APIs

What the Windows side of the shell extension surface looks like, and the politics around it. Required reading before M2-Win. Companion: [`../architecture/shell-integration.md`](../architecture/shell-integration.md), [`macos-finder-apis.md`](macos-finder-apis.md).

The Windows shell extension surface is **older, more permissive, and more dangerous** than macOS FinderSync. Older because it predates COM modernization; more permissive because it runs in-process inside `explorer.exe`; more dangerous for the exact same reason — a crash takes down the user's desktop.

## Two surfaces, two installer paths

Sprig ships **two shell extensions** that share a single source of truth for menu structure and badge state:

1. **A C++/COM in-proc DLL** (`SprigExplorer.dll`) implementing `IShellIconOverlayIdentifier` (badges) and `IContextMenu` (legacy right-click). Registered via classic registry entries. Lives in `apps/windows/SprigExplorer/`.
2. **An `IExplorerCommand` MSIX-packaged sparse extension** for the Windows 11 streamlined context menu. Lives in the same target, registered via `Package.appxmanifest`.

Both speak the same wire schema (`IPCSchema`) to SprigAgent over named pipes — they're frontends, not separate brains.

**Why C++/COM and not Swift?** Swift on Windows can technically produce a COM in-proc DLL, but the toolchain and ecosystem support is immature, every shell-extension reference book is C++, and `explorer.exe` cannot be allowed to load anything unstable. The C++/COM extension is small (~2k LOC budgeted) and the cost of writing it in C++ is a one-time tax we accept. ADR 0055 explicitly carves this out: swift-cross-ui is for the GUI task windows, **not** the shell extension.

## `IShellIconOverlayIdentifier` — and the 15-slot problem

The single most-cited Windows-shell-extension issue. Background:

- The OS only allows **15 overlay handlers system-wide**, total, across all installed apps.
- The selection is by **alphabetical sort of the registry key name** under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers`. First 15 entries win; everyone else gets ignored silently.
- This has been true since Windows XP. Microsoft has not changed it. They've explicitly said they will not change it.
- OneDrive (5 slots), Dropbox (3), Google Drive (3), Box (3), TortoiseGit (8), TortoiseSVN (8), and even some niche tools all compete in the same pool. A user with two cloud-storage providers and TortoiseGit installed has **already lost**.

The arms race: tools prefix their registry keys with leading spaces or `1` to sort first. OneDrive uses `   OneDrive1`, `   OneDrive2`, … with three leading spaces. Dropbox uses two leading spaces. TortoiseGit uses one. There is no formal limit on prefixed-space tricks; everyone keeps escalating.

### Sprig's approach

1. **Cap at 5 overlay handlers** by default — `clean`, `modified`, `staged`, `conflict`, `untracked`. The other 5 logical states from ADR 0019 are folded onto these visually, accepting some loss of fidelity vs the macOS 10-slot full set.
2. **Register with three leading spaces** (matching OneDrive's prefix length, no more): `   SprigClean`, `   SprigModified`, etc. We don't escalate the arms race.
3. **Preferences toggle "Reduce overlay slots to 3"** — the user can drop us to clean / modified / conflict only, freeing two slots for their other tools.
4. **Preferences toggle "Disable overlay icons"** — full opt-out. The right-click menu still works. TortoiseGit users coming to Sprig will recognize this fallback as their normal life.
5. **First-run diagnostic.** On first install we scan `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers` and tell the user honestly: "You have 12 overlay handlers registered; Sprig will be able to show 5 of them. Cloud storage providers (OneDrive, etc.) often take priority due to alphabetical sorting." Link to a docs page with options.

### Implementing the COM class

```cpp
class SprigBadgeClean : public IShellIconOverlayIdentifier {
    STDMETHODIMP IsMemberOf(LPCWSTR pwszPath, DWORD dwAttrib) override;
    STDMETHODIMP GetOverlayInfo(LPWSTR pwszIconFile, int cchMax,
                                int *pIndex, DWORD *pdwFlags) override;
    STDMETHODIMP GetPriority(int *pPriority) override;
};
```

`IsMemberOf` is the hot path — Explorer calls it for every visible file. **Must return in <50 ms p99**, ideally <5 ms p50. Implementation: hashmap lookup against the badge cache populated by the agent over the named pipe.

`GetOverlayInfo` is called once per badge per Explorer process to get the `.ico` path. We ship one icon file per badge state in the MSIX install dir.

`GetPriority` returns 0 (highest) — though the OS uses this only as a tiebreaker among multiple matching badges for the same path; the 15-slot global selection happens earlier.

## `IContextMenu` — the legacy right-click menu

Implemented via `IShellExtInit` (gets the selection) + `IContextMenu3` (modern variant supporting `HMENU` modifications and ownerdraw):

```cpp
class SprigContextMenu : public IShellExtInit, public IContextMenu3 {
    STDMETHODIMP Initialize(LPCITEMIDLIST pidlFolder, IDataObject *pdtobj,
                            HKEY hkeyProgID) override;
    STDMETHODIMP QueryContextMenu(HMENU hmenu, UINT indexMenu,
                                  UINT idCmdFirst, UINT idCmdLast,
                                  UINT uFlags) override;
    STDMETHODIMP InvokeCommand(LPCMINVOKECOMMANDINFO pici) override;
    STDMETHODIMP GetCommandString(UINT_PTR idCmd, UINT uType, ...) override;
    STDMETHODIMP HandleMenuMsg2(UINT uMsg, WPARAM wParam,
                                LPARAM lParam, LRESULT *plResult) override;
};
```

Registered under `HKLM\SOFTWARE\Classes\*\shellex\ContextMenuHandlers\Sprig` (for files) and `HKLM\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers\Sprig` (for folders). Per-user install variant: `HKCU\SOFTWARE\Classes\...`.

`QueryContextMenu` populates the menu structure (flat top-level + submenu, mirroring macOS exactly per ADR 0020). `InvokeCommand` translates the user's pick into a wire envelope to SprigAgent, which then launches the appropriate task window in the SprigApp host process.

**Performance budget identical to macOS**: <100 ms p99 for `QueryContextMenu`. Same mitigation: pre-warm a per-path menu cache from the agent.

## `IExplorerCommand` — Windows 11 streamlined menu

In Windows 11, the default right-click menu hides legacy `IContextMenu` entries behind a "Show more options" item. To appear in the **streamlined** menu, you implement `IExplorerCommand` *and* package as an MSIX with the extension declared in the manifest:

```xml
<Extensions>
  <desktop4:Extension Category="windows.fileExplorerContextMenus">
    <desktop4:FileExplorerContextMenus>
      <desktop4:ItemType Type="*">
        <desktop4:Verb Id="SprigCommit" Clsid="{...}" />
      </desktop4:ItemType>
      <desktop4:ItemType Type="Directory">
        <desktop4:Verb Id="SprigFolder" Clsid="{...}" />
      </desktop4:ItemType>
    </desktop4:FileExplorerContextMenus>
  </desktop4:Extension>
</Extensions>
```

The `IExplorerCommand` interface is simpler than `IContextMenu` (no `HMENU` manipulation; the manifest expresses structure declaratively):

```cpp
class SprigExplorerCommand : public IExplorerCommand {
    STDMETHODIMP GetTitle(IShellItemArray *psiItemArray, LPWSTR *ppszName) override;
    STDMETHODIMP GetIcon(IShellItemArray *psiItemArray, LPWSTR *ppszIcon) override;
    STDMETHODIMP GetState(IShellItemArray *psiItemArray, BOOL fOkToBeSlow,
                          EXPCMDSTATE *pCmdState) override;
    STDMETHODIMP Invoke(IShellItemArray *psiItemArray,
                        IBindCtx *pbc) override;
    STDMETHODIMP EnumSubCommands(IEnumExplorerCommand **ppEnum) override;
};
```

`GetState` returns `ECS_HIDDEN` for verbs that don't apply (e.g. "Resolve Conflicts" when there are no conflicts), making the menu adapt to context the same way macOS does.

`EnumSubCommands` is how we attach the `Sprig ▶` submenu — it returns an enumerator over child `IExplorerCommand` instances.

**Both extensions ship together.** A user on Windows 10 sees the `IContextMenu` items directly; a user on Windows 11 sees the `IExplorerCommand` items in the streamlined menu and the same `IContextMenu` items under "Show more options." We accept the duplication to avoid forcing users into the legacy menu on Windows 11.

## Crash-safety and the in-proc model

Anything in `explorer.exe` that throws an unhandled exception or causes an access violation can take down the desktop. **Hard rules** for Sprig's COM extension code:

1. **Every COM entry point is wrapped in `try/catch (...)`** and returns `E_FAIL` on uncaught exceptions. This is required by COM contract; we just enforce it more strictly than typical.
2. **Every IPC call to the agent has a 2-second timeout.** Falling back to "no badge" / "no menu" rather than blocking on a stuck named pipe.
3. **No allocations in `IsMemberOf`** — this gets called for every visible file in every Explorer window. Pre-allocate the badge cache; lookups are O(1) hashmap walks against pre-interned path strings.
4. **No ATL or MFC** — modern WIL (Windows Implementation Library, `microsoft/wil`) for smart-pointer ergonomics. Smaller binary, no legacy dependency surface.
5. **Static-link the C++ runtime.** Dynamic-link risks DLL-version skew with `explorer.exe`'s loaded modules.

## Per-user vs per-machine install

Sprig installs **per-user** by default — no admin elevation required for the typical install. Implications:

- Registry entries go in `HKCU\SOFTWARE\Classes` rather than `HKLM\...`. Both work; per-user takes precedence for that user.
- The MSIX package is a "user-scope MSIX" (also called a "sparse package" in some docs). winget supports this directly.
- **Caveat**: per-user shell extensions are sometimes deprioritized by `explorer.exe`'s registration ordering relative to per-machine extensions for the same shell-class. Empirically, OneDrive (per-machine, default install) wins ties against per-user Sprig. We document this; users who really need Sprig's badges to take priority can run the optional per-machine installer.

## Antivirus and SmartScreen

A new shell extension DLL signed with a fresh certificate triggers SmartScreen's "unrecognized publisher" warning until reputation builds. Mitigations:

- **EV (Extended Validation) code-signing certificate** for the Sprig DLL. EV certs bypass SmartScreen reputation building. ~$300/year through standard CAs.
- **Submit the binary to Microsoft Defender** via the Windows Security Intelligence portal on every release; usually whitelisted within 24h.
- **Document the SmartScreen prompt** in the install guide so first-run users aren't spooked.

This is one place where Sprig's release ops surface area expands meaningfully vs the macOS-only world. Tracked in the risk register.

## Windows Service for SprigAgent

The agent runs as a **Windows Service** (per-user, via the Service Control Manager) rather than as a console app. Why:

- Persistence across logoff (depending on service config; default is per-user-session).
- Can't be killed by a casual Task Manager glance the same way a tray app can.
- Standard Windows lifecycle — `services.msc` lists it, admins can restart it, etc.

Communication with the shell extension over named pipes (`\\.\pipe\sprig-agent-<userSID>`). The service registers a per-user pipe to avoid cross-user leakage on multi-user machines. DACLs on the pipe restrict to the owning SID.

The service is **separate from the GUI task-window app** (which is a regular swift-cross-ui process launched by the agent on demand). Three processes total at any time when active:

1. SprigAgent (Windows Service) — background brain.
2. `explorer.exe` with Sprig's shell-extension DLL loaded — badges + right-click menu.
3. SprigApp (when a task window is open) — the swift-cross-ui GUI host.

## Versioning and rollout

- **Minimum Windows: Windows 10 21H2** (last servicing version of Win10) **and Windows 11 22H2+**. `IExplorerCommand` requires Windows 11 22H2+ at the streamlined-menu level; we degrade to legacy `IContextMenu` on older builds automatically.
- **MSIX delivery**: signed package installable from a `.msix` file (direct download), winget (`winget install Sprig.Sprig`), or Microsoft Store (post-1.0 if we pursue it; not required for 1.0 per ADR 0009 / 0054).
- **Updates** via WinSparkle (or equivalent — see ADR 0055 open question). The MSIX framework also supports app-package self-update through a manifest update URL; investigate which is the better fit during M9-Win.

## Things explicitly not done

- **No Windows Shell namespace extension** (no fake "Sprig" virtual folder). We're augmenting the user's real folders, not adding a new namespace.
- **No `IThumbnailProvider`** for git objects. Possible future work; not in M2-Win scope.
- **No `IInfoTip`** (the hover tooltip showing "this file is modified, last commit X by Y"). Nice-to-have; deferred until after M2-Win lands.
- **No registry-based custom verbs.** All verbs go through `IContextMenu` / `IExplorerCommand` so they're consistent with the macOS structure and adapt to context.
- **No Windows 7/8 support.** They're EoL and `IExplorerCommand` is unavailable.

## Patterns from prior art

- **TortoiseGit** is the reference implementation of what we're building. They run a long-lived `TGitCache.exe` process (their "agent") that the shell extension queries over named pipe. Same pattern Sprig uses. Their public source at https://gitlab.com/tortoisegit/tortoisegit is invaluable; we're reading it carefully during M2-Win design. They've solved every gotcha listed above the hard way.
- **TortoiseSVN** predates TortoiseGit and uses the same architecture; the cache process is `TSVNCache.exe`. Same lessons apply.
- **OneDrive** is the canonical example of how to do this *at Microsoft scale* — they have the most aggressive overlay-slot prefix and the cleanest streamlined-menu integration. Their architecture is undocumented, but their MSIX-manifest pattern is what we're modeling on.
- **GitHub Desktop, SourceTree** (Windows variants) — neither implements badges or a context menu. They run as a regular app with a window. This is the gap Sprig addresses on Windows the same way it does on macOS.

## Verification checklist for M2-Win

- [ ] `regsvr32 SprigExplorer.dll` succeeds; entries appear under `HKLM\...\ShellIconOverlayIdentifiers` (or HKCU for per-user).
- [ ] Restart `explorer.exe`; badges render on a fixture repo within 100 ms of a `git status` change.
- [ ] Right-click menu structure matches the macOS structure (ADR 0020) under both legacy ("Show more options") and Windows 11 streamlined menus.
- [ ] `IsMemberOf` p99 latency < 50 ms across a 100k-file fixture repo.
- [ ] Forcing an exception in any COM entry point does not crash `explorer.exe`.
- [ ] Killing the SprigAgent service falls back to "no badge / no menu" within 2 seconds, no `explorer.exe` hang.
- [ ] Antivirus scanners (Defender + at least one major third-party AV in CI) don't quarantine the signed DLL.
- [ ] Per-user MSIX install via `winget` registers and unregisters the extension cleanly.
