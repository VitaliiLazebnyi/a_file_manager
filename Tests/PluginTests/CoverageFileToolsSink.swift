@testable import FileToolsPlugin

/// Collects what a decode machine hands over: the files it began, with their bytes.
internal final class CoverageFileToolsSink: DecodeSink {
    /// The files begun, in order: the name the text gave, and the bytes written so far.
    internal private(set) var files: [(name: String?, bytes: [UInt8])] = []
    /// How many files were ended.
    internal private(set) var ended = 0

    /// A sink that has been given nothing.
    internal init() {
        // Nothing yet.
    }

    /// Begins a file.
    internal func begin(name: String?) {
        files.append((name, []))
    }

    /// Adds bytes to the file begun last.
    internal func write(_ bytes: [UInt8]) {
        files[files.count - 1].bytes += bytes
    }

    /// Ends the file begun last.
    internal func end() {
        ended += 1
    }

    deinit {
        // Nothing to release.
    }
}
