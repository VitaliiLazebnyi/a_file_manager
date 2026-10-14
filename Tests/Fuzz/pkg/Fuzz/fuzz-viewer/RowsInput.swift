import Foundation
import FuzzCore

@testable import ViewerPlugin

/// What one input of the `rows` target asks for: the encoding, the layout, how the index is built, and the bytes.
internal struct RowsInput {
    /// The encoding of the text.
    internal let encoding: ViewerEncoding
    /// The width of the layout, in columns.
    internal let columns: Int
    /// Whether long lines wrap.
    internal let wrap: Bool
    /// The tab width as chosen (0 is made 1 by the options).
    internal let tab: Int
    /// The segment size of the index.
    internal let segment: Int
    /// The chunk size of the index.
    internal let chunk: Int
    /// Whether the index is built on several threads.
    internal let parallel: Bool
    /// The length of the byte order mark the document is told about.
    internal let bom: Int
    /// How many lookups to try.
    internal let probes: Int
    /// The file's bytes.
    internal let data: [UInt8]
    /// The file.
    internal let source: DataByteSource
    /// The input in words, for the detail of a finding.
    internal let what: String

    /// The layout options.
    internal var options: TextLayoutOptions {
        TextLayoutOptions(columns: columns, wordWrap: wrap, tabWidth: tab)
    }

    /// The options of the second layout, another width, which takes over the first one's index.
    internal var otherOptions: TextLayoutOptions {
        TextLayoutOptions(columns: 1 + (columns * 7) % 500, wordWrap: wrap, tabWidth: tab)
    }

    /// The input read out of `bytes`.
    @MainActor
    internal init(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        encoding = kEncodings[choices.int(kEncodings.count)]
        columns = 1 + Int(choices.u16()) % 500
        wrap = choices.bool()
        tab = Int(choices.byte()) % 20
        segment = size(&choices)
        chunk = size(&choices)
        parallel = choices.bool()
        bom = choices.int(4)
        probes = Int(choices.byte())
        data = choices.rest()
        source = DataByteSource(Data(data))
        what =
            "cp \(encoding.codePage) columns \(columns) wrap \(wrap) tab \(tab) segment \(segment) chunk \(chunk) "
            + "bom \(bom) bytes \(data.count)"
    }
}
