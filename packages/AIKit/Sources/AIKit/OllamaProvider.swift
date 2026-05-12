// OllamaProvider — local-first AIProvider talking to Ollama's
// HTTP API at `http://localhost:11434` (or a caller-configured
// endpoint).
//
// Tier 1 portable. Pure Foundation + the FoundationNetworking
// shim from `HTTPClient.swift`.
//
// Per ADR 0013, Ollama is one of Sprig's local-first defaults
// (Apple Foundation Models being the other). No BYOK / API keys;
// no per-action cloud confirmation per ADR 0036, since requests
// stay on-device.
//
// First slice: `/api/generate` with `stream: false`. The chat-
// shaped `/api/chat` endpoint and streaming responses are
// follow-ups.

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// `AIProvider` implementation backed by an Ollama daemon.
public struct OllamaProvider: AIProvider {
    public let identifier = "ollama"

    /// Model name as Ollama knows it (`"llama3"`, `"phi3:mini"`,
    /// `"qwen2.5-coder:7b"`, etc.). Sprig doesn't validate this
    /// — Ollama itself returns a clean error for unknown models,
    /// which the provider maps to ``AIError/modelNotAvailable``.
    public let model: String

    /// Base URL of the Ollama daemon. Defaults to the canonical
    /// `http://localhost:11434`; override for non-default ports
    /// or remote daemons.
    public let endpoint: URL

    private let httpClient: HTTPClient

    public static let defaultEndpoint = URL(string: "http://localhost:11434")!

    public init(
        model: String,
        endpoint: URL = OllamaProvider.defaultEndpoint,
        httpClient: HTTPClient = URLSessionHTTPClient()
    ) {
        self.model = model
        self.endpoint = endpoint
        self.httpClient = httpClient
    }

    public func complete(request: AIRequest) async throws -> AIResponse {
        let urlRequest = try makeURLRequest(from: request)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.send(urlRequest)
        } catch is CancellationError {
            throw AIError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw AIError.cancelled
        } catch {
            throw AIError.providerUnavailable(
                provider: identifier,
                underlying: error.localizedDescription
            )
        }

        try classify(httpStatus: response.statusCode, body: data)

        let decoded: OllamaGenerateResponse
        do {
            decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        } catch {
            throw AIError.responseDecodingFailed(
                provider: identifier,
                snippet: snippet(of: data)
            )
        }

        return AIResponse(
            text: decoded.response.trimmingCharacters(in: .whitespacesAndNewlines),
            finishReason: mapFinishReason(decoded.doneReason),
            inputTokens: decoded.promptEvalCount,
            outputTokens: decoded.evalCount
        )
    }

    // MARK: - Helpers

    private func makeURLRequest(from request: AIRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("/api/generate"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let options: OllamaGenerateOptions? = if request.maxTokens != nil || request.temperature != nil {
            .init(temperature: request.temperature, numPredict: request.maxTokens)
        } else {
            nil
        }

        let payload = OllamaGenerateRequest(
            model: model,
            prompt: request.userPrompt,
            system: request.systemPrompt,
            stream: false,
            options: options
        )
        do {
            urlRequest.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw AIError.invalidRequest(
                provider: identifier,
                message: "failed to encode Ollama request body: \(error.localizedDescription)"
            )
        }
        return urlRequest
    }

    /// Classify Ollama's HTTP status code into AIError cases.
    /// Ollama doesn't have a stable error-code vocabulary; we
    /// inspect both the status and the body snippet to disambiguate.
    private func classify(httpStatus: Int, body: Data) throws {
        switch httpStatus {
        case 200:
            return
        case 404:
            // Ollama returns 404 for unknown model — body looks like
            // `{"error":"model 'foo' not found, try pulling it..."}`
            throw AIError.modelNotAvailable(provider: identifier, model: model)
        case 401, 403:
            throw AIError.authenticationFailed(
                provider: identifier,
                message: snippet(of: body)
            )
        case 429:
            throw AIError.rateLimited(provider: identifier, retryAfter: nil)
        case 400 ... 499:
            throw AIError.invalidRequest(
                provider: identifier,
                message: snippet(of: body)
            )
        case 500 ... 599:
            throw AIError.providerUnavailable(
                provider: identifier,
                underlying: "HTTP \(httpStatus): \(snippet(of: body))"
            )
        default:
            throw AIError.providerUnavailable(
                provider: identifier,
                underlying: "unexpected HTTP \(httpStatus)"
            )
        }
    }

    private func mapFinishReason(_ raw: String?) -> FinishReason {
        switch raw {
        case "stop", nil: .stop
        case "length": .length
        case let other?: .other(other)
        }
    }

    /// Truncated body snippet for diagnostic error messages.
    /// Ollama's error bodies are short JSON; truncating is
    /// belt-and-suspenders for cases where a misconfigured proxy
    /// returns an HTML error page.
    private func snippet(of data: Data) -> String {
        let max = 256
        if data.count <= max {
            return String(data: data, encoding: .utf8) ?? "<non-UTF-8 \(data.count) bytes>"
        }
        let head = data.prefix(max)
        let text = String(data: head, encoding: .utf8) ?? "<non-UTF-8 prefix>"
        return text + "…"
    }
}
