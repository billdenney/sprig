@testable import AIKit
import Foundation
import Testing

@Suite("AISituationExplainer")
struct AISituationExplainerTests {
    private func bundledPrompt() throws -> Prompt {
        try PromptLoader.loadBundled(named: AISituationExplainer.promptName)
    }

    @Test("AI success surfaces the provider's text tagged as .ai")
    func aiSuccessSurfacesText() async throws {
        let response = AIResponse(
            text: "Your branch is ahead by two commits. Push to share them.",
            finishReason: .stop
        )
        let provider = MockAIProvider.always(response)
        let explainer = try AISituationExplainer(provider: provider, prompt: bundledPrompt())

        let situation = RepoSituation(upstreamName: "origin/main", ahead: 2)
        let explanation = await explainer.explain(situation)

        #expect(explanation.source == .ai)
        #expect(explanation.text == response.text)
        // Suggestions stay deterministic so the UI always has real verbs.
        #expect(explanation.suggestions.first?.verb == .push)
    }

    @Test("the rendered request carries the prompt body and the situation fields")
    func requestRendersPromptAndSituation() async throws {
        let provider = MockAIProvider.always(AIResponse(text: "ok", finishReason: .stop))
        let explainer = try AISituationExplainer(provider: provider, prompt: bundledPrompt())

        let situation = RepoSituation(
            branchName: "feature/login",
            upstreamName: "origin/feature/login",
            ahead: 1,
            behind: 2,
            unstagedCount: 3,
            conflictedCount: 0,
            parkedOperation: .rebase,
            recentReflog: ["checkout: moving from main to feature/login"]
        )
        _ = await explainer.explain(situation)

        let log = await provider.requestLog
        #expect(log.count == 1)
        let request = try #require(log.first)
        // The prompt body becomes the system prompt.
        #expect(request.systemPrompt?.contains("situation explainer") == true)
        // The snapshot (user prompt) carries the structured fields.
        let user = request.userPrompt
        #expect(user.contains("branch: feature/login"))
        #expect(user.contains("ahead of upstream: 1"))
        #expect(user.contains("behind upstream: 2"))
        #expect(user.contains("unstaged changes: 3"))
        #expect(user.contains("parked operation: rebase"))
        #expect(user.contains("checkout: moving from main to feature/login"))
        // Conservative generation params.
        #expect(request.maxTokens == AISituationExplainer.maxTokens)
        #expect(request.temperature == AISituationExplainer.temperature)
    }

    @Test("a provider error falls back to the deterministic explanation")
    func providerErrorFallsBack() async throws {
        let provider = MockAIProvider(outcomes: [
            .error(.providerUnavailable(provider: "mock", underlying: "ollama not running"))
        ])
        let explainer = try AISituationExplainer(provider: provider, prompt: bundledPrompt())

        let situation = RepoSituation(upstreamName: "origin/main", behind: 5)
        let explanation = await explainer.explain(situation)

        #expect(explanation.source == .deterministic)
        #expect(explanation.text.contains("5 commit"))
        #expect(explanation.suggestions.first?.verb == .pull)
    }

    @Test("an empty completion falls back rather than surfacing blank text")
    func emptyCompletionFallsBack() async throws {
        let provider = MockAIProvider.always(AIResponse(text: "   \n  ", finishReason: .stop))
        let explainer = try AISituationExplainer(provider: provider, prompt: bundledPrompt())

        let situation = RepoSituation(conflictedCount: 1)
        let explanation = await explainer.explain(situation)
        #expect(explanation.source == .deterministic)
        #expect(!explanation.text.isEmpty)
    }

    @Test("AI prose instructing a raw git command falls back to deterministic")
    func rawGitInstructionFallsBack() async throws {
        let provider = MockAIProvider.always(
            AIResponse(text: "You should run git reset --hard HEAD~1 to undo this.", finishReason: .stop)
        )
        let explainer = try AISituationExplainer(provider: provider, prompt: bundledPrompt())
        let explanation = await explainer.explain(RepoSituation(upstreamName: "origin/main", behind: 2))
        // Suggest-only stance: raw-git prose is rejected for the safe template.
        #expect(explanation.source == .deterministic)
        #expect(!explanation.text.lowercased().contains("git reset"))
    }

    @Test("AI prose implying data loss falls back to deterministic")
    func dataLossPhrasingFallsBack() async throws {
        let provider = MockAIProvider.always(
            AIResponse(text: "Your uncommitted changes are gone and cannot be recovered.", finishReason: .stop)
        )
        let explainer = try AISituationExplainer(provider: provider, prompt: bundledPrompt())
        let explanation = await explainer.explain(RepoSituation(unstagedCount: 1))
        #expect(explanation.source == .deterministic)
    }

    @Test("benign prose mentioning Git the tool is NOT rejected")
    func benignGitMentionIsKept() async throws {
        let provider = MockAIProvider.always(
            AIResponse(text: "Your Git branch is ahead by two commits. Use Push to share them.", finishReason: .stop)
        )
        let explainer = try AISituationExplainer(provider: provider, prompt: bundledPrompt())
        let explanation = await explainer.explain(RepoSituation(upstreamName: "origin/main", ahead: 2))
        #expect(explanation.source == .ai)
    }

    @Test("violatesSafetyRules flags raw git commands and data-loss phrasing, not plain text")
    func safetyGuardUnit() {
        #expect(AISituationExplainer.violatesSafetyRules("Run git reset --hard to undo."))
        #expect(AISituationExplainer.violatesSafetyRules("You could git rebase onto main."))
        #expect(AISituationExplainer.violatesSafetyRules("Those edits are gone forever."))
        #expect(!AISituationExplainer.violatesSafetyRules("Your branch is ahead. Use Push to share."))
        #expect(!AISituationExplainer.violatesSafetyRules("Everything is in sync — nothing to do."))
        // Noun phrases naming Git the tool must NOT be flagged.
        #expect(!AISituationExplainer.violatesSafetyRules("Your Git branch is ahead by two commits."))
        #expect(!AISituationExplainer.violatesSafetyRules("You have a git merge conflict to resolve."))
    }

    @Test("the AI text is trimmed of surrounding whitespace")
    func aiTextTrimmed() async throws {
        let provider = MockAIProvider.always(
            AIResponse(text: "\n\n  You are all caught up.  \n", finishReason: .stop)
        )
        let explainer = try AISituationExplainer(provider: provider, prompt: bundledPrompt())
        let explanation = await explainer.explain(RepoSituation(branchName: "main"))
        #expect(explanation.text == "You are all caught up.")
        #expect(explanation.source == .ai)
    }

    @Test("no provider (AI disabled) takes the deterministic path without any call")
    func noProviderIsDeterministic() async throws {
        let explainer = try AISituationExplainer(provider: nil, prompt: bundledPrompt())
        let situation = RepoSituation(upstreamName: "origin/main", ahead: 1, behind: 1)
        let explanation = await explainer.explain(situation)
        #expect(explanation.source == .deterministic)
        #expect(explanation.text.contains("diverged"))
    }

    @Test("convenience init loads the bundled prompt")
    func convenienceInitLoadsBundledPrompt() async throws {
        let provider = MockAIProvider.always(AIResponse(text: "hi", finishReason: .stop))
        let explainer = try AISituationExplainer(provider: provider)
        _ = await explainer.explain(RepoSituation(branchName: "main"))
        let log = await provider.requestLog
        #expect(log.first?.systemPrompt?.contains("situation explainer") == true)
    }

    @Test("detached HEAD renders as such in the snapshot, not as a branch line")
    func detachedHeadSnapshot() {
        let situation = RepoSituation(isDetachedHead: true)
        let snapshot = AISituationExplainer.renderSnapshot(situation)
        #expect(snapshot.contains("HEAD: detached"))
        #expect(!snapshot.contains("branch:"))
    }
}
