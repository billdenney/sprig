// ContentTypeTests.swift
//
// ADR 0086 C0 — magic-number content sniffing. Pure unit tests over
// hand-crafted header bytes (no git).

import Foundation
@testable import GitCore
import Testing

@Suite("ContentTypeSniffer — magic-number detection")
struct ContentTypeTests {
    @Test("recognizes image + document magic numbers")
    func magicNumbers() {
        #expect(ContentTypeSniffer.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .png)
        #expect(ContentTypeSniffer.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(ContentTypeSniffer.sniff(Data("GIF89a……".utf8)) == .gif)
        #expect(ContentTypeSniffer.sniff(Data("GIF87a".utf8)) == .gif)
        #expect(ContentTypeSniffer.sniff(Data("%PDF-1.7\n".utf8)) == .pdf)
        #expect(ContentTypeSniffer.sniff(Data([0x50, 0x4B, 0x03, 0x04])) == .zipContainer)
        var webp = Data("RIFF".utf8)
        webp.append(contentsOf: [0x10, 0x00, 0x00, 0x00])
        webp.append(contentsOf: Array("WEBP".utf8))
        #expect(ContentTypeSniffer.sniff(webp) == .webp)
    }

    @Test("falls back to a NUL-byte text/binary heuristic")
    func textVsBinary() {
        #expect(ContentTypeSniffer.sniff(Data("hello\nworld\n".utf8)) == .plainText)
        #expect(ContentTypeSniffer.sniff(Data([0x01, 0x00, 0x02])) == .unknownBinary)
        #expect(ContentTypeSniffer.sniff(Data()) == .plainText)
    }

    @Test("isBinary reflects the type")
    func isBinaryFlag() {
        #expect(ContentType.png.isBinary)
        #expect(ContentType.pdf.isBinary)
        #expect(ContentType.zipContainer.isBinary)
        #expect(!ContentType.plainText.isBinary)
        #expect(ContentType.unknownBinary.isBinary)
    }
}
