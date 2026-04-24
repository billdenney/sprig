import Foundation

/// A `TextOutputStream` that writes to stderr.
/// Used for warnings that should not appear on stdout (which is reserved for
/// machine-parseable output like `--json`). Callers create a local
/// `var stream = StderrStream()` per call-site — avoids Swift 6 concurrency
/// complaints about mutable globals.
struct StderrStream: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
