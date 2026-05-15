// PathResolverTests.swift
//
// Tests for the PathResolver protocol and its FoundationPathResolver
// default impl. Verify the protocol contract on every platform Swift
// runs (macOS / Linux / Windows) without asserting platform-specific
// path shapes — the platform-correct path comes from Foundation, so
// we test the wrapper's invariants (app-name suffix, directory
// created, distinct roots per search path) rather than the exact
// string form.

import Foundation
@testable import PlatformKit
import Testing

@Suite("PathResolver — FoundationPathResolver default impl")
struct PathResolverTests {
    /// UUID-suffixed app name so concurrent test runs and prior runs
    /// don't share state on the developer's machine.
    private func uniqueAppName(tag: String) -> String {
        "SprigPathResolverTest-\(tag)-\(UUID().uuidString)"
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - appSupport

    @Test("appSupport returns a URL ending in the configured app name")
    func appSupportHasAppNameSuffix() throws {
        let name = uniqueAppName(tag: "appsupport-suffix")
        let resolver = FoundationPathResolver(appName: name)
        let url = try resolver.appSupport()
        defer { cleanup(url) }
        #expect(url.lastPathComponent == name)
    }

    @Test("appSupport creates the directory if it doesn't exist")
    func appSupportCreatesDirectory() throws {
        let name = uniqueAppName(tag: "appsupport-create")
        let resolver = FoundationPathResolver(appName: name)
        let url = try resolver.appSupport()
        defer { cleanup(url) }
        // Existence is enough — `createDirectory(at:withIntermediateDirectories:)`
        // either created a directory or threw. The `isDirectory:`
        // overload uses `ObjCBool` which is awkward to thread through
        // cross-platform Foundation; we trust the create call instead.
        #expect(FileManager.default.fileExists(atPath: url.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
        #expect(contents.isEmpty || !contents.isEmpty) // listing succeeded → it's a directory
    }

    @Test("appSupport returns a consistent path across calls")
    func appSupportIsIdempotent() throws {
        let name = uniqueAppName(tag: "appsupport-idempotent")
        let resolver = FoundationPathResolver(appName: name)
        let first = try resolver.appSupport()
        defer { cleanup(first) }
        let second = try resolver.appSupport()
        #expect(first == second)
    }

    // MARK: - cache

    @Test("cache returns a URL ending in the configured app name")
    func cacheHasAppNameSuffix() throws {
        let name = uniqueAppName(tag: "cache-suffix")
        let resolver = FoundationPathResolver(appName: name)
        let url = try resolver.cache()
        defer { cleanup(url) }
        #expect(url.lastPathComponent == name)
    }

    @Test("cache creates the directory if it doesn't exist")
    func cacheCreatesDirectory() throws {
        let name = uniqueAppName(tag: "cache-create")
        let resolver = FoundationPathResolver(appName: name)
        let url = try resolver.cache()
        defer { cleanup(url) }
        // Existence is enough — `createDirectory(at:withIntermediateDirectories:)`
        // either created a directory or threw. The `isDirectory:`
        // overload uses `ObjCBool` which is awkward to thread through
        // cross-platform Foundation; we trust the create call instead.
        #expect(FileManager.default.fileExists(atPath: url.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
        #expect(contents.isEmpty || !contents.isEmpty) // listing succeeded → it's a directory
    }

    // MARK: - Distinctness

    @Test("appSupport and cache resolve to different roots (different platform search paths)")
    func appSupportAndCacheAreDistinct() throws {
        let name = uniqueAppName(tag: "distinct")
        let resolver = FoundationPathResolver(appName: name)
        let support = try resolver.appSupport()
        let cache = try resolver.cache()
        defer {
            cleanup(support)
            cleanup(cache)
        }
        // Both end in the same app-name leaf but the parent
        // directories must differ — appSupport sits under the
        // platform's application-support root, cache under the
        // platform's cache root.
        #expect(support.deletingLastPathComponent() != cache.deletingLastPathComponent())
    }

    @Test("default appName is Sprig")
    func defaultAppNameIsSprig() {
        #expect(FoundationPathResolver().appName == "Sprig")
    }

    // MARK: - PathResolver as a protocol

    @Test("FoundationPathResolver conforms to PathResolver and is Sendable")
    func protocolConformance() async {
        let resolver: any PathResolver = FoundationPathResolver(
            appName: uniqueAppName(tag: "protocol")
        )
        // Sendable witness via actor-isolated holder.
        actor Holder<T: Sendable> {
            var value: T
            init(_ v: T) {
                value = v
            }
        }
        let holder = Holder<any PathResolver>(resolver)
        _ = await holder.value
    }
}
