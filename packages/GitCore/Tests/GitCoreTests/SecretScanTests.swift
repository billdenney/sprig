// SecretScanTests.swift
//
// ADR 0092 — corpus tests for the vendored secret ruleset + the diff
// parser. Pure tests (no git) cover the rules/entropy/parsing; one
// integration test stages a real secret and asserts scanStaged finds it.
//
// NOTE: every secret-shaped fixture is ASSEMBLED FROM FRAGMENTS at
// runtime (see `Fixtures`), so no contiguous secret literal is ever
// committed to source. That keeps these tests from tripping GitHub's
// secret-scanning push protection (and is good hygiene), while the
// assembled runtime value is full-shape so the rules still fire.

import Foundation
@testable import GitCore
import Testing

@Suite("SecretScan — vendored ruleset + diff scanning")
struct SecretScanTests {
    let scan = SecretScan()

    /// Full-shape, never-real secrets built from fragments (see file note).
    enum Fixtures {
        static let aws = "AKIA" + "IOSFODNN7EXAMPLE"
        static let githubPat = "ghp_" + String(repeating: "a", count: 36)
        static let gitlabPat = "glpat-" + String(repeating: "x", count: 20)
        static let googleKey = "AIza" + String(repeating: "0", count: 35)
        static let slackToken = "xoxb-" + "123456789012-abcdefghij"
        static let stripeKey = "sk_live_" + String(repeating: "0", count: 24)
        static let privateKeyHeader = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
        static let jwt = "eyJ" + "hbGciOiJIUzI1NiJ9" + "." + "eyJ" + "zdWIiOiIxMjMifQ" + "." + "abc123DEF456ghi"
    }

    // MARK: - Positive corpus (real-shaped secrets are caught)

    @Test("catches provider-specific token shapes")
    func catchesProviderTokens() {
        let cases: [(String, String)] = [
            (Fixtures.aws, "aws-access-key-id"),
            (Fixtures.githubPat, "github-pat"),
            (Fixtures.gitlabPat, "gitlab-pat"),
            (Fixtures.googleKey, "google-api-key"),
            (Fixtures.slackToken, "slack-token"),
            (Fixtures.stripeKey, "stripe-secret-key")
        ]
        for (secret, expectedRule) in cases {
            let found = scan.scan(line: "let k = \"\(secret)\"", lineNumber: 1, path: "config.swift")
            #expect(found.contains { $0.ruleID == expectedRule }, "expected \(expectedRule) to fire on \(secret)")
        }
    }

    @Test("catches a private key header and a JWT")
    func catchesKeyAndJWT() {
        let pk = scan.scan(line: Fixtures.privateKeyHeader, lineNumber: 1, path: "id_x")
        #expect(pk.contains { $0.ruleID == "private-key-block" })
        let found = scan.scan(line: "token=\(Fixtures.jwt)", lineNumber: 1, path: "a.txt")
        #expect(found.contains { $0.ruleID == "jwt" })
    }

    @Test("catches a high-entropy generic secret assignment")
    func catchesGenericHighEntropy() {
        let value = "a8Fk39Lm02" + "QzXp71Rt55"
        let found = scan.scan(line: "api_key = \"\(value)\"", lineNumber: 1, path: "settings.py")
        #expect(found.contains { $0.ruleID == "generic-secret-assignment" })
    }

    // MARK: - Negative corpus (placeholders are NOT caught)

    @Test("does not flag low-entropy placeholder assignments")
    func ignoresPlaceholders() {
        for line in [
            "password = \"changeme1234\"",
            "token = \"your-token-here\"",
            "api_key = \"TODO_FILL_THIS_IN\"",
            "secret = \"xxxxxxxxxxxx\""
        ] {
            let found = scan.scan(line: line, lineNumber: 1, path: "example.env")
            #expect(found.isEmpty, "placeholder should not fire: \(line)")
        }
    }

    @Test("does not flag ordinary prose or code")
    func ignoresOrdinaryContent() {
        for line in [
            "// this function returns the access key from the vault",
            "let greeting = \"hello world\"",
            "print(\"the quick brown fox jumps\")"
        ] {
            #expect(scan.scan(line: line, lineNumber: 1, path: "a.swift").isEmpty, "should not fire: \(line)")
        }
    }

    @Test("entropy floor separates a real key from a repeated-char string of equal length")
    func entropyFloor() {
        let realValue = "a8Fk39Lm02" + "QzXp71Rt55"
        let real = "api_key = \"\(realValue)\""
        let fake = "api_key = \"" + String(repeating: "a", count: 20) + "\""
        #expect(!scan.scan(line: real, lineNumber: 1, path: "x").isEmpty)
        #expect(scan.scan(line: fake, lineNumber: 1, path: "x").isEmpty)
    }

    // MARK: - Diff parsing (added lines only, correct line numbers)

    @Test("scans only added lines and reports the new-side line number")
    func parsesAddedLinesWithLineNumbers() {
        let diff = """
        diff --git a/app/config.py b/app/config.py
        index e69de29..1a2b3c4 100644
        --- a/app/config.py
        +++ b/app/config.py
        @@ -0,0 +5,2 @@
        +AWS_KEY = "\(Fixtures.aws)"
        +debug = true
        """
        let findings = scan.scan(unifiedDiff: diff)
        #expect(findings.count == 1)
        let f = findings.first
        #expect(f?.path == "app/config.py")
        #expect(f?.ruleID == "aws-access-key-id")
        #expect(f?.line == 5, "should report the new-side hunk start line")
    }

    @Test("ignores removed lines — deleting a secret is not a finding")
    func ignoresRemovedLines() {
        let diff = """
        diff --git a/secrets.txt b/secrets.txt
        --- a/secrets.txt
        +++ b/secrets.txt
        @@ -1 +0,0 @@
        -\(Fixtures.githubPat)
        """
        #expect(scan.scan(unifiedDiff: diff).isEmpty)
    }

    // MARK: - Allowlist

    @Test("allowlist suppresses by exact match and by path:ruleID")
    func allowlistSuppression() {
        let diff = """
        --- a/c.py
        +++ b/c.py
        @@ -0,0 +1 @@
        +KEY = "\(Fixtures.aws)"
        """
        #expect(scan.scan(unifiedDiff: diff).count == 1)
        #expect(scan.scan(unifiedDiff: diff, allowlist: [Fixtures.aws]).isEmpty)
        #expect(scan.scan(unifiedDiff: diff, allowlist: ["c.py:aws-access-key-id"]).isEmpty)
        #expect(scan.scan(unifiedDiff: diff, allowlist: ["other.py:aws-access-key-id"]).count == 1)
    }

    @Test("redactedMatch masks the middle of a secret")
    func redaction() {
        let f = SecretFinding(path: "a", ruleID: "r", ruleTitle: "R", line: 1, match: Fixtures.aws)
        #expect(f.redactedMatch == "AKIA…LE")
        #expect(!f.redactedMatch.contains("OSFODNN"))
    }

    // MARK: - Integration (real git fixture)

    @Test("scanStaged finds a secret staged into a real repo")
    func scanStagedRealGit() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-secretscan-\(UUID().uuidString)").standardized
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runner = Runner(defaultWorkingDirectory: tmp)
        _ = try await runner.run(["init", "-b", "main"])
        _ = try await runner.run(["config", "user.email", "t@sprig.app"])
        _ = try await runner.run(["config", "user.name", "T"])

        try Data("AWS_KEY = \"\(Fixtures.aws)\"\nok = 1\n".utf8)
            .write(to: tmp.appendingPathComponent("config.py"))
        _ = try await runner.run(["add", "config.py"])

        let findings = try await SecretScan().scanStaged(runner: runner)
        #expect(findings.contains { $0.ruleID == "aws-access-key-id" && $0.path == "config.py" })

        // Allowlist file is honored.
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent(".sprig"), withIntermediateDirectories: true)
        try Data("config.py:aws-access-key-id\n".utf8).write(to: tmp.appendingPathComponent(".sprig/secret-allow"))
        let allow = SecretScan.loadAllowlist(repoURL: tmp)
        let suppressed = try await SecretScan().scanStaged(runner: runner, allowlist: allow)
        #expect(!suppressed.contains { $0.ruleID == "aws-access-key-id" })
    }
}
