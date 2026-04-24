# apps/macos/

The macOS app. Contains the SwiftUI + AppKit shell, the LaunchAgent background service, the FinderSync extension, the (stretch) Quick Look preview extension, and the DMG installer scripts.

This is the only `apps/` dir populated at 1.0. Windows and Linux shells, if ever built, are additive — they do **not** require reshaping any packages in `packages/`.

- `SprigApp/` — main app bundle; SwiftUI task windows; the only place `import AppKit/SwiftUI` is allowed.
- `SprigAgent/` — LaunchAgent wrapper around `AgentKit`.
- `SprigFinder/` — FinderSync extension; thin, delegates to SprigAgent over XPC.
- `SprigQuickLook/` — (M6+) `.diff` preview.
- `Resources/` — app icon, 10-badge asset catalog, `.xcstrings` string catalogs.
- `Entitlements/` — per-target entitlements plists.
- `LaunchAgent/` — `com.sprig.agent.plist` template.
- `Sparkle/` — appcast config + EdDSA public-key placeholder.
- `Installer/` — DMG + notarization scripts.

Xcode project skeletons are materialized in M2.
