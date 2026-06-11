// CredentialKit — adapter (Tier 2) package.
// The protocol (`CredentialStore`) lives here, portable — and so
// does the DEFAULT implementation, `GitCredentialChainStore`, which
// defers to the user's `git credential` helper chain on every OS
// (ADR 0080). The Sources/Mac, Sources/Linux, Sources/Windows stubs
// remain the slots for native keystore adapters if helper-chain
// coverage ever proves insufficient.
// See ADR 0048, ADR 0080, and CLAUDE.md.

import Foundation
import PlatformKit

public enum CredentialKit {
    public static let moduleName = "CredentialKit"
}
