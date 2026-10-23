import Testing

@testable import ViewerPlugin

/// HTML as text, made fast without changing what comes out.
@Suite
internal struct ViewerAdoptHTMLTests {
    /// Bits of HTML, good and broken, that the random pages are made of.
    private let pieces: [String] = [
        "text ", "More  words\n", "tab\there ", "\u{A0}", "\u{2003}", "\u{85}", " ", "  \n  ", "\r\n", "x", "é", "日本語 ",
        "😀", "caf\u{E9} ",
        "&amp;", "&lt;", "&gt;", "&quot;", "&apos;", "&nbsp;", "&copy;", "&#65;", "&#x41;", "&#xZZ;", "&#0;",
        "&#xD800;", "&unknown;", "&amp", "&", "&;", "&#;", "&eacute;&auml;",
        "&longentitynamethatisfartoolong;", "&a<b>;",
        "<p>", "</p>", "<div>", "</div>", "<br>", "<br/>", "<li>", "<ul>", "<ol>", "<table>", "<tr>", "<h1>", "</h1>",
        "<H2>", "<hr>", "<title>", "<dt>", "<blockquote>",
        "<pre>", "</pre>", "<PRE>", "<b>", "</b>", "<i class=\"x\">", "<span>", "<em>", "<h7>", "<p/>",
        "<a href=\"x\">", "<a href='y&amp;z'>", "<A HREF=u>", "<a href = \"w\">", "<a data-href=\"q\">",
        "<a href=\"\">", "<a href=\"#frag\">", "<a>", "<a name=\"n\">",
        "<a title=\"t\" href=\"https://example.com/?a=1&amp;b=2&c=3\" class=\"k\">", "<a\nhref=\"multi\nline\">",
        "<a\r\nhref=\"crlf\r\nvalue\">", "<a href=\"ü&euro;\">",
        "<a href='&#65;&#x42;&bogus;&amp'>", "<a href=\"a&amp;b&amp;c&amp;d&amp;e&amp;f&gt;&lt;&quot;&nbsp;\">",
        "<a href=value-with-dash/and&amp;more>", "<a href=\"x\" href=\"y\">",
        "<a href=\"日本語\">", "<a href=\"x\u{301}\">", "<a href=\"&;&&amp;;\">", "<a href=\"unterminated>", "</a>",
        "</A>",
        "<!-- comment -->", "<!-- <p>hidden</p> -->", "<!---->", "<!-->", "<!DOCTYPE html>", "<?xml version=\"1.0\"?>",
        "<script>var a = '<b>';</script>", "<SCRIPT type=text/javascript>x</Script>", "<style>p { color: red }</style>",
        "<svg><path d=\"M0\"/></svg>", "<noscript>no</noscript>",
        "<template><p>t</p></template>", "</script>", "<script src=x></script>", "< b>", "<>", "</>", "<3", "a < b",
        "x > y", "<<p>>", "<a b c>", "<verylongtagnamethatgoesonforever>",
        "<h1 attr=\"v\"", "<div class='a>b'>"
    ]

    /// A generator of numbers below a bound, the same series for the same seed.
    private func random(_ seed: UInt64) -> (Int) -> Int {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return { bound in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(truncatingIfNeeded: state >> 11) % max(1, bound)
        }
    }

    /// A random page of `count` pieces, with lone surrogates and control characters among them.
    private func generate(_ next: (Int) -> Int, count: Int) -> [UInt16] {
        var units: [UInt16] = []
        for _ in 0..<count {
            switch next(40) {
            case 0:
                units.append(UInt16(0xD800 + next(0x400)))

            case 1:
                units.append(UInt16(0xDC00 + next(0x400)))

            case 2:
                units.append(UInt16(next(0x20)))

            default:
                units.append(contentsOf: pieces[next(pieces.count)].utf16)
            }
        }
        return units
    }

    /// The fast scan gives what the unit-by-unit reference gives, for 400 random short pages, cut anywhere, with and
    /// without braces around the links.
    @Test
    internal func theFastScanGivesTheOutputOfTheUnitByUnitOne() {
        var compared = 0
        for seed in 1...400 as ClosedRange<UInt64> {
            let next = random(seed)
            var units = generate(next, count: 1 + next(60))
            // Cut anywhere, as a file can end in the middle of a tag or an entity.
            if seed.isMultiple(of: 5) { units.removeLast(min(units.count, next(12))) }
            for braces in [true, false] {
                let fast = HTMLText.plainText(units: units, linkBraces: braces, cancellation: nil)
                let reference = HTMLReference.plainText(units: units, linkBraces: braces)
                let page = String(decoding: units, as: UTF16.self).debugDescription
                #expect(fast == reference, Comment(rawValue: "seed \(seed), braces \(braces): \(page)"))
                compared += 1
            }
        }
        #expect(compared == 800)
    }

    /// The fast scan and the reference agree on long random pages too.
    @Test
    internal func theFastScanAgreesOnLongPagesToo() {
        for seed in 1_000...1_012 as ClosedRange<UInt64> {
            let next = random(seed)
            let units = generate(next, count: 4_000)
            #expect(
                HTMLText.plainText(units: units, linkBraces: true, cancellation: nil)
                    == HTMLReference.plainText(units: units, linkBraces: true),
                "seed \(seed)"
            )
            #expect(
                HTMLText.plainText(units: units, linkBraces: false, cancellation: nil)
                    == HTMLReference.plainText(units: units, linkBraces: false),
                "seed \(seed)"
            )
        }
    }

    /// Links are found in every form of the `href` attribute, and only there.
    @Test
    internal func linksAreFoundTheSameWayInEveryFormOfTheAttribute() {
        let html = """
            <a href="one">1</a> <A HREF='two&amp;2'>2</A> <a href=three>3</a> <a class=x href = "four">4</a> \
            <a data-href="five">5</a> <a href="#six">6</a>
            <a href="">7</a> <a href="https://e.com/?a=1&amp;b=2&amp;c&amp">8</a> \
            <a title='a href="nested"' href="real">9</a> <a href="ü">10</a>
            """
        let result = HTMLText.plainText(units: Array(html.utf16), linkBraces: true, cancellation: nil)
        #expect(result == HTMLReference.plainText(units: Array(html.utf16), linkBraces: true))
        // `data-href` is no `href`, and the text `href="nested"` inside the title of a tag is no attribute.
        #expect(result?.links == ["one", "two&2", "three", "four", "https://e.com/?a=1&b=2&c&amp", "real", "ü"])
    }
}
