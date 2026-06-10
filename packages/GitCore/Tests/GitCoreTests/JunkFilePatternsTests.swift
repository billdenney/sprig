// JunkFilePatternsTests.swift
//
// Pure matcher tests for the shared junk-file rules (ADR 0075
// amendment / ADR 0070 amendment). Pins the four pattern shapes
// (exact, *.suffix, prefix*, *infix*), case-insensitivity, and the
// basename-only semantics — plus the pathspec projection's shape,
// since `:(exclude,glob)**/<pattern>` strings are what the backup
// engine actually emits.

import Foundation
@testable import GitCore
import Testing

@Suite("JunkFilePatterns — basename matcher + projections")
struct JunkFilePatternsTests {
    @Test("exact patterns match only the exact basename, case-insensitively")
    func exactMatch() {
        let rule = JunkFilePattern(gitignoreLine: ".DS_Store", category: .temporary)
        #expect(rule.matches(basename: ".DS_Store"))
        #expect(rule.matches(basename: ".ds_store"))
        #expect(!rule.matches(basename: "DS_Store"))
        #expect(!rule.matches(basename: "x.DS_Store"))
    }

    @Test("*.suffix patterns match any basename with the suffix")
    func suffixMatch() {
        let rule = JunkFilePattern(gitignoreLine: "*.env", category: .secret)
        #expect(rule.matches(basename: "prod.env"))
        #expect(rule.matches(basename: ".env"))
        #expect(rule.matches(basename: "Secrets.ENV"))
        #expect(!rule.matches(basename: "env"))
        #expect(!rule.matches(basename: "environment.txt"))
    }

    @Test("prefix* patterns match any basename with the prefix")
    func prefixMatch() {
        let office = JunkFilePattern(gitignoreLine: "~$*", category: .temporary)
        #expect(office.matches(basename: "~$Budget.xlsx"))
        #expect(!office.matches(basename: "Budget.xlsx"))

        let sshKey = JunkFilePattern(gitignoreLine: "id_rsa*", category: .secret)
        #expect(sshKey.matches(basename: "id_rsa"))
        #expect(sshKey.matches(basename: "id_rsa.pub"))
        #expect(!sshKey.matches(basename: "my_id_rsa"))
    }

    @Test("*infix* patterns match the substring anywhere")
    func infixMatch() {
        let rule = JunkFilePattern(gitignoreLine: "*credentials*", category: .secret)
        #expect(rule.matches(basename: "credentials"))
        #expect(rule.matches(basename: "aws_credentials.json"))
        #expect(
            rule.matches(basename: "CredentialsView.swift"),
            "documented trade-off: name-based rules over-match"
        )
        #expect(!rule.matches(basename: "creds.json"))
    }

    @Test("rule(matching:) matches by basename regardless of directory depth")
    func ruleByPath() {
        #expect(JunkFilePatterns.rule(matching: "config/secrets/prod.env") != nil)
        #expect(JunkFilePatterns.rule(matching: "docs/~$Report.docx") != nil)
        #expect(JunkFilePatterns.rule(matching: ".env.local") != nil)
        #expect(JunkFilePatterns.rule(matching: "Sources/App/main.swift") == nil)
        #expect(JunkFilePatterns.rule(matching: "README.md") == nil)
    }

    @Test("the curated set covers the ratified examples on both sides")
    func curatedCoverage() {
        let junk = [
            "deploy.pem", "server.key", "cert.p12", "cert.pfx",
            "id_ed25519", "id_ecdsa.pub", "secret_token.txt",
            "scratch.tmp", "build.temp", ".main.swift.swp", "draft.swo",
            "notes.txt~", "Thumbs.db"
        ]
        for name in junk {
            #expect(JunkFilePatterns.rule(matching: name) != nil, "\(name) should match")
        }
        let legit = ["main.swift", "Package.resolved", "keynote.md", "tmpdir_helper.swift"]
        for name in legit {
            #expect(JunkFilePatterns.rule(matching: name) == nil, "\(name) should NOT match")
        }
    }

    @Test("pathspec projection anchors every rule at any depth")
    func pathspecProjection() {
        #expect(JunkFilePatterns.backupExcludePathspecs.count == JunkFilePatterns.all.count)
        for spec in JunkFilePatterns.backupExcludePathspecs {
            #expect(spec.hasPrefix("**/"), "\(spec) must be depth-anchored")
        }
        #expect(JunkFilePatterns.backupExcludePathspecs.contains("**/*.env"))
        #expect(JunkFilePatterns.backupExcludePathspecs.contains("**/~$*"))
    }

    @Test("category split: secrets and temporaries are disjoint and ordered secrets-first")
    func categorySplit() {
        #expect(JunkFilePatterns.secrets.allSatisfy { $0.category == .secret })
        #expect(JunkFilePatterns.temporaries.allSatisfy { $0.category == .temporary })
        #expect(JunkFilePatterns.all == JunkFilePatterns.secrets + JunkFilePatterns.temporaries)
    }
}
