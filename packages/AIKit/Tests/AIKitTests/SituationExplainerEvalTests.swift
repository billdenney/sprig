@testable import AIKit
import Foundation
import Testing

/// Drives the held-out `tests/ai-evals/situation-explainer-v1.json`
/// corpus (ADR 0038 / ADR 0095) through the deterministic explainer
/// — the always-available path the AI guidance is held consistent
/// with. Each fixture case pins the SHAPE of the guidance: the lead
/// verb, required verbs, and headline substrings. No LLM is involved
/// (the engine is fully testable without one); the corpus is the
/// regression net that fails loudly if the guidance ever proposes an
/// action with no Sprig affordance or stops naming the user's state.
@Suite("Situation explainer — held-out eval corpus")
struct SituationExplainerEvalTests {
    // MARK: Fixture decoding

    private struct Corpus: Decodable {
        let prompt: String
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let situation: SituationFixture
        let expect: Expectation
    }

    private struct SituationFixture: Decodable {
        var branchName: String?
        var isDetachedHead: Bool?
        var upstreamName: String?
        var upstreamGone: Bool?
        var ahead: Int?
        var behind: Int?
        var stagedCount: Int?
        var unstagedCount: Int?
        var untrackedCount: Int?
        var conflictedCount: Int?
        var parkedOperation: String?
        var recentReflog: [String]?

        func toSituation() -> RepoSituation {
            RepoSituation(
                branchName: branchName,
                isDetachedHead: isDetachedHead ?? false,
                upstreamName: upstreamName,
                upstreamGone: upstreamGone ?? false,
                ahead: ahead ?? 0,
                behind: behind ?? 0,
                stagedCount: stagedCount ?? 0,
                unstagedCount: unstagedCount ?? 0,
                untrackedCount: untrackedCount ?? 0,
                conflictedCount: conflictedCount ?? 0,
                parkedOperation: parkedOperation
                    .flatMap(ParkedOperation.init(rawValue:)) ?? .none,
                recentReflog: recentReflog ?? []
            )
        }
    }

    private struct Expectation: Decodable {
        let leadVerb: String
        let mustContainVerbs: [String]
        var headlineContains: [String]?
        var mustNotContainVerbs: [String]?
    }

    // MARK: Corpus location

    /// Resolve `tests/ai-evals/` by walking up from this source file
    /// (`packages/AIKit/Tests/AIKitTests/…`). The eval corpus lives at
    /// the repo root, outside any SwiftPM resource bundle, so it's
    /// reached by path rather than `Bundle.module`.
    private static func corpusURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AIKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AIKit
            .deletingLastPathComponent() // packages
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("tests")
            .appendingPathComponent("ai-evals")
            .appendingPathComponent("situation-explainer-v1.json")
    }

    private func loadCorpus() throws -> Corpus {
        let data = try Data(contentsOf: Self.corpusURL())
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    // MARK: Tests

    @Test("the corpus targets the shipped prompt and is non-empty")
    func corpusMetadata() throws {
        let corpus = try loadCorpus()
        #expect(corpus.prompt == AISituationExplainer.promptName)
        #expect(!corpus.cases.isEmpty)
    }

    @Test("every corpus case matches the deterministic guidance shape")
    func everyCaseMatchesExpectedShape() throws {
        let corpus = try loadCorpus()
        for testCase in corpus.cases {
            let explanation = DeterministicSituationExplainer
                .explain(testCase.situation.toSituation())
            let verbs = explanation.suggestions.map(\.verb.rawValue)

            #expect(
                verbs.first == testCase.expect.leadVerb,
                "case \(testCase.name): expected lead verb \(testCase.expect.leadVerb), got \(verbs)"
            )
            for required in testCase.expect.mustContainVerbs {
                #expect(
                    verbs.contains(required),
                    "case \(testCase.name): missing required verb \(required) in \(verbs)"
                )
            }
            for absent in testCase.expect.mustNotContainVerbs ?? [] {
                #expect(
                    !verbs.contains(absent),
                    "case \(testCase.name): verb \(absent) should be absent, got \(verbs)"
                )
            }
            for needle in testCase.expect.headlineContains ?? [] {
                #expect(
                    explanation.text.contains(needle),
                    "case \(testCase.name): headline missing \"\(needle)\": \(explanation.text)"
                )
            }
        }
    }

    @Test("corpus verbs are all part of the closed SprigVerb set")
    func corpusVerbsAreKnown() throws {
        let corpus = try loadCorpus()
        let known = Set(SprigVerb.allCases.map(\.rawValue))
        for testCase in corpus.cases {
            #expect(known.contains(testCase.expect.leadVerb))
            for verb in testCase.expect.mustContainVerbs {
                #expect(
                    known.contains(verb),
                    "case \(testCase.name): \(verb) is not a known SprigVerb"
                )
            }
        }
    }
}
