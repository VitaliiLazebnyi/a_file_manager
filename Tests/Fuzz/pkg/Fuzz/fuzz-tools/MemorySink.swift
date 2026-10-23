import FuzzCore

@testable import FileToolsPlugin

/// A decode sink that only counts: the files begun, their names and how many bytes each got.
internal final class MemorySink: DecodeSink {
    /// The files begun: the name the text gave and the bytes written.
    internal var files: [(name: String?, bytes: Int)] = []

    /// Whether a file is open.
    internal var open = false

    /// Begins a file; checks that the name made safe is one path component.
    ///
    /// - Parameter name: The name the text gives.
    internal func begin(name: String?) {
        fzCheck(!open, "decode-begin-while-open", "")
        open = true
        files.append((name, 0))
        if let safe = Decoder.safeName(name, replacingColon: true) {
            // By bytes: a `/` that carries a combining mark is still a separator to the file system.
            let raw = Array(safe.utf8)
            fzCheck(
                !raw.contains(0x2F) && raw != [0x2E] && raw != [0x2E, 0x2E] && !raw.isEmpty && !raw.contains(0)
                    && raw.count <= 255,
                "decode-unsafe-name",
                "\(String(describing: name).debugDescription) -> \(safe.debugDescription)"
            )
        }
    }

    /// Counts bytes of the open file.
    ///
    /// - Parameter bytes: The bytes.
    internal func write(_ bytes: [UInt8]) {
        fzCheck(open, "decode-write-without-file", "")
        files[files.count - 1].bytes += bytes.count
    }

    /// Ends the open file.
    internal func end() {
        fzCheck(open, "decode-end-without-file", "")
        open = false
    }

    deinit {
        // Nothing to release.
    }
}
