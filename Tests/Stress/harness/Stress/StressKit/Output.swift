internal import Foundation

// What the harnesses print: lines on standard output, padded columns.

/// `text` padded with spaces to `width` characters (left as it is when it is longer).
public func pad(_ text: String, _ width: Int = 46) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// Writes `text` and a line break to standard output at once, unbuffered.
public func say(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}
