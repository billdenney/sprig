@testable import AIKit
import Foundation
import Testing

@Suite("OllamaGenerateRequest — wire shape")
struct OllamaGenerateRequestTests {
    @Test("encodes the canonical fields with Ollama's exact keys")
    func canonicalEncoding() throws {
        let request = OllamaGenerateRequest(
            model: "llama3",
            prompt: "explain this",
            system: "you are concise",
            stream: false,
            options: .init(temperature: 0.0, numPredict: 100)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        // Sorted keys → predictable output. Assert on exact field
        // names since they're the wire contract.
        #expect(json.contains("\"model\":\"llama3\""))
        #expect(json.contains("\"prompt\":\"explain this\""))
        #expect(json.contains("\"system\":\"you are concise\""))
        #expect(json.contains("\"stream\":false"))
        #expect(json.contains("\"num_predict\":100"))
        #expect(json.contains("\"temperature\":0"))
    }

    @Test("nil options + nil system are omitted from the encoded JSON")
    func nilFieldsOmitted() throws {
        let request = OllamaGenerateRequest(
            model: "phi3",
            prompt: "x",
            system: nil,
            stream: false,
            options: nil
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"system\""))
        #expect(!json.contains("\"options\""))
    }
}

@Suite("OllamaGenerateResponse — wire shape")
struct OllamaGenerateResponseTests {
    @Test("decodes a typical successful response")
    func typicalResponse() throws {
        let body = """
        {
          "model": "llama3",
          "created_at": "2026-05-09T12:00:00Z",
          "response": "the answer",
          "done": true,
          "done_reason": "stop",
          "prompt_eval_count": 42,
          "eval_count": 7
        }
        """
        let data = try #require(body.data(using: .utf8))
        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        #expect(decoded.response == "the answer")
        #expect(decoded.done == true)
        #expect(decoded.doneReason == "stop")
        #expect(decoded.promptEvalCount == 42)
        #expect(decoded.evalCount == 7)
    }

    @Test("decodes a response missing the optional doneReason field (older Ollama)")
    func responseMissingDoneReason() throws {
        let body = """
        {
          "model": "llama3",
          "response": "ok",
          "done": true,
          "prompt_eval_count": 5,
          "eval_count": 1
        }
        """
        let data = try #require(body.data(using: .utf8))
        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        #expect(decoded.doneReason == nil)
        #expect(decoded.response == "ok")
    }

    @Test("decoder ignores unknown fields (forward-compat)")
    func ignoresUnknownFields() throws {
        let body = """
        {
          "response": "fine",
          "done": true,
          "future_field": "whatever"
        }
        """
        let data = try #require(body.data(using: .utf8))
        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        #expect(decoded.response == "fine")
    }
}
