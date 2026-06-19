// CreateReleaseViewModel.swift
//
// ADR 0087 — the portable engine behind the "Create Release…" task
// window: optionally create a new annotated tag locally, then publish a
// GitHub/GitLab Release (title + notes) and upload assets.
//
// **Publishing is consent.** Release creation is a publish action, so
// it's two-step by construction: ``prepare()`` builds a ``ReleaseSummary``
// of exactly what will be created where, the shell shows that as a
// confirmation, and only then may ``publish()`` run. `publish()` refuses
// until `prepare()` has been called — it is never automatic and never
// implied by another verb.
//
// Tier 1, portable. Tag creation via `GitCore.TagOps` (Runner); the
// forge calls via `ForgeKit.ForgeReleaseClient` (HTTP through the
// injected `ForgeHTTPClient`, never persisting the token).

import ForgeKit
import Foundation
import GitCore

/// A confirmation summary of what ``CreateReleaseViewModel/publish()``
/// will do — shown to the user before anything is created.
public struct ReleaseSummary: Sendable, Equatable {
    public let provider: ForgeProvider
    /// `owner/repo`.
    public let repository: String
    public let tagName: String
    /// True when a new annotated tag will be created (vs. using an
    /// existing tag).
    public let willCreateTag: Bool
    public let title: String?
    public let assetCount: Int

    public init(
        provider: ForgeProvider,
        repository: String,
        tagName: String,
        willCreateTag: Bool,
        title: String?,
        assetCount: Int
    ) {
        self.provider = provider
        self.repository = repository
        self.tagName = tagName
        self.willCreateTag = willCreateTag
        self.title = title
        self.assetCount = assetCount
    }
}

/// View model for the Create Release task window.
public actor CreateReleaseViewModel {
    public let repoURL: URL
    public let provider: ForgeProvider
    public let owner: String
    public let repo: String

    public private(set) var tagName: String
    /// When non-nil, a new annotated tag is created at this commit before
    /// the release; nil uses the existing tag `tagName`.
    public private(set) var createTagAtCommit: String?
    public private(set) var title: String
    public private(set) var notes: String
    public private(set) var assetURLs: [URL]

    /// The confirmation summary from ``prepare()``; nil until prepared.
    /// `publish()` refuses while this is nil (consent gate).
    public private(set) var summary: ReleaseSummary?

    /// Lifecycle of the publish. Success carries the created release.
    public private(set) var state: TaskWindowState<Release> = .idle

    /// The forge release once created — retained across a partial failure
    /// so a re-`publish()` resumes asset upload instead of re-creating the
    /// (already-live) release.
    public private(set) var createdRelease: Release?

    /// Assets uploaded so far; accumulates across publish attempts.
    public private(set) var uploadedAssets: [ReleaseAsset] = []

    private let runner: Runner
    private let releaseClient: ForgeReleaseClient
    private let token: String

    public init(
        repoURL: URL,
        provider: ForgeProvider,
        owner: String,
        repo: String,
        token: String,
        runner: Runner,
        releaseClient: ForgeReleaseClient = ForgeReleaseClient(),
        tagName: String = "",
        title: String = "",
        notes: String = "",
        createTagAtCommit: String? = nil,
        assetURLs: [URL] = []
    ) {
        self.repoURL = repoURL
        self.provider = provider
        self.owner = owner
        self.repo = repo
        self.token = token
        self.runner = runner
        self.releaseClient = releaseClient
        self.tagName = tagName
        self.title = title
        self.notes = notes
        self.createTagAtCommit = createTagAtCommit
        self.assetURLs = assetURLs
    }

    // MARK: - Form

    public func setTagName(_ value: String) {
        tagName = value; summary = nil
    }

    public func setTitle(_ value: String) {
        title = value; summary = nil
    }

    public func setNotes(_ value: String) {
        notes = value; summary = nil
    }

    public func setAssets(_ urls: [URL]) {
        assetURLs = urls; summary = nil
    }

    public func setCreateTagAtCommit(_ commit: String?) {
        createTagAtCommit = commit; summary = nil
    }

    // MARK: - Consent + publish

    /// Build the confirmation summary the shell shows before publishing.
    /// Returns nil (and records a validation failure) when the tag name
    /// is empty.
    @discardableResult
    public func prepare() -> ReleaseSummary? {
        let trimmedTag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty else {
            state = .failure(.init(description: TaskWindowVocabulary.releaseNeedsTag))
            return nil
        }
        let built = ReleaseSummary(
            provider: provider,
            repository: "\(owner)/\(repo)",
            tagName: trimmedTag,
            willCreateTag: createTagAtCommit != nil,
            title: title.isEmpty ? nil : title,
            assetCount: assetURLs.count
        )
        summary = built
        return built
    }

    /// Publish the release — only after ``prepare()`` (consent). Order is
    /// deliberate so a partial failure is never silently lost:
    ///   1. Create the forge release FIRST (nothing local is mutated
    ///      before it succeeds, so a forge failure leaves no orphan tag and
    ///      retry is clean), and retain it in ``createdRelease``.
    ///   2. Create the local annotated tag best-effort (the published
    ///      release is the source of truth; a local-tag failure must not
    ///      fail the publish).
    ///   3. Upload assets; on a failure report partial success (the
    ///      release IS live) and keep what uploaded, so a re-`publish()`
    ///      resumes the remaining assets rather than re-creating the release.
    public func publish() async {
        if case .busy = state { return }
        guard summary != nil else {
            state = .failure(.init(description: TaskWindowVocabulary.confirmReleaseFirst))
            return
        }
        state = .busy(progress: nil)
        do {
            let release: Release
            if let existing = createdRelease {
                release = existing // resume: the release is already live
            } else {
                // Read-only pre-flight: a NEW tag must not already exist.
                if createTagAtCommit != nil, try await TagOps(runner: runner).exists(tagName) {
                    state = .failure(.init(description: TaskWindowVocabulary.releaseTagExists(tagName)))
                    return
                }
                let request = CreateReleaseRequest(
                    tagName: tagName,
                    targetCommitish: createTagAtCommit,
                    title: title.isEmpty ? nil : title,
                    notes: notes.isEmpty ? nil : notes
                )
                release = try await releaseClient.createRelease(
                    provider: provider, token: token, owner: owner, repo: repo, request: request
                )
                createdRelease = release
                if let commit = createTagAtCommit {
                    let message = title.isEmpty ? tagName : title
                    _ = try? await TagOps(runner: runner).createAnnotatedTag(
                        name: tagName, message: message, at: commit
                    )
                }
            }
            await uploadAssets(for: release)
        } catch {
            state = .failure(.init(from: error))
        }
    }

    /// Upload the assets not yet uploaded; partial-success on any failure.
    private func uploadAssets(for release: Release) async {
        let done = Set(uploadedAssets.map(\.name))
        let pending = assetURLs.filter { !done.contains($0.lastPathComponent) }
        var uploaded = uploadedAssets
        for (index, fileURL) in pending.enumerated() {
            // Per-asset progress — fine-grained byte progress needs a
            // streaming HTTP client (deferred with resumable uploads).
            state = .busy(progress: Double(index) / Double(pending.count))
            do {
                let asset = try await releaseClient.uploadAsset(
                    provider: provider, token: token, release: release, fileURL: fileURL
                )
                uploaded.append(asset)
                uploadedAssets = uploaded
            } catch {
                uploadedAssets = uploaded
                state = .failure(.init(description: TaskWindowVocabulary.releasePartialAssets(
                    uploaded: uploaded.count, total: assetURLs.count, url: release.htmlURL
                )))
                return
            }
        }
        uploadedAssets = uploaded
        state = .success(release)
    }

    /// Reset to idle and clear the consent summary + any retained release
    /// (a fresh start — not the resume path, which re-runs `publish()`).
    public func reset() {
        summary = nil
        createdRelease = nil
        uploadedAssets = []
        state = .idle
    }
}
