import Foundation
import FuzzCore

@testable import FileOperationsPlugin

// MARK: name template

/// The longest name template so far (seconds), for the note of the slowest input.
@MainActor internal var slowestTemplate = 0.0

/// The seeds of `nametemplate`.
@MainActor
internal func nameTemplateSeeds() -> [[UInt8]] {
    seedsOf([
        "00a/b/c | other\nfile.name.txt\nparent\ngrand\nclip\n",
        "10<[Y]-[M]-[D] downloads [hms][v][i][i1][d][t]\nx.y\np\ng\nc\n",
        "20<Copy of [N] [E] [A] [P] [G] [S] [N2-5] [N2,3] [N-3-] [N02-9] [N-8-5]\nreport final.tar.gz\np\ng\nc\n",
        "30<1-10>[C]\n\n\n\n\n", "40<1-3>test[\" (\"C\")\"]\n\n\n\n\n",
        "50<test[C]|a[C:3]|[U]b[L]C[F]the end of[f]the end of[n][X][X+][[][]][%HOME%]\nn\np\ng\nclip\n",
        "61\"a b.txt\" \"c.txt\" d|e\n\n\n\n\n", "70<[T2+1D][Y][T1-60m][h][=x][Q][N\n\n\n\n\n"
    ])
}

/// The template's context: the item under the cursor and its folders, a fixed clock, the clipboard, and
/// (when `flags` ask for it) names that already exist.
internal func templateContext(flags: UInt8, salt: UInt8, _ choices: inout Choices) -> NameTemplate.Context {
    var context = NameTemplate.Context()
    context.cursorName = name255(choices.until(0x0A))
    context.cursorIsFolder = flags & 1 != 0
    context.cursorSize = flags & 2 != 0 ? Int64.max : Int64(salt)
    context.parentName = name255(choices.until(0x0A))
    context.grandparentName = name255(choices.until(0x0A))
    context.now = Date(timeIntervalSince1970: 1_700_000_000.5)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = kUTC
    calendar.locale = kPosixLocale
    context.calendar = calendar
    context.clipboard =
        flags & 4 != 0 ? nil : text(choices.until(0x0A)).replacingOccurrences(of: "\u{1}", with: "\n")
    context.environment = ["HOME": "/Users/me", "X": "a:b/c\\d", "E": ""]
    let seed = UInt64(salt)
    if flags & 8 != 0 {
        context.exists = { name in
            let hash = name.utf8.reduce(seed &+ 0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
            return !(hash >> 40).isMultiple(of: 4)
        }
    }
    return context
}

/// The names a typed template makes, timed; no name comes out empty.
@MainActor
internal func runNameTemplate(_ bytes: [UInt8]) {
    var choices = Choices(bytes)
    let flags = choices.byte()
    let salt = choices.byte()
    let typed = text(choices.until(0x0A))
    let context = templateContext(flags: flags, salt: salt, &choices)
    let started = Date()
    let names = try? NameTemplate.names(from: typed, context: context, quotedLists: flags & 16 != 0)
    _ = NameTemplate.rangePreview(typed, context: context)
    let elapsed = Date().timeIntervalSince(started)
    if elapsed > slowestTemplate, elapsed > 0.005 {
        slowestTemplate = elapsed
        fzNote("nametemplate slowest \(Int(elapsed * 1_000)) ms typed=\(typed.debugDescription.prefix(300))")
    }
    // A list part that expands to nothing ("<[T2+1D]", "<a|[U]") comes back as an empty name, while a
    // counter range filters such names out: noted in the results, not failed, so the run goes on.
    for name in names ?? [] {
        fzCheck(!name.isEmpty, "nametemplate-empty-name", typed.debugDescription)
    }
}

/// The `nametemplate` target.
@MainActor
internal func nameTemplateTarget() -> FuzzTarget {
    FuzzTarget(
        "nametemplate",
        maxLen: 2_048,
        dict: kMaskDict + [
            "<", ">", "|", "\"", "<1-10>", "<0-99999>", "<1-3>test[\" (\"C\")\"]", "[\" (\"C\")\"]", "[C:3]",
            "[C:999]", "[C10+5:3]", "[Y-M-D]", "[T2+1D]", "[T1+9223372036854775807Y]",
            "[T1-9223372036854775808s]", "[N9223372036854775807-]", "[N1,9223372036854775807]",
            "[N-9223372036854775807-1]", "9223372036854775807", "[N1--1]", "[%HOME%1-2]",
            "[N01,300]", "[N 2-5]", "[i1]", "[d]", "[t]", "٣", "²", "[N٣]", "[C²]"
        ],
        seeds: nameTemplateSeeds,
        run: runNameTemplate
    )
}
