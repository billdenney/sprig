// ForgeDeviceFlow.swift
//
// ADR 0081 — forge sign-in via the OAuth device authorization grant
// (RFC 8628): no localhost redirect server, no embedded browser, and
// it works from a CLI or a Finder-launched task window alike. The
// user gets a short code and a URL; Sprig polls until they approve.
//
// CLIENT IDS ARE INJECTED, like tokens (ADR 0078): registering OAuth
// apps is a distribution concern, and self-hosted forges need their
// own registration anyway. The resulting access token is handed to
// the caller — storage is CredentialKit (ADR 0080), never here.
//
// Provider matrix: GitHub and GitLab implement the device grant.
// Bitbucket Cloud has no device grant, and Gitea's support is too
// version-dependent to rely on — both are typed
// ``DeviceFlowError/unsupportedProvider(_:)`` so callers can word
// the personal-access-token alternative (`sprigctl credential
// --set`).
//
// Tier 1 portable. The HTTP seam and the SLEEP are injectable, so
// the polling loop — intervals, slow_down backoff, expiry budget —
// is pinned deterministically without wall-clock time.

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What ``ForgeDeviceFlow/begin(provider:clientID:baseURL:)`` hands
/// the UI: show ``userCode`` + ``verificationURI`` to the user, keep
/// the rest for ``ForgeDeviceFlow/awaitToken(provider:clientID:authorization:baseURL:)``.
public struct DeviceAuthorization: Sendable, Equatable {
    /// The short code the user types at the verification page.
    public let userCode: String
    /// Where the user goes to type it.
    public let verificationURI: String
    /// Pre-filled variant some forges offer (QR codes, "open
    /// browser" buttons); nil when the forge doesn't send one.
    public let verificationURIComplete: String?
    /// Opaque polling handle.
    public let deviceCode: String
    /// Server-requested polling interval (RFC 8628 default 5 s when
    /// the forge omits it).
    public let interval: Duration
    /// How long the codes stay valid; polling past this is
    /// ``DeviceFlowError/expired``.
    public let expiresIn: Duration

    public init(
        userCode: String,
        verificationURI: String,
        verificationURIComplete: String?,
        deviceCode: String,
        interval: Duration,
        expiresIn: Duration
    ) {
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.deviceCode = deviceCode
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

/// Typed failures the UI can word.
public enum DeviceFlowError: Error, Equatable, Sendable {
    /// The user declined the authorization.
    case accessDenied
    /// The device code expired before the user approved (or the
    /// polling budget ran out).
    case expired
    /// This forge has no usable device grant — offer the
    /// personal-access-token path instead.
    case unsupportedProvider(ForgeProvider)
    /// Non-2xx without an RFC 8628 error body.
    case httpStatus(Int)
    /// The body didn't parse as the documented shape.
    case malformedResponse(detail: String)
}

/// RFC 8628 device authorization against a forge.
public struct ForgeDeviceFlow: Sendable {
    private let client: any ForgeHTTPClient
    private let sleeper: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - client: HTTP seam (tests inject the canned fake).
    ///   - sleeper: how to wait between polls — tests inject a
    ///     recorder; production sleeps for real.
    public init(
        client: any ForgeHTTPClient = URLSessionForgeHTTPClient(),
        sleeper: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.client = client
        self.sleeper = sleeper
    }

    /// Step 1: request the device + user codes.
    ///
    /// - Parameters:
    ///   - clientID: the registered OAuth app's client id. Injected —
    ///     never baked into the engine.
    ///   - baseURL: the forge's WEB base (`https://github.com`, a
    ///     GitHub Enterprise host, a self-managed GitLab) — note this
    ///     is not the API base the repo listing uses.
    public func begin(
        provider: ForgeProvider,
        clientID: String,
        baseURL: URL? = nil
    ) async throws -> DeviceAuthorization {
        let endpoints = try Self.endpoints(provider: provider, baseURL: baseURL)
        let (data, response) = try await postForm(
            url: endpoints.authorize,
            fields: [("client_id", clientID), ("scope", endpoints.scope)]
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            throw DeviceFlowError.httpStatus(response.statusCode)
        }
        let wire = try Self.decode(DeviceCodeResponse.self, from: data)
        return DeviceAuthorization(
            userCode: wire.userCode,
            verificationURI: wire.verificationUri,
            verificationURIComplete: wire.verificationUriComplete,
            deviceCode: wire.deviceCode,
            interval: .seconds(wire.interval ?? 5),
            expiresIn: .seconds(wire.expiresIn)
        )
    }

    /// Step 2: poll until the user approves. Honors the server's
    /// interval, backs off +5 s on `slow_down` (RFC 8628 §3.5), and
    /// gives up with ``DeviceFlowError/expired`` once the total wait
    /// would exceed the authorization's `expiresIn`.
    public func awaitToken(
        provider: ForgeProvider,
        clientID: String,
        authorization: DeviceAuthorization,
        baseURL: URL? = nil
    ) async throws -> String {
        let endpoints = try Self.endpoints(provider: provider, baseURL: baseURL)
        var interval = authorization.interval
        var slept = Duration.zero

        while true {
            guard slept + interval <= authorization.expiresIn else {
                throw DeviceFlowError.expired
            }
            try await sleeper(interval)
            slept += interval

            let (data, response) = try await postForm(
                url: endpoints.token,
                fields: [
                    ("client_id", clientID),
                    ("device_code", authorization.deviceCode),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
                ]
            )
            // RFC 8628 mid-flow "errors" arrive as 400s on GitLab and
            // as 200s on GitHub — classify by BODY first; the status
            // only matters when there's no parseable error field.
            let wire = try? Self.decode(TokenPollResponse.self, from: data)
            if let token = wire?.accessToken {
                return token
            }
            switch wire?.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += .seconds(5)
            case "access_denied":
                throw DeviceFlowError.accessDenied
            case "expired_token":
                throw DeviceFlowError.expired
            case let .some(other):
                throw DeviceFlowError.malformedResponse(
                    detail: wire?.errorDescription ?? other
                )
            case nil:
                guard (200 ..< 300).contains(response.statusCode) else {
                    throw DeviceFlowError.httpStatus(response.statusCode)
                }
                throw DeviceFlowError.malformedResponse(
                    detail: "token poll response had neither access_token nor error"
                )
            }
        }
    }

    // MARK: - Wire plumbing

    private func postForm(
        url: URL,
        fields: [(String, String)]
    ) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return try await client.send(request)
    }

    private static func endpoints(
        provider: ForgeProvider,
        baseURL: URL?
    ) throws -> ProviderEndpoints {
        switch provider {
        case .github:
            let base = baseURL ?? URL(string: "https://github.com")!
            return ProviderEndpoints(
                authorize: base.appendingPathComponent("login")
                    .appendingPathComponent("device")
                    .appendingPathComponent("code"),
                token: base.appendingPathComponent("login")
                    .appendingPathComponent("oauth")
                    .appendingPathComponent("access_token"),
                scope: "repo"
            )
        case .gitlab:
            let base = baseURL ?? URL(string: "https://gitlab.com")!
            return ProviderEndpoints(
                authorize: base.appendingPathComponent("oauth")
                    .appendingPathComponent("authorize_device"),
                token: base.appendingPathComponent("oauth")
                    .appendingPathComponent("token"),
                scope: "read_api"
            )
        case .bitbucket, .gitea:
            throw DeviceFlowError.unsupportedProvider(provider)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DeviceFlowError.malformedResponse(detail: String(describing: error))
        }
    }
}

/// Where a provider's device-flow endpoints live and what scope to
/// request.
private struct ProviderEndpoints {
    let authorize: URL
    let token: URL
    let scope: String
}

/// RFC 8628 §3.2 device authorization response (GitHub and GitLab
/// both use the standard field names).
private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let expiresIn: Int
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case verificationUriComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// Token-endpoint poll response: either `access_token` or an
/// RFC 8628 §3.5 error code.
private struct TokenPollResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}
