// ForgeDeviceFlowTests.swift
//
// ADR 0081 — RFC 8628 device flow against the canned-response fake,
// with an injected sleep recorder so the polling loop's timing
// contract (interval honored, slow_down +5 s, expiresIn budget) is
// pinned deterministically, no wall clock anywhere.

@testable import ForgeKit
import Foundation
import Testing
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Records requested sleep durations instead of sleeping.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var sleeps: [Duration] {
        sync { recorded }
    }

    func sleeper() -> @Sendable (Duration) async throws -> Void {
        { [self] duration in record(duration) }
    }

    private func record(_ duration: Duration) {
        sync { recorded.append(duration) }
    }

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@Suite("ForgeDeviceFlow — RFC 8628 device grant")
struct ForgeDeviceFlowTests {
    private func authorization(
        interval: Int = 5,
        expiresIn: Int = 900
    ) -> DeviceAuthorization {
        DeviceAuthorization(
            userCode: "WXYZ-1234",
            verificationURI: "https://github.com/login/device",
            verificationURIComplete: nil,
            deviceCode: "dev123",
            interval: .seconds(interval),
            expiresIn: .seconds(expiresIn)
        )
    }

    private func pending(status: Int = 200) -> FakeForgeHTTPClient.Canned {
        .init(status: status, body: Data(#"{"error": "authorization_pending"}"#.utf8))
    }

    private var success: FakeForgeHTTPClient.Canned {
        .init(body: Data(#"{"access_token": "gho_tok", "token_type": "bearer"}"#.utf8))
    }

    @Test("begin: GitHub request shape and the decoded authorization")
    func beginGitHub() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: Data("""
        {
          "device_code": "dev123",
          "user_code": "WXYZ-1234",
          "verification_uri": "https://github.com/login/device",
          "expires_in": 899,
          "interval": 7
        }
        """.utf8))

        let auth = try await ForgeDeviceFlow(client: fake)
            .begin(provider: .github, clientID: "Iv1.abc")

        let request = try #require(fake.lastRequest)
        #expect(request.url?.absoluteString == "https://github.com/login/device/code")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "application/x-www-form-urlencoded"
        )
        let body = try String(data: #require(request.httpBody), encoding: .utf8) ?? ""
        #expect(body.contains("client_id=Iv1.abc"))
        #expect(body.contains("scope=repo"))
        #expect(auth.userCode == "WXYZ-1234")
        #expect(auth.deviceCode == "dev123")
        #expect(auth.interval == .seconds(7))
        #expect(auth.expiresIn == .seconds(899))
        #expect(auth.verificationURIComplete == nil)
    }

    @Test("begin: GitLab self-hosted endpoint, read_api scope, RFC default interval when omitted")
    func beginGitLabSelfHosted() async throws {
        let fake = FakeForgeHTTPClient(status: 200, body: Data("""
        {
          "device_code": "d",
          "user_code": "u",
          "verification_uri": "https://git.example.org/oauth/device",
          "verification_uri_complete": "https://git.example.org/oauth/device?user_code=u",
          "expires_in": 300
        }
        """.utf8))

        let auth = try await ForgeDeviceFlow(client: fake).begin(
            provider: .gitlab,
            clientID: "appid",
            baseURL: #require(URL(string: "https://git.example.org"))
        )

        let request = try #require(fake.lastRequest)
        #expect(request.url?.absoluteString == "https://git.example.org/oauth/authorize_device")
        let body = try String(data: #require(request.httpBody), encoding: .utf8) ?? ""
        #expect(body.contains("scope=read_api"))
        #expect(auth.interval == .seconds(5), "RFC 8628 default when the forge omits interval")
        #expect(auth.verificationURIComplete == "https://git.example.org/oauth/device?user_code=u")
    }

    @Test("awaitToken: sleeps the interval before every poll, returns the token")
    func awaitTokenHappyPath() async throws {
        let fake = FakeForgeHTTPClient(responses: [pending(), success])
        let recorder = SleepRecorder()

        let token = try await ForgeDeviceFlow(client: fake, sleeper: recorder.sleeper())
            .awaitToken(provider: .github, clientID: "c", authorization: authorization())

        #expect(token == "gho_tok")
        #expect(recorder.sleeps == [.seconds(5), .seconds(5)])
        let body = try String(
            data: #require(fake.lastRequest?.httpBody),
            encoding: .utf8
        ) ?? ""
        #expect(body.contains("device_code=dev123"))
        #expect(body.contains("grant_type=urn"))
    }

    @Test("awaitToken: slow_down backs the interval off by 5 s (RFC 8628 §3.5)")
    func slowDownBacksOff() async throws {
        let slowDown = FakeForgeHTTPClient.Canned(
            status: 200,
            body: Data(#"{"error": "slow_down"}"#.utf8)
        )
        let fake = FakeForgeHTTPClient(responses: [slowDown, pending(), success])
        let recorder = SleepRecorder()

        let token = try await ForgeDeviceFlow(client: fake, sleeper: recorder.sleeper())
            .awaitToken(provider: .github, clientID: "c", authorization: authorization())

        #expect(token == "gho_tok")
        #expect(recorder.sleeps == [.seconds(5), .seconds(10), .seconds(10)])
    }

    @Test("awaitToken: GitLab's 400-with-authorization_pending is normal flow, not a failure")
    func gitlab400PendingIsNormalFlow() async throws {
        let fake = FakeForgeHTTPClient(responses: [pending(status: 400), success])

        let token = try await ForgeDeviceFlow(
            client: fake,
            sleeper: SleepRecorder().sleeper()
        )
        .awaitToken(provider: .gitlab, clientID: "c", authorization: authorization())

        #expect(token == "gho_tok")
    }

    @Test("awaitToken: access_denied and expired_token are their typed errors")
    func deniedAndExpired() async throws {
        let denied = FakeForgeHTTPClient(
            status: 200,
            body: Data(#"{"error": "access_denied"}"#.utf8)
        )
        await #expect(throws: DeviceFlowError.accessDenied) {
            _ = try await ForgeDeviceFlow(client: denied, sleeper: SleepRecorder().sleeper())
                .awaitToken(provider: .github, clientID: "c", authorization: authorization())
        }

        let expired = FakeForgeHTTPClient(
            status: 200,
            body: Data(#"{"error": "expired_token"}"#.utf8)
        )
        await #expect(throws: DeviceFlowError.expired) {
            _ = try await ForgeDeviceFlow(client: expired, sleeper: SleepRecorder().sleeper())
                .awaitToken(provider: .github, clientID: "c", authorization: authorization())
        }
    }

    @Test("awaitToken: gives up with .expired once total sleep would exceed expiresIn")
    func expiryBudget() async throws {
        let alwaysPending = FakeForgeHTTPClient(responses: [pending()])
        let recorder = SleepRecorder()

        await #expect(throws: DeviceFlowError.expired) {
            _ = try await ForgeDeviceFlow(client: alwaysPending, sleeper: recorder.sleeper())
                .awaitToken(
                    provider: .github,
                    clientID: "c",
                    authorization: authorization(interval: 5, expiresIn: 12)
                )
        }
        // 5 + 5 = 10 fits inside 12; a third poll would need 15 — stop.
        #expect(recorder.sleeps == [.seconds(5), .seconds(5)])
    }

    @Test("Bitbucket and Gitea have no device grant — typed unsupportedProvider")
    func unsupportedProviders() async throws {
        let flow = ForgeDeviceFlow(client: FakeForgeHTTPClient(status: 200, body: Data()))
        await #expect(throws: DeviceFlowError.unsupportedProvider(.bitbucket)) {
            _ = try await flow.begin(provider: .bitbucket, clientID: "c")
        }
        await #expect(throws: DeviceFlowError.unsupportedProvider(.gitea)) {
            _ = try await flow.begin(provider: .gitea, clientID: "c")
        }
    }
}
