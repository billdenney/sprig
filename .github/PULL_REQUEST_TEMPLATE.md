## Summary

<!-- 1–3 bullets describing the change -->

## Related ADRs

<!-- e.g., Implements ADR 0024. Supersedes part of ADR 0017. -->

## Test plan

- [ ] `./script/test` passes locally.
- [ ] No new banned imports in `packages/` (AppKit/SwiftUI/Cocoa/FinderSync/Combine/ServiceManagement/Sparkle).
- [ ] No new `#if os(...)` in portable package sources.
- [ ] No new hardcoded absolute paths.
- [ ] Destructive ops (if any) create snapshot refs via SafetyKit.
- [ ] CHANGELOG.md updated under `[Unreleased]` for user-visible changes.
