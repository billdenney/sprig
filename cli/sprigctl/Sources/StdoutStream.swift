import Foundation

/// A `TextOutputStream` that writes to stdout via
/// `FileHandle.standardOutput`, bypassing Swift's default `print()`
/// path. Mirrors ``StderrStream``.
///
/// Why this exists: Swift's default `print(...)` writes to stdout
/// through a C-runtime FILE * with text-mode semantics on Windows,
/// which translates `"\n"` to `"\r\n"`. That CRLF emission is
/// unconventional for streaming-JSON CLI output (one envelope per
/// line, jq-style); downstream consumers expect LF, and the
/// translation also bit a Windows CI test until slice A9's
/// `enumerateLines`-based fix made the test CRLF-tolerant.
///
/// Writing through `FileHandle.standardOutput.write(Data(...).utf8)`
/// is byte-for-byte: no text-mode translation, LF on every platform.
/// Use this stream for any output that's intended to be
/// machine-readable or that downstream code splits on `"\n"`. Human
/// output is fine on the default `print` path — terminals on every
/// platform render either LF or CRLF identically.
///
/// Callers create a local `var stream = StdoutStream()` per call-site
/// to avoid Swift 6 concurrency complaints about mutable globals.
struct StdoutStream: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardOutput.write(Data(string.utf8))
    }
}
