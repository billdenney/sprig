@testable import AIKit
import Foundation
import Testing

// On Linux + Windows, `URLRequest` / `URLResponse` / `HTTPURLResponse`
// live in `FoundationNetworking`. Mirror the production code's
// import shape so test fixtures using these types compile.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("HTTPClient")
struct HTTPClientTests {
    /// Custom conformance proving the protocol is implementable
    /// without going through `URLSession`. This is the seam
    /// `OllamaProvider`'s tests use to inject canned responses.
    struct StubHTTPClient: HTTPClient {
        let response: (Data, HTTPURLResponse)

        func send(_: URLRequest) async throws -> (Data, HTTPURLResponse) {
            response
        }
    }

    @Test("a custom HTTPClient can return canned data + HTTPURLResponse")
    func stubReturnsCannedData() async throws {
        let url = try #require(URL(string: "https://example.invalid/x"))
        let httpResponse = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        let body = Data("hello".utf8)
        let stub = StubHTTPClient(response: (body, httpResponse))

        let request = URLRequest(url: url)
        let (data, response) = try await stub.send(request)
        #expect(data == body)
        #expect(response.statusCode == 200)
    }

    @Test("HTTPClientError.nonHTTPResponse is value-equal")
    func errorEquality() {
        #expect(
            HTTPClientError.nonHTTPResponse(scheme: "ftp")
                == HTTPClientError.nonHTTPResponse(scheme: "ftp")
        )
        #expect(
            HTTPClientError.nonHTTPResponse(scheme: "ftp")
                != HTTPClientError.nonHTTPResponse(scheme: "https")
        )
    }
}
