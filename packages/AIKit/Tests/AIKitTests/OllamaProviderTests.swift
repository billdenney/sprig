@testable import AIKit
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - Shared stub + fixture helpers

//
// File-scope so the test struct body stays under SwiftLint's 250-line
// type-body cap. Reused across the request-shape, response-decoding,
// and error-mapping suites below.

/// Captures the URLRequest the provider sent so tests can assert on
/// URL, method, headers, and body. Returns the canned response on
/// every call.
private actor RecordingStubClient: HTTPClient {
    let response: (Data, HTTPURLResponse)
    let throwsOnSend: Error?
    var observed: [URLRequest] = []

    init(
        response: (Data, HTTPURLResponse),
        throwsOnSend: Error? = nil
    ) {
        self.response = response
        self.throwsOnSend = throwsOnSend
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        observed.append(request)
        if let throwsOnSend { throw throwsOnSend }
        return response
    }
}

private func httpResponse(
    statusCode: Int,
    url: URL = URL(string: "http://localhost:11434/api/generate")!
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
}

private func okResponseBody(
    text: String = "the answer",
    doneReason: String? = "stop",
    prompt: Int? = 42,
    eval: Int? = 7
) throws -> Data {
    var json: [String: Any] = [
        "model": "llama3",
        "response": text,
        "done": true
    ]
    if let doneReason {
        json["done_reason"] = doneReason
    }
    if let prompt {
        json["prompt_eval_count"] = prompt
    }
    if let eval {
        json["eval_count"] = eval
    }
    return try JSONSerialization.data(withJSONObject: json)
}

private func payload(of request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    let parsed = try JSONSerialization.jsonObject(with: body)
    return try #require(parsed as? [String: Any])
}

// MARK: - Suites

@Suite("OllamaProvider — request shape")
struct OllamaProviderRequestShapeTests {
    @Test("identifier is the literal string 'ollama'")
    func identifierConstant() {
        let stub = RecordingStubClient(response: (Data(), httpResponse(statusCode: 200)))
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        #expect(provider.identifier == "ollama")
    }

    @Test("complete() sends a POST to /api/generate with the configured model + user prompt")
    func sendsCanonicalPostRequest() async throws {
        let stub = try RecordingStubClient(
            response: (okResponseBody(), httpResponse(statusCode: 200))
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        _ = try await provider.complete(request: AIRequest(userPrompt: "explain"))

        let observed = await stub.observed
        #expect(observed.count == 1)
        let request = try #require(observed.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/generate")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try payload(of: request)
        #expect(body["model"] as? String == "llama3")
        #expect(body["prompt"] as? String == "explain")
        #expect(body["stream"] as? Bool == false)
    }

    @Test("complete() includes system prompt when AIRequest provides one")
    func includesSystemPrompt() async throws {
        let stub = try RecordingStubClient(
            response: (okResponseBody(), httpResponse(statusCode: 200))
        )
        let provider = OllamaProvider(model: "phi3", httpClient: stub)
        _ = try await provider.complete(
            request: AIRequest(systemPrompt: "be terse", userPrompt: "hi")
        )
        let request = try #require(await stub.observed.first)
        let body = try payload(of: request)
        #expect(body["system"] as? String == "be terse")
    }

    @Test("complete() folds maxTokens + temperature into the options block")
    func includesOptionsWhenSet() async throws {
        let stub = try RecordingStubClient(
            response: (okResponseBody(), httpResponse(statusCode: 200))
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        _ = try await provider.complete(
            request: AIRequest(userPrompt: "x", maxTokens: 64, temperature: 0.0)
        )
        let request = try #require(await stub.observed.first)
        let body = try payload(of: request)
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 64)
        // JSONSerialization decodes 0.0 as either Int 0 or Double 0.0
        // depending on the source serialization. Accept both.
        let temperature = options["temperature"]
        #expect(temperature as? Double == 0.0 || temperature as? Int == 0)
    }

    @Test("complete() omits the options block when both maxTokens and temperature are nil")
    func omitsOptionsWhenNil() async throws {
        let stub = try RecordingStubClient(
            response: (okResponseBody(), httpResponse(statusCode: 200))
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
        let request = try #require(await stub.observed.first)
        let body = try payload(of: request)
        #expect(body["options"] == nil)
    }

    @Test("custom endpoint hits the user-supplied host + port")
    func customEndpoint() async throws {
        let stub = try RecordingStubClient(
            response: (okResponseBody(), httpResponse(statusCode: 200))
        )
        let endpoint = try #require(URL(string: "http://10.0.0.5:8080"))
        let provider = OllamaProvider(model: "llama3", endpoint: endpoint, httpClient: stub)
        _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
        let request = try #require(await stub.observed.first)
        #expect(request.url?.host == "10.0.0.5")
        #expect(request.url?.port == 8080)
        #expect(request.url?.path == "/api/generate")
    }
}

@Suite("OllamaProvider — response decoding")
struct OllamaProviderResponseDecodingTests {
    @Test("complete() decodes the response into AIResponse with trimmed text + token counts")
    func decodesSuccessResponse() async throws {
        let stub = try RecordingStubClient(
            response: (
                okResponseBody(text: "  the answer\n\n", doneReason: "stop", prompt: 10, eval: 3),
                httpResponse(statusCode: 200)
            )
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        let response = try await provider.complete(request: AIRequest(userPrompt: "x"))
        #expect(response.text == "the answer")
        #expect(response.finishReason == .stop)
        #expect(response.inputTokens == 10)
        #expect(response.outputTokens == 3)
    }

    @Test("complete() maps Ollama's done_reason 'length' to FinishReason.length")
    func mapsLengthFinishReason() async throws {
        let stub = try RecordingStubClient(
            response: (
                okResponseBody(doneReason: "length"),
                httpResponse(statusCode: 200)
            )
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        let response = try await provider.complete(request: AIRequest(userPrompt: "x"))
        #expect(response.finishReason == .length)
    }

    @Test("complete() maps unknown done_reason to FinishReason.other(raw)")
    func mapsUnknownFinishReason() async throws {
        let stub = try RecordingStubClient(
            response: (
                okResponseBody(doneReason: "load"),
                httpResponse(statusCode: 200)
            )
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        let response = try await provider.complete(request: AIRequest(userPrompt: "x"))
        #expect(response.finishReason == .other("load"))
    }

    @Test("malformed response body maps to AIError.responseDecodingFailed")
    func malformedBodyMapsToDecodingFailed() async {
        let stub = RecordingStubClient(
            response: (
                Data("not json at all".utf8),
                httpResponse(statusCode: 200)
            )
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        do {
            _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
            Issue.record("expected throw")
        } catch let error as AIError {
            switch error {
            case let .responseDecodingFailed(provider, snippet):
                #expect(provider == "ollama")
                #expect(snippet.contains("not json"))
            default:
                Issue.record("expected responseDecodingFailed, got \(error)")
            }
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }
}

@Suite("OllamaProvider — error mapping")
struct OllamaProviderErrorMappingTests {
    @Test("HTTP 404 from Ollama maps to AIError.modelNotAvailable")
    func http404MapsToModelNotAvailable() async {
        let stub = RecordingStubClient(
            response: (
                Data("{\"error\":\"model 'unknown' not found\"}".utf8),
                httpResponse(statusCode: 404)
            )
        )
        let provider = OllamaProvider(model: "unknown", httpClient: stub)
        do {
            _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
            Issue.record("expected throw")
        } catch let error as AIError {
            #expect(error == .modelNotAvailable(provider: "ollama", model: "unknown"))
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }

    @Test("HTTP 429 maps to AIError.rateLimited")
    func http429MapsToRateLimited() async {
        let stub = RecordingStubClient(
            response: (Data(), httpResponse(statusCode: 429))
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        do {
            _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
            Issue.record("expected throw")
        } catch let error as AIError {
            #expect(error == .rateLimited(provider: "ollama", retryAfter: nil))
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }

    @Test("HTTP 5xx maps to AIError.providerUnavailable")
    func http5xxMapsToProviderUnavailable() async {
        let stub = RecordingStubClient(
            response: (Data("{\"error\":\"server boom\"}".utf8), httpResponse(statusCode: 503))
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        do {
            _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
            Issue.record("expected throw")
        } catch let error as AIError {
            switch error {
            case let .providerUnavailable(provider, underlying):
                #expect(provider == "ollama")
                #expect(underlying?.contains("503") == true)
            default:
                Issue.record("expected providerUnavailable, got \(error)")
            }
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }

    @Test("HTTP 4xx (non-404, non-429, non-401/403) maps to AIError.invalidRequest")
    func http400MapsToInvalidRequest() async {
        let stub = RecordingStubClient(
            response: (
                Data("{\"error\":\"bad prompt\"}".utf8),
                httpResponse(statusCode: 400)
            )
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        do {
            _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
            Issue.record("expected throw")
        } catch let error as AIError {
            switch error {
            case let .invalidRequest(provider, _):
                #expect(provider == "ollama")
            default:
                Issue.record("expected invalidRequest, got \(error)")
            }
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }

    @Test("transport-level URLError(.cancelled) maps to AIError.cancelled")
    func cancelledURLErrorMapsToCancelled() async {
        let stub = RecordingStubClient(
            response: (Data(), httpResponse(statusCode: 200)),
            throwsOnSend: URLError(.cancelled)
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        do {
            _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
            Issue.record("expected throw")
        } catch let error as AIError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }

    @Test("CancellationError from the transport maps to AIError.cancelled")
    func cancellationErrorMapsToCancelled() async {
        let stub = RecordingStubClient(
            response: (Data(), httpResponse(statusCode: 200)),
            throwsOnSend: CancellationError()
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        do {
            _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
            Issue.record("expected throw")
        } catch let error as AIError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }

    @Test("other transport-level URLErrors map to AIError.providerUnavailable")
    func otherURLErrorMapsToUnavailable() async {
        let stub = RecordingStubClient(
            response: (Data(), httpResponse(statusCode: 200)),
            throwsOnSend: URLError(.notConnectedToInternet)
        )
        let provider = OllamaProvider(model: "llama3", httpClient: stub)
        do {
            _ = try await provider.complete(request: AIRequest(userPrompt: "x"))
            Issue.record("expected throw")
        } catch let error as AIError {
            switch error {
            case let .providerUnavailable(provider, _):
                #expect(provider == "ollama")
            default:
                Issue.record("expected providerUnavailable, got \(error)")
            }
        } catch {
            Issue.record("expected AIError, got \(error)")
        }
    }
}
