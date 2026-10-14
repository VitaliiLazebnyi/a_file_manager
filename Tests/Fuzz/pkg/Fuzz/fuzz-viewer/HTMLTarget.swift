import Foundation
import FuzzCore

@testable import ViewerPlugin

/// The `html` target: the fast HTML to text against the reference it was made from, and its time.
internal enum HTMLTarget {
    /// The slowest time per 1024 units noted so far, in seconds.
    @MainActor private static var slowestPerKB = 0.0

    /// The target.
    @MainActor
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "html",
            maxLen: 1 << 15,
            dict: [
                "<", ">", "</", "<a href=\"", "<a href='", "<a href=", "</a>", "<script>", "</script>", "<style>",
                "</style", "<pre>", "</pre>", "<br>", "<p>", "<li>", "<!--", "-->", "&amp;", "&#", "&#x", ";",
                "&#1114112;", "&#xFFFFFFFFFF;", "&#99999999999999999999;", "&#xD800;", "&#0;", "&nbsp;", "&", "<svg",
                "<template>", "<noscript>", "<title>", "\"", "'", "=", " ", "\n", "<![CDATA[", "]]>", "<?", "<a",
                "href",
                "<a href=\"&#x41;&amp;\">", "<<<<<<<<", "&&&&&&&&", "<a <a <a ", "<script<script"
            ],
            rawDict: [[0xED, 0xA0, 0x80], [0xF0, 0x9F, 0x98, 0x80], [0xC2, 0xA0], [0xE2, 0x80, 0xA8]],
            seeds: seeds,
            run: run
        )
    }

    /// The inputs the fuzzer starts from: the mode byte, then the HTML.
    internal static func seeds() -> [[UInt8]] {
        [
            "\u{0}<html><head><title>T</title><style>p{}</style><script>var a='</p>';</script></head><body>"
                + "<h1>Head</h1><p>Some <b>bold</b> &amp; <a href=\"http://x.example/a?b=1&amp;c=2\">link</a> "
                + "text&nbsp;here.</p><pre>  keep\n   this </pre><ul><li>one<li>two</ul><!-- note --><br/>"
                + "&#65;&#x42;&bogus; &lt;tag&gt;</body></html>",
            "\u{1}<a href='x'>y</a><a href=z>w</a><a>none</a><svg><a href=q>in</a></svg>tail &#x1F600; &#128512;",
            "\u{2}<p>unterminated <a href=\"foo", "\u{3}plain & simple < text > here"
        ]
        .map { Array($0.utf8) }
    }

    /// Runs one input.
    @MainActor
    internal static func run(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        let mode = choices.byte()
        let braces = mode & 1 == 0
        let units = units(choices.rest(), mode: mode)
        let started = Date()
        let fast = HTMLText.plainText(units: units, linkBraces: braces)
        noteTime(Date().timeIntervalSince(started), units: units)
        let reference = HTMLReference.plainText(units: units, linkBraces: braces)
        if fast != reference {
            let html = String(decoding: units, as: UTF16.self).debugDescription.prefix(600)
            fzFail(
                "html-differs-from-reference",
                "braces \(braces): \(html)\nfast: \(String(describing: fast).prefix(700))\n"
                    + "reference: \(String(describing: reference).prefix(700))"
            )
        }
        if let fast {
            fzCheck(
                fast.text.utf16.count <= units.count * 8 + 64,
                "html-output-much-larger",
                "\(units.count) units give \(fast.text.utf16.count)"
            )
        }
        let text = String(decoding: units.prefix(300), as: UTF16.self)
        _ = HTMLText.plainText(from: text, linkBraces: braces)
        _ = HTMLText.attribute("href", in: text[...])
        _ = HTMLText.decodeEntities(text[...])
        _ = HTMLText.decodeEntity(String(text.prefix(12)))
        _ = HTMLText.url(from: text)
    }

    /// `fuzz-viewer scale FILE`: prints the time of plainText for the file repeated 1 to 32 times.
    internal static func scale(path: String) {
        let body = [UInt8](FileManager.default.contents(atPath: path) ?? Data())
        let unit = Array(fzText(body).utf16)
        for factor in [1, 2, 4, 8, 16, 32] {
            var units: [UInt16] = []
            for _ in 0..<factor {
                units += unit
            }
            var best = Double.infinity
            for _ in 0..<3 {
                let started = Date()
                _ = HTMLText.plainText(units: units)
                best = min(best, Date().timeIntervalSince(started))
            }
            let milliseconds = String(format: "%.3f", best * 1_000)
            let perKB = String(format: "%.2f", best * 1e6 / (Double(units.count) / 1_024))
            print("x\(factor): \(units.count) units, \(milliseconds) ms, \(perKB) us per 1024 units")
        }
    }

    /// The UTF-16 units of the input: its bytes as UTF-8, or (mode bit 2) as they come from a UTF-16 file,
    /// lone surrogates and all, and (mode bit 4) then mostly made ASCII.
    private static func units(_ body: [UInt8], mode: UInt8) -> [UInt16] {
        if mode & 2 == 0 {
            return Array(fzText(body).utf16)
        }
        var units: [UInt16] = []
        var index = 0
        while index + 1 < body.count {
            units.append(UInt16(body[index]) | UInt16(body[index + 1]) << 8)
            index += 2
        }
        if mode & 4 != 0 {
            units = units.map { $0 & 0x00FF == $0 ? $0 : ($0 & 0x7F) }
        }
        return units
    }

    /// Notes the time of an input of at least 512 units when it is the slowest per 1024 units so far.
    @MainActor
    private static func noteTime(_ seconds: TimeInterval, units: [UInt16]) {
        guard units.count >= 512 else {
            return
        }
        let perKB = seconds / (Double(units.count) / 1_024)
        if perKB > slowestPerKB {
            slowestPerKB = perKB
            let start = String(decoding: units.prefix(60), as: UTF16.self).debugDescription
            fzNote("html slowest \(Int(perKB * 1e6)) us per 1024 units, \(units.count) units, starts \(start)")
        }
    }
}
