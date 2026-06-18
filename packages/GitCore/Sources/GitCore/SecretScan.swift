// SecretScan.swift
//
// ADR 0092 — a gitleaks-style staged-secret scan, promoted from M6 into
// the pre-flight rail family (ADR 0070). This is the ENGINE: it scans
// the *added* lines of a diff (the staged tree for the commit-time rail,
// or a commit range for the push-time rail in ADR 0093) against a
// curated, VENDORED ruleset (named regexes + an entropy gate on the
// generic rules). The rail UI, suppression, and remedies live in
// TaskWindowKit; this file only finds candidates.
//
// What this is NOT:
//   - It is not a bundled `gitleaks` binary. We vendor the *rules*
//     (data), never the executable. A detect-and-use hand-off to a
//     `gitleaks` on PATH (à la the LFS flow, ADR 0029/0047) is a
//     documented follow-up; the vendored ruleset is the always-available
//     default so the rail works with zero external dependencies.
//   - It is not a blocking pre-commit hook (wrong layer — ADR 0050).
//     Findings drive a warn-and-proceed banner, never a block.
//
// Scope discipline: we scan ADDED lines only (the `+` side of a unified
// diff), never the whole tree — a pre-existing secret elsewhere in the
// file is out of scope for the commit that didn't touch it. All git
// invocation routes through `Runner` (CLAUDE.md rule 5).

import Foundation

/// One candidate secret found in added content.
public struct SecretFinding: Sendable, Equatable, Hashable {
    /// Repo-relative path of the file the match was found in.
    public let path: String
    /// Stable rule identifier (e.g. `aws-access-key-id`) — used in the
    /// banner copy and in `path:ruleID` allowlist entries.
    public let ruleID: String
    /// Human-readable rule name for the banner (e.g. `AWS Access Key ID`).
    public let ruleTitle: String
    /// 1-based line number on the new side of the diff.
    public let line: Int
    /// The matched secret text. Used for allowlisting and (redacted) for
    /// display — never logged in full.
    public let match: String

    public init(path: String, ruleID: String, ruleTitle: String, line: Int, match: String) {
        self.path = path
        self.ruleID = ruleID
        self.ruleTitle = ruleTitle
        self.line = line
        self.match = match
    }

    /// A redacted form safe to show in a banner: first 4 and last 2
    /// characters with the middle masked (short matches fully masked).
    public var redactedMatch: String {
        let chars = Array(match)
        guard chars.count > 8 else { return String(repeating: "•", count: chars.count) }
        return String(chars.prefix(4)) + "…" + String(chars.suffix(2))
    }

    /// The canonical allowlist key for this finding (`<path>:<ruleID>`),
    /// the coarse-grained suppression form.
    public var allowlistKey: String {
        "\(path):\(ruleID)"
    }
}

/// One vendored detection rule.
public struct SecretScanRule: Sendable {
    public let id: String
    public let title: String
    let regex: NSRegularExpression
    /// Capture group holding the secret value (0 = whole match). Used
    /// both for the reported `match` and for the entropy gate.
    let secretGroup: Int
    /// If set, the captured value's Shannon entropy (bits/char) must
    /// meet this floor — keeps the generic `key = value` rules from
    /// firing on obvious non-secrets like `password = changeme`.
    let minEntropyBitsPerChar: Double?

    init(id: String, title: String, pattern: String, secretGroup: Int = 0, minEntropyBitsPerChar: Double? = nil) {
        self.id = id
        self.title = title
        // Patterns are curated constants; a bad pattern is a programmer
        // error we want to surface loudly in tests, not silently skip.
        // swiftlint:disable:next force_try
        self.regex = try! NSRegularExpression(pattern: pattern, options: [])
        self.secretGroup = secretGroup
        self.minEntropyBitsPerChar = minEntropyBitsPerChar
    }
}

/// Stateless staged/range secret scanner over a curated ruleset.
public struct SecretScan: Sendable {
    public let rules: [SecretScanRule]

    public init(rules: [SecretScanRule] = SecretScan.defaultRules) {
        self.rules = rules
    }

    // MARK: - Git-backed entry points

    /// Scan the added lines of the staged tree (`git diff --cached`).
    /// `allowlist` entries (exact matched value, or `<path>:<ruleID>`)
    /// suppress known-safe findings without disabling the rail.
    public func scanStaged(runner: Runner, allowlist: Set<String> = []) async throws -> [SecretFinding] {
        let out = try await runner.run(["diff", "--cached", "--unified=0", "--no-color"])
        return scan(unifiedDiff: out.stdoutString, allowlist: allowlist)
    }

    /// Scan the added lines introduced by a commit range (e.g.
    /// `@{u}..HEAD`) — the ADR 0093 push-time variant, which catches a
    /// secret committed in an *earlier* commit that is about to leave the
    /// machine, not just staged content.
    public func scanRange(_ range: String, runner: Runner, allowlist: Set<String> = []) async throws -> [SecretFinding] {
        let out = try await runner.run(["diff", "--unified=0", "--no-color", range])
        return scan(unifiedDiff: out.stdoutString, allowlist: allowlist)
    }

    /// Load `.sprig/secret-allow` (one allowlist entry per line; `#`
    /// comments and blanks ignored). Missing file → empty set.
    public static func loadAllowlist(repoURL: URL) -> Set<String> {
        let url = repoURL.appendingPathComponent(".sprig/secret-allow")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries: Set<String> = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            entries.insert(line)
        }
        return entries
    }

    // MARK: - Pure scanning (testable without git)

    /// Parse a unified diff and scan its added (`+`) lines, tracking the
    /// new-side line number. Robust to `--unified=0` output (no context
    /// lines). Removed (`-`) lines do not advance the new-side counter.
    public func scan(unifiedDiff: String, allowlist: Set<String> = []) -> [SecretFinding] {
        var findings: [SecretFinding] = []
        var path = ""
        var newLine = 0
        for raw in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(raw)
            if lineStr.hasPrefix("+++ ") {
                path = Self.parseDiffPath(lineStr)
                continue
            }
            if lineStr.hasPrefix("--- ") || lineStr.hasPrefix("diff ") || lineStr.hasPrefix("index ") {
                continue
            }
            if lineStr.hasPrefix("@@") {
                newLine = Self.parseHunkNewStart(lineStr) ?? newLine
                continue
            }
            if lineStr.hasPrefix("+") {
                let content = String(lineStr.dropFirst())
                findings += scan(line: content, lineNumber: newLine, path: path)
                newLine += 1
            } else if lineStr.hasPrefix("-") {
                // removed line — does not advance the new-side counter
                continue
            } else {
                // context line (only with -U>0); advances the new side
                newLine += 1
            }
        }
        guard !allowlist.isEmpty else { return findings }
        return findings.filter { !allowlist.contains($0.match) && !allowlist.contains($0.allowlistKey) }
    }

    /// Scan a single line of content against every rule. Exposed for
    /// unit tests (no git, no diff framing).
    public func scan(line content: String, lineNumber: Int, path: String) -> [SecretFinding] {
        guard !content.isEmpty else { return [] }
        let range = NSRange(content.startIndex ..< content.endIndex, in: content)
        var out: [SecretFinding] = []
        for rule in rules {
            rule.regex.enumerateMatches(in: content, options: [], range: range) { result, _, _ in
                guard let result else { return }
                let group = rule.secretGroup < result.numberOfRanges ? rule.secretGroup : 0
                let nsr = result.range(at: group)
                guard nsr.location != NSNotFound, let r = Range(nsr, in: content) else { return }
                let secret = String(content[r])
                if let floor = rule.minEntropyBitsPerChar, Self.shannonEntropyBitsPerChar(secret) < floor {
                    return
                }
                out.append(SecretFinding(
                    path: path,
                    ruleID: rule.id,
                    ruleTitle: rule.title,
                    line: lineNumber,
                    match: secret
                ))
            }
        }
        return out
    }

    // MARK: - Helpers

    /// `+++ b/path/to/file` → `path/to/file`; `/dev/null` → "".
    static func parseDiffPath(_ line: String) -> String {
        var s = String(line.dropFirst(4)) // drop "+++ "
        if s == "/dev/null" { return "" }
        if s.hasPrefix("b/") { s = String(s.dropFirst(2)) }
        // Strip a trailing tab+timestamp some git configs emit.
        if let tab = s.firstIndex(of: "\t") { s = String(s[..<tab]) }
        return s
    }

    /// `@@ -a,b +c,d @@` → c (the new-side start line). `+c` (no count)
    /// is also valid.
    static func parseHunkNewStart(_ line: String) -> Int? {
        guard let plus = line.firstIndex(of: "+") else { return nil }
        let after = line[line.index(after: plus)...]
        let digits = after.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Shannon entropy in bits per character — the standard high-entropy
    /// heuristic for distinguishing a real key from a placeholder.
    static func shannonEntropyBitsPerChar(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s {
            counts[c, default: 0] += 1
        }
        let n = Double(s.count)
        var bits = 0.0
        for count in counts.values {
            let p = Double(count) / n
            bits -= p * (log(p) / log(2))
        }
        return bits
    }

    // MARK: - Vendored ruleset

    /// Curated default rules. A focused, high-signal subset of the
    /// gitleaks ruleset (specific provider token shapes catch the common
    /// real leaks; the entropy-gated generic rules catch the rest).
    /// Maintenance item: refresh against upstream gitleaks periodically
    /// (ADR 0092 consequence).
    public static let defaultRules: [SecretScanRule] = [
        .init(id: "aws-access-key-id", title: "AWS Access Key ID", pattern: "\\b(AKIA|ASIA)[0-9A-Z]{16}\\b"),
        .init(id: "github-pat", title: "GitHub Personal Access Token", pattern: "\\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\\b"),
        .init(id: "github-fine-grained-pat", title: "GitHub Fine-Grained Token", pattern: "\\bgithub_pat_[A-Za-z0-9_]{22,}\\b"),
        .init(id: "gitlab-pat", title: "GitLab Personal Access Token", pattern: "\\bglpat-[A-Za-z0-9_-]{20}\\b"),
        .init(id: "slack-token", title: "Slack Token", pattern: "\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b"),
        .init(id: "google-api-key", title: "Google API Key", pattern: "\\bAIza[0-9A-Za-z_-]{35}\\b"),
        .init(id: "stripe-secret-key", title: "Stripe Secret Key", pattern: "\\b(sk|rk)_(live|test)_[A-Za-z0-9]{20,}\\b"),
        .init(id: "private-key-block", title: "Private Key", pattern: "-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"),
        .init(id: "jwt", title: "JSON Web Token", pattern: "\\beyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b"),
        // Entropy-gated generic assignment: `secret = "<high-entropy>"`.
        // secretGroup 2 is the value; the entropy floor keeps it off
        // `password = "changeme"` and `token = "TODO"`.
        .init(
            id: "generic-secret-assignment",
            title: "Generic Secret Assignment",
            pattern: "(?i)(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)"
                + "[\"']?\\s*[:=]\\s*[\"']([^\"'\\s]{12,})[\"']",
            secretGroup: 1,
            minEntropyBitsPerChar: 3.5
        )
    ]
}
