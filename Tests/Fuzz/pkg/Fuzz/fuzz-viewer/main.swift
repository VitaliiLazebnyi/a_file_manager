import Foundation
import FuzzCore

@testable import ViewerPlugin

// Target group 6: the viewer's model. Every random choice comes out of the input bytes.

/// The encodings the targets choose from: the Unicode ones, the system's, and some code pages.
internal let kEncodings: [ViewerEncoding] =
    [.utf8, .utf16LE, .utf16BE, .ansi, .dos, .latin1, .macRoman]
    + [932, 936, 949, 950, 1_251, 874].compactMap(ViewerEncoding.codePage)

/// The encodings among them that use two bytes for some characters.
internal let kDoubleByte = kEncodings.filter { $0.kind == .doubleByte }

/// The first 200 bytes in hex, for the detail of a finding.
internal func describe(_ bytes: [UInt8]) -> String {
    bytes.prefix(200).map { String(format: "%02x", $0) }.joined(separator: " ")
}

/// A size from the input: mostly small (so borders fall everywhere), sometimes larger; at least 1.
internal func size(_ choices: inout Choices) -> Int {
    let value = Int(choices.byte())
    let scaled = value < 200 ? value : (value - 199) * 37
    return max(1, scaled)
}

// `fuzz-viewer scale FILE`: the time of plainText for the input repeated 1, 2, 4, 8, 16 times.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "scale" {
    HTMLTarget.scale(path: CommandLine.arguments[2])
    exit(0)
}

fuzzMain([
    DetectTarget.make(), RowsTarget.make(), BoundariesTarget.make(), SearchTarget.make(), HTMLTarget.make()
])
