import FuzzCore

@testable import ViewerPlugin

/// The `search` target: the raw search against the decoded one, chunked against in one piece.
internal enum SearchTarget {
    /// The target.
    @MainActor
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "search",
            maxLen: 4_096,
            dict: [
                "foo", "bar", "\\n", "\\t", "\\\\", "\"PK\"0102", "0D 0A", "ß", "ſ", "İ", "ı", "K", "é", "É",
                "e\u{301}",
                "ǅ", "σς", "\n", "\r\n", " ", "日本", "あ"
            ],
            rawDict: [[0], [0x82, 0xA0], [0x81, 0x40], [0xE2, 0x84, 0xAA], [0xC5, 0xBF], [0xFF], [0xC3]],
            seeds: seeds,
            run: run
        )
    }

    /// The inputs the fuzzer starts from: the choices of `SearchInput`, the pattern, a 0, then the text.
    internal static func seeds() -> [[UInt8]] {
        func seed(_ head: [UInt8], _ pattern: String, _ text: String) -> [UInt8] {
            head + Array(pattern.utf8) + [0] + Array(text.utf8)
        }
        return [
            seed([0, 0, 7, 0, 2, 0], "bar", "foo bar FOO BAR foobar\nbar"),
            seed([0, 1, 5, 30, 1, 0], "Bar", "foo bar FOO BAR foobar\nbar Bar"),
            seed([0, 16, 9, 0, 3, 0], "b", "foo bar FOO BAR foobar\nbar"),
            seed([0, 8, 4, 0, 1, 0], "\"PK\"0102", "xxPK\u{1}\u{2}yy"),
            seed([3, 2, 6, 0, 2, 0], "über", "Über die Brücke über"), seed([7, 0, 3, 0, 2, 0], "界", "你好世界你好"),
            seed([0, 0, 11, 0, 2, 0], "a\\nb", "xa\r\nb a\nb"),
            seed([0, 4, 8, 99, 2, 0], "ss", "Straße STRASSE ſs KELVIN K")
        ]
    }

    /// Runs one input.
    @MainActor
    internal static func run(_ bytes: [UInt8]) {
        guard let input = SearchInput(bytes) else {
            return
        }
        let what = input.what
        guard let raw = input.find(input.chunk, raw: true, shared: input.shared, from: input.start),
            let decoded = input.find(input.chunk, raw: false, shared: nil, from: input.start)
        else {
            fzFail("search-threw", what)
        }
        if raw != decoded {
            fzFail(
                "search-raw-differs-from-decoded",
                "\(what): raw \(String(describing: raw)), decoded \(String(describing: decoded))\n"
                    + describe(input.data)
            )
        }
        if let match = raw {
            checkSide(match, input)
        }
        // Plain text and bytes: the chunk size changes nothing.
        switch input.pattern.kind {
        case .expression:
            break

        case .text, .bytes:
            checkWhole(decoded, input)
        }
        // Find next from the match, as F3 does.
        if let match = raw, match.upperBound > match.lowerBound {
            checkNext(match, input)
        }
    }

    /// The match is inside the content and on the right side of the start.
    @MainActor
    private static func checkSide(_ match: Range<Int64>, _ input: SearchInput) {
        let content = input.content
        fzCheck(
            match.lowerBound >= content.lowerBound && match.upperBound <= content.upperBound
                && match.lowerBound <= match.upperBound,
            "search-match-outside-content",
            "\(input.what): \(match)"
        )
        let from = min(max(input.start, content.lowerBound), content.upperBound)
        // A backwards search never returns the match that begins at `start` (Find Previous would repeat it),
        // also when the match is shorter in the text than the needle (ß for "ss"). The tolerance the first
        // campaign needed for that finding is gone.
        fzCheck(
            input.options.backwards ? match.lowerBound < from : match.lowerBound >= from,
            "search-match-wrong-side",
            "\(input.what): \(match)\n\(describe(input.data))"
        )
    }

    /// The search in one piece finds what the chunked one found.
    @MainActor
    private static func checkWhole(_ decoded: Range<Int64>?, _ input: SearchInput) {
        guard let whole = input.find(1 << 20, raw: false, shared: nil, from: input.start) else {
            fzFail("search-threw", input.what)
        }
        if whole != decoded {
            fzFail(
                "search-chunked-differs-from-whole",
                "\(input.what): chunked \(String(describing: decoded)), in one piece \(String(describing: whole))\n"
                    + describe(input.data)
            )
        }
    }

    /// Searching again from the match, raw and decoded agree.
    @MainActor
    private static func checkNext(_ match: Range<Int64>, _ input: SearchInput) {
        let next = input.options.backwards ? match.lowerBound : match.lowerBound + 1
        guard let raw = input.find(input.chunk, raw: true, shared: input.shared, from: next),
            let decoded = input.find(input.chunk, raw: false, shared: nil, from: next)
        else {
            fzFail("search-threw", input.what)
        }
        if raw != decoded {
            fzFail(
                "search-raw-differs-from-decoded",
                "\(input.what) (next from \(next)): raw \(String(describing: raw)), "
                    + "decoded \(String(describing: decoded))\n\(describe(input.data))"
            )
        }
    }
}
