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

## Implementation deep-dives

The sections above cover *what* we're building. The sections below cover *how* — at the level of detail you need to actually write the code. They're the next layer down from the architectural overview, and they're where the gotchas live.

### Named-pipe IPC: the server side

The shell extension is the *client*; SprigAgent (running as a Windows Service) is the *server*. The MSDN reference patterns are well-established but worth pinning down because the wrong combination of flags will silently cripple throughput or break multi-client.

**`CreateNamedPipe` flags we use** (per [MSDN's Multithreaded Pipe Server example](https://learn.microsoft.com/en-us/windows/win32/ipc/multithreaded-pipe-server)):

- `PIPE_ACCESS_DUPLEX` — read and write; the agent both serves badge state queries and pushes `git status` deltas.
- `PIPE_TYPE_BYTE | PIPE_READMODE_BYTE` — *not* `PIPE_TYPE_MESSAGE`. See "Wire format" below for why.
- `FILE_FLAG_OVERLAPPED` — every instance is async; no blocking I/O on the accept thread.
- `PIPE_UNLIMITED_INSTANCES` — the SCM-imposed limit (one service, multiple Explorer processes per session) sits well under any practical cap.

**Multi-client accept loop.** Each connecting client gets its own pipe instance; the canonical pattern is one `CreateNamedPipe` call per accepted client, then immediately loop back and create the next pending instance:

```cpp
for (;;) {
    wil::unique_handle hPipe{ CreateNamedPipeW(
        kPipeName,
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        kBufSize, kBufSize, 0, &sa) };
    THROW_LAST_ERROR_IF(!hPipe);

    OVERLAPPED ov{};
    ov.hEvent = m_acceptEvent.get();
    if (!ConnectNamedPipe(hPipe.get(), &ov)) {
        DWORD err = GetLastError();
        if (err == ERROR_PIPE_CONNECTED) { /* already connected, fall through */ }
        else if (err == ERROR_IO_PENDING) { WaitForSingleObject(m_acceptEvent.get(), INFINITE); }
        else { THROW_WIN32(err); }
    }
    HandOffToIocp(std::move(hPipe));
}
```

The `ERROR_PIPE_CONNECTED` race is real — a client can connect between `CreateNamedPipe` and `ConnectNamedPipe` and the API documents this explicitly. Forgetting to handle it is a long-standing rite of passage.

**DACL: per-user-SID restriction.** The default DACL grants `Everyone` read access — wrong for us. The agent constructs a SECURITY_ATTRIBUTES with an explicit DACL that allows only the owning user's logon SID:

```cpp
PSID userSid = /* GetTokenInformation(TokenUser) on the service's user token */;
EXPLICIT_ACCESS ea{};
ea.grfAccessPermissions = FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_CREATE_PIPE_INSTANCE;
ea.grfAccessMode = SET_ACCESS;
ea.grfInheritance = NO_INHERITANCE;
ea.Trustee.TrusteeForm = TRUSTEE_IS_SID;
ea.Trustee.TrusteeType = TRUSTEE_IS_USER;
ea.Trustee.ptstrName = static_cast<LPWSTR>(userSid);

PACL pAcl = nullptr;
THROW_IF_WIN32_ERROR(SetEntriesInAclW(1, &ea, nullptr, &pAcl));
SECURITY_DESCRIPTOR sd{};
THROW_IF_WIN32_BOOL_FALSE(InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION));
THROW_IF_WIN32_BOOL_FALSE(SetSecurityDescriptorDacl(&sd, TRUE, pAcl, FALSE));
```

Note `FILE_CREATE_PIPE_INSTANCE` collides with `FILE_APPEND_DATA` (same numeric value), which is why we never pass `FILE_GENERIC_WRITE` wholesale on this path — see the [Named Pipe Security and Access Rights](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights) page for the full footgun.

**Async I/O: IOCP plus a small threadpool.** `WaitForMultipleObjects` caps at `MAXIMUM_WAIT_OBJECTS` (64) and degrades linearly; IOCP is the standard answer for scaling beyond a handful of concurrent pipe instances. For M2-Win we use the existing `CreateThreadpoolIo` API rather than rolling our own IOCP loop — it's the same kernel object underneath, with one fewer thing to get wrong:

```cpp
PTP_IO io = CreateThreadpoolIo(hPipe.get(), &OnPipeIoCompletion, this, nullptr);
StartThreadpoolIo(io);
ReadFile(hPipe.get(), buf, sizeof(buf), nullptr, &ov); // returns immediately
```

Each completion runs on a worker thread; we copy the envelope into the badge cache and re-arm the read. Memory budget for steady state: ~16 KB read buffer per connected client, plus the cache. Threadpool size auto-tunes.

**Wire format: length-prefixed binary, not message-mode.** This is the deliberate divergence from "the Windows way." Pipes support `PIPE_TYPE_MESSAGE` boundaries, but the rest of Sprig's IPC (XPC on macOS, eventually D-Bus on Linux) uses a single canonical wire format: `IPCSchema.EnvelopeCodec`'s 4-byte little-endian length prefix followed by a JSON body. We pay the cost of byte-mode framing on Windows so the codec stays one implementation everywhere. Side benefit: a 64 KiB JSON envelope traverses message-mode pipes in chunks anyway (the OS-side message buffer cap is 64 KiB), so the framing benefit is illusory at our payload sizes.

**Client-side reconnection.** When the service restarts (Windows updates, manual restart, crash), every client's pipe handle goes `ERROR_BROKEN_PIPE`. The shell-extension client wraps each round-trip in a small retry: on broken pipe, sleep 100 ms (jittered exponential, capped at 2 s), call `WaitNamedPipe(kPipeName, kReconnectTimeout)` to wait until a new instance exists, then `CreateFile` it. We never block Explorer's calling thread for more than ~2 s total — past that we return "no badge" and let the next call retry.

**MSDN references:** [Named Pipes overview](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipes), [Multithreaded Pipe Server](https://learn.microsoft.com/en-us/windows/win32/ipc/multithreaded-pipe-server), [Named Pipe Security and Access Rights](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights).

### MSIX packaging for the streamlined-menu extension

Sprig ships a *sparse* MSIX package — Microsoft's official term is now "[packaging with external location](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps)" but the older "sparse package" name still appears in tooling and community docs. The model: a tiny `.msix` carrying just the `AppxManifest.xml` plus visual assets, with `<uap10:AllowExternalContent>true</uap10:AllowExternalContent>` declared, and the actual binaries shipping via our regular installer in a normal `Program Files\Sprig` (or `%LocalAppData%\Programs\Sprig` for per-user) directory.

**Why sparse.** A full MSIX would force every binary inside the package container, with file-system and registry virtualization redirecting writes. That breaks the C++/COM shell extension's classic-registry registration path on Windows 10 (older, full-MSIX shell extensions are constrained), and it limits us to MSIX-only delivery. Sparse lets us keep the regular installer path open — winget today, optional MSI tomorrow if an enterprise customer demands it — while still getting package identity for the `IExplorerCommand` registration, push-notification eligibility, and clean Add/Remove Programs entry.

**Manifest layout.** The package combines `IExplorerCommand` registration (the streamlined menu) with the legacy `IShellIconOverlayIdentifier` / `IContextMenu` registration done via classic registry entries from the installer:

```xml
<Package IgnorableNamespaces="uap uap10 desktop4 desktop5 com"
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap10="http://schemas.microsoft.com/appx/manifest/uap/windows10/10"
  xmlns:desktop4="http://schemas.microsoft.com/appx/manifest/desktop/windows10/4"
  xmlns:com="http://schemas.microsoft.com/appx/manifest/com/windows10">
  <Identity Name="Sprig.Sprig"
            Publisher="CN=Sprig, O=Sprig, C=US"
            Version="1.0.0.0"
            ProcessorArchitecture="neutral"/>
  <Properties>
    <DisplayName>Sprig</DisplayName>
    <PublisherDisplayName>Sprig</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
    <uap10:AllowExternalContent>true</uap10:AllowExternalContent>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop"
                        MinVersion="10.0.19041.0"
                        MaxVersionTested="10.0.26100.0"/>
  </Dependencies>
  <Capabilities>
    <rescap:Capability Name="runFullTrust"/>
    <rescap:Capability Name="unvirtualizedResources"/>
  </Capabilities>
  <Applications>
    <Application Id="Sprig" Executable="SprigApp.exe"
                 uap10:TrustLevel="mediumIL"
                 uap10:RuntimeBehavior="win32App">
      <Extensions>
        <com:Extension Category="windows.comServer">
          <com:ComServer>
            <com:SurrogateServer DisplayName="Sprig Explorer Command">
              <com:Class Id="{...}" Path="SprigExplorer.dll" ThreadingModel="STA"/>
            </com:SurrogateServer>
          </com:ComServer>
        </com:Extension>
        <desktop4:Extension Category="windows.fileExplorerContextMenus">
          <desktop4:FileExplorerContextMenus>
            <desktop4:ItemType Type="*">
              <desktop4:Verb Id="Sprig" Clsid="{...}"/>
            </desktop4:ItemType>
            <desktop4:ItemType Type="Directory">
              <desktop4:Verb Id="Sprig" Clsid="{...}"/>
            </desktop4:ItemType>
          </desktop4:FileExplorerContextMenus>
        </desktop4:Extension>
      </Extensions>
    </Application>
  </Applications>
</Package>
```

**Identity / Publisher / Version: tied to the cert.** The `Publisher` attribute on `<Identity>` *must* be a string-equal match for the Subject DN of the code-signing certificate, including `CN=` / `O=` / `C=` order and spacing. Mismatch produces `0x80073CF6` ("manifest invalid") at install time. `Name` becomes part of the package family name (`Sprig.Sprig_<hash>`); changing it after release breaks every existing install. `Version` is `Major.Minor.Build.Revision` — Microsoft Store and `Add-AppxPackage` both reject a re-register at the same version, so the build number bumps every release.

**MSIX vs MSI.** MSI is what enterprise admins know; it integrates with Group Policy and SCCM out of the box. MSIX is what gets us identity-bound platform features (Live Tiles aren't relevant, but background tasks, share targets, and the streamlined-menu registration absolutely are). For 1.0 we ship MSIX only, with winget as the headline distribution channel; the MSI path is a deferred decision that ADR 0054 keeps open.

**MSDN references:** [What is MSIX](https://learn.microsoft.com/en-us/windows/msix/overview), [Grant package identity by packaging with external location](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps).

### Code-signing in CI

Three artifacts need signatures: `SprigExplorer.dll` (loaded into `explorer.exe` — this is the one SmartScreen and Defender heuristics look at hardest), `SprigAgent.exe` (the Windows Service), and `Sprig.msix` (the sparse package). Each gets signed independently with the same EV cert; MSIX signs *after* the contained binaries are signed, because the `AppxBlockMap.xml` hashes the signed bytes.

**Cert acquisition.** The four practical EV-cert vendors are DigiCert, Sectigo, GlobalSign, and SSL.com. List price runs roughly $300–$700/year for a 1-year cert, less per year on multi-year deals. Every EV cert ships either as a USB hardware token (FIPS 140-2 Level 2) — which is unusable for headless CI — or as a cloud-HSM key under the CA's KMS. We use the cloud-HSM option.

**Cloud signing options.** The relevant offerings are [DigiCert KeyLocker](https://docs.digicert.com/en/digicert-keylocker.html), Sectigo's CodeSign Tool / CodeSigning HSM, [Azure Trusted Signing](https://learn.microsoft.com/en-us/azure/trusted-signing/) (formerly Azure Code Signing), and SSL.com eSigner. KeyLocker integrates as a `signtool` PKCS#11 KSP (Key Storage Provider) library; Azure Trusted Signing integrates as a separate `dlib` plugin invoked via `signtool /dlib`. Both are FIPS 140-2 Level 3 backed and both work in headless GitHub Actions runners.

**`signtool` invocation.** SHA-256 file digest, RFC 3161 timestamp server, KSP-backed key:

```powershell
signtool sign `
  /fd SHA256 `
  /tr http://timestamp.digicert.com `
  /td SHA256 `
  /n "Sprig" `
  /a `
  SprigExplorer.dll SprigAgent.exe

signtool sign `
  /fd SHA256 `
  /tr http://timestamp.digicert.com `
  /td SHA256 `
  /n "Sprig" `
  /a `
  Sprig.msix
```

The `/td` flag for the timestamp digest algorithm is mandatory in current Windows SDK builds; omitting it warns today and errors tomorrow per Microsoft's [SignTool reference](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool). RFC 3161 timestamping (the `/tr` form, not the legacy `/t`) embeds a timestamp signed by a TSA, which means our Authenticode signature stays valid past cert expiration as long as the TSA signature itself was valid at signing time — the standard trick to avoid every shipped binary expiring on the cert anniversary.

**Build pipeline shape.** Cross-compiling Swift on a Linux runner (faster, cheaper) for the *agent* is feasible — the Swift Windows SDK is a supported target. The C++ shell extension still wants a real Windows runner because of MSVC, the WIL headers, and the WinRT projection generator. So the realistic CI shape:

1. Linux job: `swift build --triple x86_64-unknown-windows-msvc` produces `SprigAgent.exe` + dependencies.
2. Windows job: MSVC builds `SprigExplorer.dll`; downloads the agent from the prior job; signs both binaries; runs `MakeAppx.exe pack`; signs the MSIX.
3. Both jobs cache aggressively. KeyLocker / Trusted Signing creds come from GitHub OIDC → CA federation, never long-lived secrets in Actions vars.

**Time budget.** Per-artifact RFC 3161 round-trip is ~0.5–1.0 s against DigiCert's TSA (well-provisioned, geographically distributed). Three artifacts × 1 s ≈ 3 s timestamping; SHA-256 hashing of a 2 MB DLL is sub-second; PKCS#7 wrapping is sub-second; the cloud-HSM signing call is the dominant variable, typically 200–500 ms each. Whole step targets **<30 s wall-clock** and the actual budget is well under that. If we ever exceed it, the suspect is TSA latency, not the signer.

**MSDN / vendor references:** [SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool), [DigiCert KeyLocker](https://docs.digicert.com/en/digicert-keylocker.html), [Azure Trusted Signing overview](https://learn.microsoft.com/en-us/azure/trusted-signing/).

### Testing the shell extension in CI

The honest answer: hosted `windows-latest` runners cannot test most of what matters. There is no logged-in interactive desktop session, no real `explorer.exe` to load our DLL into, no Start Menu, no right-click. GitHub-hosted Windows runners are server SKUs running headless. We test what we *can* test and document the rest as a manual checklist gated behind the eventual self-hosted runner.

**What runs in `ci-windows` today:**

1. **`regsvr32` round-trip.** `regsvr32 /s SprigExplorer.dll` followed by `regsvr32 /u /s SprigExplorer.dll` — verifies the DLL exports `DllRegisterServer` / `DllUnregisterServer` and the COM-class registry entries are syntactically valid. `/s` for silent; failure exit code surfaces in CI.
2. **`CoCreateInstance` activation.** Programmatically activate each CLSID against the in-proc DLL and `QueryInterface` for `IShellIconOverlayIdentifier`, `IContextMenu3`, `IExplorerCommand`. Catches missing exports, broken vtables, and CLSID-registry typos — the failure modes that wreck the extension before Explorer ever sees it.
3. **Direct interface calls without Explorer.** `IsMemberOf` is a pure function: feed it a path and a fixture badge state, assert the return value. `QueryContextMenu` against a fixture `IDataObject` (we synthesize one with `SHCreateDataObject` over a `CIDA`) populates an `HMENU` we then enumerate to assert structure. None of this needs a desktop session.
4. **MSIX pack/unpack.** `MakeAppx.exe pack` then `MakeAppx.exe unpack`, plus manifest schema validation via `MakeAppx.exe pack /v`. Doesn't install the package — that needs a real session — but catches manifest typos before they ship.
5. **Static analysis.** `signtool verify /pa` against the signed artifacts; `appxsignaturetest.exe` for MSIX-specific signature validity.

**What needs the eventual self-hosted runner:**

- Badges actually rendering on visible files. (Requires Explorer + interactive desktop.)
- The Windows 11 streamlined menu showing our `IExplorerCommand` verbs in the right place. (Requires shell. Even a programmatic `IExplorerCommand` activation test doesn't prove the menu integration.)
- MSIX `Add-AppxPackage` / `Remove-AppxPackage` round-trip. (Requires user session for per-user install; admin for `Stage` / `Provision`.)
- SmartScreen behavior on a fresh download. (Requires real download via Edge or the Web from a non-cached URL.)
- Antivirus interference. (Requires Defender + at-least-one third-party AV installed.)
- Long-running stability — `explorer.exe` not leaking memory after 10k `IsMemberOf` calls.

These get a **manual verification checklist** that ships with each release-candidate tag, which the maintainer runs on a dedicated Windows 11 VM before promoting to release. The checklist is mechanical and short (~15 minutes) so it doesn't get skipped.

The same M0-Win risk-register entry that funds the self-hosted Windows runner also funds re-introducing this layer in `tests/e2e/` — same framing as the deferred macOS XCUITest suite (see `CLAUDE.md`'s testing-expectations section). Until then we run the integration-test surface that's actually testable on hosted runners and accept the gap.

### Power-management integration

ADR 0064 specifies auto-fetch backoff: aggressive on AC, conservative on battery, suspended on metered networks or low battery. The Windows mapping uses three notification mechanisms, all funneled into the service's `HandlerEx` via `SERVICE_CONTROL_POWEREVENT`.

**Suspend / resume.** When the SCM sends `SERVICE_CONTROL_POWEREVENT`, `dwEventType` carries the [`PBT_*` constant](https://learn.microsoft.com/en-us/windows/win32/power/wm-powerbroadcast):

- `PBT_APMSUSPEND` (0x4) — system is going to sleep. We cancel in-flight fetches, flush the badge cache, and stop scheduling new work. Time budget: ~2 seconds before the OS forces the suspend.
- `PBT_APMRESUMEAUTOMATIC` (0x12) — system is resuming, regardless of cause. We re-enumerate watched repos and re-arm the fetch scheduler. *Always* delivered on resume.
- `PBT_APMRESUMESUSPEND` (0x7) — delivered after `PBT_APMRESUMEAUTOMATIC` *only* if the resume was triggered by user input. We use this as the signal to do a one-shot eager `git fetch` for the repo containing the foreground Explorer window — the user came back, they want fresh state.
- `PBT_POWERSETTINGCHANGE` (0x8013) — power-setting change for a setting we registered for via [`RegisterPowerSettingNotification`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerpowersettingnotification).

**Per-setting subscriptions.** From within `ServiceMain`, after the initial `RegisterServiceCtrlHandlerEx`, the service registers for the specific GUIDs that drive ADR 0064's policy:

```cpp
SERVICE_STATUS_HANDLE ssh = RegisterServiceCtrlHandlerExW(
    kServiceName, &HandlerEx, this);

HPOWERNOTIFY hAcDc = RegisterPowerSettingNotification(
    ssh, &GUID_ACDC_POWER_SOURCE, DEVICE_NOTIFY_SERVICE_HANDLE);
HPOWERNOTIFY hBatt = RegisterPowerSettingNotification(
    ssh, &GUID_BATTERY_PERCENTAGE_REMAINING, DEVICE_NOTIFY_SERVICE_HANDLE);
HPOWERNOTIFY hLid  = RegisterPowerSettingNotification(
    ssh, &GUID_LIDSWITCH_STATE_CHANGE, DEVICE_NOTIFY_SERVICE_HANDLE);
```

Inside the handler, `lpEventData` for `PBT_POWERSETTINGCHANGE` is a `POWERBROADCAST_SETTING*`; the `PowerSetting` GUID identifies which one fired and `Data[0]` carries the new value:

- `GUID_ACDC_POWER_SOURCE` → `0` = AC (full polling), `1` = battery (back off), `2` = short-term battery (further back off).
- `GUID_BATTERY_PERCENTAGE_REMAINING` → 0–100; below 20% we drop to "manual fetch only."
- `GUID_LIDSWITCH_STATE_CHANGE` → `0` = closed, `1` = open. We treat lid-close as a soft suspend (cancel in-flight) even before the OS-level suspend fires; lid-open as a soft resume hint.

**Metered-network detection.** *Open question:* power notifications don't cover network meterability. The likely path is `INetworkCostManager::GetCost` from the Network List Manager (NLM) COM API plus subscription to `INetworkConnectionEvents` — but neither is a power notification. Tracked as a follow-up question for the M2-Win design pass; for now we honor `NetworkInformation.GetInternetConnectionProfile().GetConnectionCost()` synchronously when we make a fetch decision, accepting the latency.

**MSDN references:** [Power Management portal](https://learn.microsoft.com/en-us/windows/win32/power/power-management-portal), [WM_POWERBROADCAST](https://learn.microsoft.com/en-us/windows/win32/power/wm-powerbroadcast), [RegisterPowerSettingNotification](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerpowersettingnotification), [RegisterServiceCtrlHandlerEx](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/nf-winsvc-registerservicectrlhandlerexa).

### WIL (Windows Implementation Library) usage patterns

WIL is [`microsoft/wil`](https://github.com/microsoft/wil), a header-only MIT-licensed Microsoft library that's the modern replacement for ATL's smart-pointer and error-handling subsets. It is what Microsoft's own Windows component teams use; it is actively maintained; and it does not drag in the licensing baggage and learning curve of ATL.

**Why WIL, not ATL.** ATL is technically still supported but its smart-pointer interfaces (`CComPtr`, `CHandle`) are ergonomically frozen, the macros (`ATLENSURE`, `ATLASSERT`) bake in MFC-era assumptions, and the linkage story (`atls.lib` vs `atlsd.lib`, `_ATL_FREE_THREADED` etc.) is a maintenance trap for a small, single-purpose DLL. WIL's headers are include-and-go, the macros map cleanly onto modern C++ exception semantics, and the upstream project ships monthly updates. ATL also pulls in dependencies on Visual C++ runtime versions in subtle ways that interact badly with the "static-link the C++ runtime" rule from the crash-safety section.

**Smart-pointer types we lean on:**

- `wil::com_ptr<T>` — RAII `IUnknown*`. Zero-cost over `CComPtr`, with cleaner `query<I>()` and `try_query<I>()` that don't lose the HRESULT.
- `wil::unique_handle` — RAII `HANDLE`. Variant `wil::unique_hfile` calls `CloseHandle`; `wil::unique_event` for `CreateEvent` results. The naming convention is `unique_<resource>` and the deleter is correct by construction.
- `wil::unique_cotaskmem_string` — RAII for `CoTaskMemAlloc`'d wide strings, the common return-via-out-parameter pattern in shell APIs. Used everywhere in the `IShellItem` glue.

**Error-handling macros.** WIL gives you four families per the [error-handling helpers wiki](https://github.com/microsoft/wil/wiki/Error-handling-helpers):

- `RETURN_IF_FAILED(hr)` — propagate failure HRESULTs without stack unwinding. Used inside `try`/`catch`-free functions.
- `THROW_IF_FAILED(hr)` / `THROW_HR(hr)` — convert failure to `wil::ResultException`. Used inside the COM-method bodies which need exceptions for the modern-C++ flow.
- `CATCH_RETURN()` — at every COM entry point, pair with `try {` to convert any escaped exception into the right HRESULT. WIL's mapping table covers `wil::ResultException`, `std::bad_alloc`, `std::exception`, and the WinRT/PPL families uniformly.
- `LOG_IF_FAILED(hr)` / `CATCH_LOG()` — for "this is best-effort, log the failure but keep going" sites. Cleaner than discarding the HRESULT silently.

The COM-entry-point pattern this makes possible:

```cpp
IFACEMETHODIMP SprigExplorerCommand::GetTitle(IShellItemArray* psia, LPWSTR* ppszName) try {
    *ppszName = nullptr;
    auto state = m_cache->Lookup(psia);  // can throw
    *ppszName = wil::make_cotaskmem_string(state.title.c_str()).release();
    return S_OK;
} CATCH_RETURN();
```

This is the "every COM entry point is wrapped" rule from the crash-safety section, written so the pattern is uniform and grep-able. Reviewer's job: confirm every method on a COM interface has the `try { ... } CATCH_RETURN();` outer shell. Anything that doesn't is a candidate for taking down `explorer.exe`.

**Distribution.** WIL ships via NuGet (`Microsoft.Windows.ImplementationLibrary`), vcpkg, or just dropping the headers into the source tree. We pin a version via vcpkg.json and update on a quarterly cadence — the library is stable but adds new helpers reasonably often.

**Reference:** [`microsoft/wil`](https://github.com/microsoft/wil), specifically the [error-handling helpers wiki page](https://github.com/microsoft/wil/wiki/Error-handling-helpers).

## Verification checklist for M2-Win

- [ ] `regsvr32 SprigExplorer.dll` succeeds; entries appear under `HKLM\...\ShellIconOverlayIdentifiers` (or HKCU for per-user).
- [ ] Restart `explorer.exe`; badges render on a fixture repo within 100 ms of a `git status` change.
- [ ] Right-click menu structure matches the macOS structure (ADR 0020) under both legacy ("Show more options") and Windows 11 streamlined menus.
- [ ] `IsMemberOf` p99 latency < 50 ms across a 100k-file fixture repo.
- [ ] Forcing an exception in any COM entry point does not crash `explorer.exe`.
- [ ] Killing the SprigAgent service falls back to "no badge / no menu" within 2 seconds, no `explorer.exe` hang.
- [ ] Antivirus scanners (Defender + at least one major third-party AV in CI) don't quarantine the signed DLL.
- [ ] Per-user MSIX install via `winget` registers and unregisters the extension cleanly.
