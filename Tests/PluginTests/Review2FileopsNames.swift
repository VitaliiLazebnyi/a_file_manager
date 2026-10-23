import Foundation
import Testing

@testable import FileOperationsPlugin

/// Name templates as the fuzzer and the review found them: huge ranges, empty parts, dates, the clipboard.
@Suite
internal struct Review2FileopsNames {
    // F014, F015, F016: reproducers of the fuzzer, as typed text.
    /// Ranges near the ends of Int in a name template neither crash nor lose their meaning, and the fuzzer's finds
    /// give names or an error.
    @Test
    internal func rangesNearTheEndsOfIntDoNotCrash() throws {
        var context = NameTemplate.Context()
        context.cursorName = "report.txt"
        #expect(
            try NameTemplate.names(from: "<[N1,-9223372036854775808]", context: context) == [
                "[N1,-9223372036854775808]"
            ]
        )
        // A number of nineteen digits is no position; the bracket stays as typed.
        #expect(
            try NameTemplate.names(from: "<x[N9223372036854775807--9223372036854775807]", context: context)
                == ["x[N9223372036854775807--9223372036854775807]"]
        )
        #expect(
            try NameTemplate.names(from: "<x[N1,9223372036854775807]", context: context) == [
                "x[N1,9223372036854775807]"
            ]
        )
        // Large numbers that are positions are cut to the length of the name.
        #expect(try NameTemplate.names(from: "<x[N999999999999999999--999999999999999999]", context: context) == ["x"])
        #expect(try NameTemplate.names(from: "<x[N1,999999999999999999]", context: context) == ["xreport"])
        #expect(try NameTemplate.names(from: "<x[N-999999999999999999-]", context: context) == ["xreport"])
        #expect(
            try NameTemplate.names(from: "<x[N99999999999999999999]", context: context) == ["x[N99999999999999999999]"]
        )
        #expect(try NameTemplate.names(from: "<x[C:-9223372036854775808]", context: context) == ["x"])
        #expect(try NameTemplate.names(from: "<1-2>x[C:-9223372036854775808]", context: context) == ["x1", "x2"])
        // The ranges that are meant still work.
        #expect(
            try NameTemplate.names(from: "<[N2-4]|[N2,3]|[N-3-]|[N05-9]", context: context) == [
                "epo", "epo", "ort", "000rt"
            ]
        )
        for name in [
            "nametemplate-slice-overflow.bin", "nametemplate-slice-length-overflow.bin", "nametemplate-empty-name.bin"
        ] {
            let file = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fuzz/repro/diff/\(name)")
            guard let data = try? Data(contentsOf: file) else { continue }
            // The reproducers are UTF-8 text; whatever it says, typed as a name it gives names or an error.
            let typed = try #require(String(bytes: data, encoding: .utf8))
            let names = try? NameTemplate.names(from: "<" + typed, context: context)
            #expect(names?.contains("") != true)
        }
    }

    // F035, F075
    /// A part of a name template that comes to nothing names nothing.
    @Test
    internal func aMaskThatComesToNothingNamesNothing() throws {
        let context = NameTemplate.Context()
        #expect(try NameTemplate.names(from: "<[T2+1D]", context: context).isEmpty)
        #expect(try NameTemplate.names(from: "<[T2+1D] | real", context: context) == ["real"])
        #expect(try NameTemplate.names(from: "<1-3>[T1]", context: context).isEmpty)
    }

    // F035, F074
    /// Twenty thousand names with dates come from one text, the dates without slashes or colons.
    @Test
    internal func theDateFormattersAreMadeOncePerText() throws {
        var context = NameTemplate.Context()
        context.now = Date(timeIntervalSince1970: 1_700_000_000)
        let names = try NameTemplate.names(from: "<0-19999>[C] [d] [t]", context: context)
        #expect(names.count == 20_000 && Set(names).count == 20_000)
        let one = try NameTemplate.names(from: "<[d] [t]", context: context)
        #expect(names[7] == "00007 " + one[0] && !one[0].contains("/") && !one[0].contains(":"))
    }

    // F059
    /// The clipboard's text in a name loses its separators and line breaks, and an empty clipboard is an error.
    @Test
    internal func theClipboardCannotBringPathsIntoAName() throws {
        var context = NameTemplate.Context()
        context.clipboard = "../../etc/passwd\nsecond line"
        #expect(try NameTemplate.names(from: "<[X]", context: context) == [".._.._etc_passwd"])
        context.clipboard = ".."
        #expect(try NameTemplate.names(from: "<[X]", context: context) == ["__"])
        context.clipboard = "~/secret"
        #expect(try NameTemplate.names(from: "<new [X]", context: context) == ["new __secret"])
        context.clipboard = "a:b*c\tend"
        #expect(try NameTemplate.names(from: "<[X]", context: context) == ["a_b_c_end"])
        context.clipboard = ""
        #expect(throws: NameTemplate.Failure.emptyClipboard) {
            _ = try NameTemplate.names(from: "<[X]", context: context)
        }
    }
}
