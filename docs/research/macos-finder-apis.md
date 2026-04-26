# macOS FinderSync + related APIs

What the macOS shell extension surface actually looks like in practice, the gotchas that have bitten Dropbox/Box/Google-Drive over the years, and the patterns we're committing to. Required reading before M2-Mac. Companion: [`../architecture/shell-integration.md`](../architecture/shell-integration.md), [`windows-shell-apis.md`](windows-shell-apis.md).

## FinderSync 101

`FinderSync` (FIFinderSync) is the Apple-blessed extension point for adding overlay badges and context-menu items in Finder. It replaces the unsupported `SIMBL`/Finder-injection hacks that older clients used pre-10.10. It's an **app extension** (`NSExtensionPointIdentifier = com.apple.FinderSync`) bundled inside the host app.

Extension lifetime: the system spawns it on demand when Finder shows a directory the extension has registered interest in. It can be killed at any time to reclaim memory; **assume your extension restarts often**.

Key types:

- **`FIFinderSync`** — base class. You override `beginObservingDirectory(at:)`, `endObservingDirectory(at:)`, `requestBadgeIdentifier(for:)`, `menu(for:)`, etc.
- **`FIFinderSyncController.default()`** — the singleton you call to declare watched roots and to register badge images.

## The five things you must call at extension init

```swift
let controller = FIFinderSyncController.default()

// 1. Tell Finder which roots we care about. Finder will only invoke
//    our hooks for paths under these.
controller.directoryURLs = Set(userWatchRoots)

// 2. Register every badge identifier we'll ever set.
controller.setBadgeImage(NSImage(named: "BadgeClean")!,
                         label: "Clean",
                         forBadgeIdentifier: "com.sprig.badge.clean")
// ... 9 more, one per state

// 3. Register the toolbar item label (shows up in the Finder toolbar).
controller.toolbarItemName = "Sprig"
controller.toolbarItemToolTip = "Sprig — Git for macOS"
controller.toolbarItemImage = NSImage(named: "ToolbarIcon")!
```

The `directoryURLs` set has an **undocumented soft cap** (older threads cite ~16, current testing on macOS 14/15 happily accepts 100+). Sprig caps at 64 watched roots in Preferences and surfaces a warning past that.

## Badge identifiers — what's stable

- Identifiers are arbitrary strings; the convention is reverse-DNS (`com.sprig.badge.modified`).
- Once registered, the identifier-to-image map is immutable for the extension's lifetime. To swap an image (e.g. dark mode), use a single image with appearance variants in the asset catalog rather than re-registering.
- `controller.setBadgeIdentifier("com.sprig.badge.modified", for: url)` is the per-path call. It coalesces internally; calling it 1000×/sec for the same path is fine.
- Calling it with the empty string clears the badge.

There's no documented identifier-count cap, but Apple's sample code recommends keeping it small. Sprig's 10 (ADR 0019) is comfortably within budget.

## The menu hook

```swift
override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    let menu = NSMenu(title: "")
    // ... append items synchronously
    return menu
}
```

`menuKind` distinguishes:

- `.contextualMenuForItems` — right-click on selected files
- `.contextualMenuForContainer` — right-click on the *folder*, or in the empty area of a Finder window
- `.contextualMenuForSidebar` — right-click on a sidebar entry
- `.toolbarItemMenu` — the toolbar dropdown

We populate `.contextualMenuForItems` and `.contextualMenuForContainer` for full coverage; the toolbar is opt-in (ADR 0034 says no menu-bar app, but the Finder *toolbar* item is fine since it lives inside the file manager itself, not the system menu bar).

The selected paths are *not* passed to `menu(for:)`. You retrieve them via `FIFinderSyncController.default().selectedItemURLs()`. Annoying API ergonomics; calling it is cheap.

**`menu(for:)` is synchronous.** Anything that takes >100ms here is a bug; users will feel the menu lag. Implication: pre-compute everything via push from the agent.

## Sandboxing

FinderSync extensions run **sandboxed**. Entitlements:

- `com.apple.security.app-sandbox` — required.
- `com.apple.security.application-groups` — for the App Group container shared with SprigAgent (used for the badge cache and any small bootstrap data). The group ID convention is `<TeamID>.com.sprig.shared`.
- `com.apple.security.files.user-selected.read-write` — for file access beyond the App Group container, granted when the user adds a watch root.
- **No** `com.apple.security.network.client` — the extension never makes network calls; if it needs anything, the agent does it.

The agent itself runs **outside the sandbox** (it's a LaunchAgent, not an extension), which is necessary because it needs to spawn `git` with arbitrary cwd and read/write across the whole user home.

## XPC between extension and agent

Two mechanisms available:

1. **Mach service via `NSXPCConnection`** — the modern path. Agent registers a Mach service (`com.sprig.agent`) declared in its `launchd.plist`. Extension connects with `NSXPCConnection(machServiceName: "com.sprig.agent", options: [])`. Bidirectional, supports remote-object proxies, but those proxies are **Apple-only ergonomics** — we deliberately don't use them (ADR 0048 §12.6) because the same wire schema must work over named pipes on Windows.
2. **App Group + file-based mailbox** — a fallback for when the Mach service is unavailable (e.g. agent not yet started). Used only for the "wake up the agent on first contact" handshake.

Pattern Sprig uses (ADR 0048):

- `NSXPCConnection` with a single one-method protocol: `func send(_ data: Data, reply: @escaping (Data) -> Void)`.
- Both ends serialize / deserialize `IPCSchema` envelopes around that primitive.
- This deliberately gives up XPC's nicer remote-proxy semantics. Don't add them back without a corresponding ADR — the cross-platform IPC contract is load-bearing.

## Memory ceiling

FinderSync extensions are killed by `launchd` when memory pressure rises or when they exceed an internal threshold (~50 MB jetsam-ish, not officially documented). Sprig targets **<30 MB resident** with a hard alarm at 25 MB that flushes the badge cache.

Practical implications:

- No image caching beyond the 10 badge images we registered at init.
- The badge cache is a `Dictionary<URL, BadgeIdentifier>` capped at 10k entries with LRU eviction. At 10k entries with ~100-byte path strings + 30-byte identifier strings, that's ~1.3 MB, well within budget.
- No git-history caching, no diff caching, no anything-but-the-immediate-task-at-hand.

## User-granted paths

This is the most-frequently-confused-by-users aspect of the macOS extension model. **Finder will only invoke the extension on paths the user has explicitly approved in System Settings → Privacy & Security → Extensions → Finder Extensions → Sprig**. Adding a watch root in Sprig's Preferences is necessary but not sufficient: the user must also tick the Finder Extension entry in System Settings.

Sprig's onboarding (ADR 0039) walks through this:

1. User picks watch roots in Preferences.
2. Sprig calls `FIFinderSyncController.default().directoryURLs = ...`.
3. Sprig opens System Settings to the right pane via `x-apple.systempreferences:com.apple.ExtensionsPreferences?Finder` and shows an in-app callout: "Tick the box next to Sprig to enable badges in Finder."
4. Sprig polls for activation (the `pluginkit` query) and surfaces success.

If the user later uninstalls + reinstalls Sprig, the system **preserves** the activation state for the new bundle as long as the bundle ID is unchanged. New bundle ID → user re-grants from scratch. Implication: don't change `com.sprig.SprigFinder` lightly.

## Network-volume / iCloud-Drive caveats

FinderSync events on these volumes are **lossy or absent**:

- **SMB / AFP / NFS shares** — FSEvents doesn't fire. The Finder still calls `requestBadgeIdentifier(for:)` when scrolling, but our agent doesn't know the path is dirty without polling.
- **iCloud Drive** — events fire for local-cache changes but not for remote-side updates synced down. Plus the placeholder-file model means a path may legitimately have no local content.
- **External drives** — usually fine if APFS or HFS+; flaky on exFAT.

ADR 0022 strategy: detect volume type via `URLResourceKey.volumeIsLocalKey` + `URLResourceKey.volumeURLForRemountingKey`; flip the watcher to `PollingFileWatcher` and surface a banner in the repo view. User can disable polling per-volume to opt out entirely.

## Patterns from prior art

- **Dropbox** ships a separate Finder extension *and* a kernel-extension-replacement called "Dropbox File Provider" (using the modern `FileProvider` API). The badge work is in the Finder extension; the placeholder-file model is in the file provider. Sprig does not need a file provider — we're augmenting real directories, not synthesizing them.
- **Google Drive** (Drive for Desktop) similarly splits responsibilities. They've publicly noted (in WWDC labs) that minimizing extension-process work is the single biggest reliability win.
- **Box Drive** uses a single extension; their support docs frequently surface "if badges are missing, toggle the extension off and on in System Settings" — a tell that user-granted-paths confusion is the #1 support issue. Sprig's onboarding tries to head this off.
- **GitHub Desktop, Tower, Fork, GitUp, Sublime Merge** — none of these implement Finder badges or context menus. The only macOS-native Git tool that did was the discontinued **SourceTree Beta** (2014-ish; abandoned). This is the gap Sprig fills.

## What's not available to us

- **No way to add items to the Finder *menu bar*.** The toolbar dropdown (above) is the closest; otherwise users get the right-click menu only. (ADR 0034 keeps Sprig out of the system menu bar entirely, which aligns.)
- **No way to override Finder's drag-and-drop semantics.** Dragging a file into a different repo to "git mv" it is not implementable via FinderSync.
- **No access to Finder's "Get Info" inspector.** Custom Sprig metadata (HEAD ref, last commit, etc.) cannot be added to the inspector; we surface it in the per-repo Status task window instead.
- **No Quick Look hook from FinderSync.** `.diff` files getting a Sprig Quick Look preview requires a separate `QLPreviewExtension` target (`apps/macos/SprigQuickLook/`, M6+).

## Versioning and rollout

- **Minimum macOS: 14 Sonoma** (ADR 0010). FinderSync API itself is stable since 10.10; nothing in our usage is Sonoma-specific. The reason for the floor is unrelated (`OSAllocatedUnfairLock`, modern Swift Concurrency, `@Observable`).
- The extension bundle is shipped inside the host app at `Sprig.app/Contents/PlugIns/SprigFinder.appex`. Sparkle updates the host app; the extension follows automatically.
- **Don't touch the bundle ID across releases.** See user-granted-paths above.

## Verification checklist for M2-Mac

- [ ] Extension registered: `pluginkit -m -p com.apple.FinderSync | grep com.sprig.SprigFinder` returns it.
- [ ] Badges render on a fixture repo within the watch root within 100ms of `git status` change.
- [ ] Right-click menu appears in <100 ms p99 against a fixture repo with 10k tracked files.
- [ ] Extension memory stays under 30 MB resident across a 5-minute scroll-through-many-folders session.
- [ ] Killing the extension (`pluginkit -e ignore -i com.sprig.SprigFinder` then re-enable) triggers full state rehydration from the agent in <1 s.
- [ ] System Settings → Extensions → Finder Extensions → Sprig is present and tickable.
- [ ] Network volume falls back to polling with the documented banner.
