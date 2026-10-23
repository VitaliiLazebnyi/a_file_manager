import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// The placeholders of a Parameters field (spec 18 › Button and command parameters).
@Suite
internal struct ParameterExpansionTests {
    /// What a list parameter expanded to, and the list file it wrote (nil when there is none).
    internal typealias ListResult = (text: String, written: Data?)

    /// Three names selected on the left (`/A dir/`), the cursor on `my file.txt`; `other.md` on the right.
    internal let context = ExpansionContext(
        left: PanelSnapshot(path: "/A dir/", cursorName: "my file.txt", selection: ["a.txt", "b c.txt", "d.tar.gz"]),
        right: PanelSnapshot(path: "/B/", cursorName: "other.md"),
        environment: ["HOME": "/Users/me", "Q": "\"quoted\""],
        arguments: "one \"two words\" three",
        listFolder: URL(fileURLWithPath: "/tmp/lists"),
        listName: "test"
    )

    /// Takes the selection of the left panel away.
    internal let unselected: (inout ExpansionContext) -> Void = { $0.left.selection = [] }

    /// `text` expanded in the suite's context.
    internal func expand(_ text: String) -> String {
        ParameterExpander(context: context).expand(text).text
    }

    /// `text` expanded in the suite's context after `change`.
    internal func expand(_ text: String, _ change: (inout ExpansionContext) -> Void) -> String {
        var changed = context
        change(&changed)
        return ParameterExpander(context: changed).expand(text).text
    }

    /// `text` expanded in the suite's context with list files in `box`.
    internal func list(_ text: String, in box: Sandbox) throws -> ListResult {
        try list(text, in: box, context: context)
    }

    /// `text` expanded with list files in `box`, in the suite's context after `change`.
    internal func list(
        _ text: String,
        in box: Sandbox,
        _ change: (inout ExpansionContext) -> Void
    ) throws -> ListResult {
        var changed = context
        change(&changed)
        return try list(text, in: box, context: changed)
    }

    /// `text` expanded in `context` with list files in `box`; the list file, if any, is written and read back.
    internal func list(_ text: String, in box: Sandbox, context: ExpansionContext) throws -> ListResult {
        var inBox = context
        inBox.listFolder = box.url("lists")
        let result = ParameterExpander(context: inBox).expand(text)
        guard let file = result.listFile else {
            return (result.text, nil)
        }
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try file.contents.write(to: file.url)
        #expect(file.url == box.url("lists/list-test.txt"))
        return (result.text, try Data(contentsOf: box.url("lists/list-test.txt")))
    }

    /// Each placeholder of a single value inserts it, quoted when it needs to be.
    @Test
    internal func singleValues() {
        #expect(expand("%P") == "\"/A dir/\"" && expand("%T") == "/B/")
        #expect(expand("%N") == "\"my file.txt\"" && expand("%M") == "other.md")
        #expect(expand("%O") == "\"my file\"" && expand("%E") == "txt")
        // The lower-case codes insert the same: the Mac has no short names.
        #expect(
            expand("%p%n") == expand("%P%N") && expand("%t%m") == "/B/other.md" && expand("%o.%e") == "\"my file\".txt"
        )
        #expect(expand("%v") == "\"my file.txt\"" && expand("%V") == "\"/A dir/my file.txt\"")
        #expect(expand("100%% %|HOME|/x %|NONE|.") == "100% /Users/me/x .")
        // A variable's value is quoted like any other: it stays one word whatever it holds.
        #expect(expand("%|Q| %q%|Q| %q%|Q|") == "\"\\\"quoted\\\"\" quoted \"\\\"quoted\\\"\"")
        #expect(expand("-o %J %") == "-o %J %")
        // A value that is empty and a word of its own stays a word: the later ones keep their places.
        #expect(expand("%N %M") { $0.left.cursorName = nil } == "\"\" other.md")
    }

    /// Names with spaces or characters the shell reads are quoted as one word; quotes the user wrote are kept.
    @Test
    internal func namesWithSpacesAreQuotedAsOneWord() {
        #expect(expand("open %P%N --to %T%M") == "open \"/A dir/my file.txt\" --to /B/other.md")
        // Quotes the user wrote are kept and not doubled.
        #expect(expand("\"%P%N\"") == "\"/A dir/my file.txt\"" && expand("x=\"%N\"") == "x=\"my file.txt\"")
        // %Q leaves the quoting to the user.
        #expect(expand("%Q%P%N") == "/A dir/my file.txt" && expand("%S%Q") == "a.txt b c.txt d.tar.gz")
        // What the shell would interpret is quoted and escaped too.
        #expect(expand("%N") { $0.left.cursorName = "a$b\"c.txt" } == "\"a\\$b\\\"c.txt\"")
        #expect(
            expand("%N") { $0.left.cursorName = "x=1" } == "\"x=1\""
                && expand("%N") { $0.left.cursorName = "plain-1_2.txt" } == "plain-1_2.txt"
        )
        #expect(
            ShellWords.unquoted("\"a\\$b\\\"c d\"") == "a$b\"c d"
                && ShellWords.split("a \"b c\" d") == ["a", "\"b c\"", "d"]
        )
    }

    /// `%S` and its ranges insert the selected names, each name quoted on its own.
    @Test
    internal func selectedNames() {
        #expect(expand("%S") == "a.txt \"b c.txt\" d.tar.gz" && expand("%s") == expand("%S"))
        #expect(expand("%P%S") == "\"/A dir/a.txt\" \"/A dir/b c.txt\" \"/A dir/d.tar.gz\"")
        #expect(expand("%T%S1") == "/B/a.txt")
        #expect(expand("%R") == "other.md" && expand("%T%R") == "/B/other.md")
        #expect(expand("%R") { $0.right.selection = ["x", "y z"] } == "x \"y z\"")
        // Nothing selected: the file under the cursor, unless %Y asks for nothing.
        #expect(expand("ls %S", unselected) == "ls \"my file.txt\"" && expand("ls %Y%S", unselected) == "ls")
        // Ranges.
        #expect(
            expand("%S2") == "a.txt \"b c.txt\"" && expand("%S+2") == "\"b c.txt\""
                && expand("%S+2-3") == "\"b c.txt\" d.tar.gz"
        )
        #expect(
            expand("%S+2-") == "\"b c.txt\" d.tar.gz" && expand("%S-1") == "d.tar.gz"
                && expand("%S-3-2") == "a.txt \"b c.txt\""
        )
        #expect(
            expand("%S-2-") == "\"b c.txt\" d.tar.gz" && expand("%S+9").isEmpty
                && expand("%S -x") == "a.txt \"b c.txt\" d.tar.gz -x"
        )
        // In the user's quotes every name gets its own pair, with the text around as affixes.
        #expect(expand("\"%S\"") == "\"a.txt\" \"b c.txt\" \"d.tar.gz\"")
        #expect(expand("cp \"%P%S\" x") == "cp \"/A dir/a.txt\" \"/A dir/b c.txt\" \"/A dir/d.tar.gz\" x")
        #expect(
            expand("\"new-%S-old%E.bak\"") == "\"new-a-old.txt.bak\" \"new-b c-old.txt.bak\" \"new-d.tar-old.gz.bak\""
        )
        #expect(expand("\"%S.bak\"") == "\"a.txt.bak\" \"b c.txt.bak\" \"d.tar.gz.bak\"")
    }

    /// `:~` takes a part of a value, counted from either end.
    @Test
    internal func substrings() {
        #expect(
            expand("%E:~0,2") == "tx" && expand("%E:~1") == "xt" && expand("%E:~-2") == "xt"
                && expand("%E:~-2,1") == "x"
        )
        #expect(expand("%P:~0,-1") == "\"/A dir\"" && expand("%E:~1,1~2") == "x2" && expand("%E:~9") == "\"\"")
        // -0: the name without its extension, or the extension.
        #expect(expand("%N:~-0,2") == "my" && expand("%N:~-0,-2") == "tx" && expand("%N:~-0") == "\"my file\"")
        // With a path in front, the substring is taken from the name.
        #expect(expand("%T%S:~0,1") == "/B/a /B/b /B/d")
        #expect(expand("%E:x %E:~") == "txt:x txt:~")
    }

    /// The folder names (`%B`), the files to compare (`%C`) and the sides (`%X`, `%x`).
    @Test
    internal func directoriesComparedFilesAndSides() {
        let deep: (inout ExpansionContext) -> Void = { $0.left.path = "/Users/me/Projects/app/" }
        #expect(expand("%B", deep) == "app" && expand("%B0 %B1 %B2 %B9", deep) == "app Projects me \"\"")
        #expect(expand("%B-1", deep) == "Projects" && expand("%B+1 %B+3 %B+ [%B+0]", deep) == "Users Projects / []")
        #expect(expand("%BT %BT1") == "B \"\"")
        #expect(expand("%C1 %C2 %C3 %C4") == "\"/A dir/a.txt\" \"/A dir/b c.txt\" \"/A dir/d.tar.gz\" \"\"")
        // Fewer than two selected: the second file is the one of the same name on the other side.
        #expect(expand("%C1 %C2", unselected) == "\"/A dir/my file.txt\" \"/B/my file.txt\"")
        #expect(
            expand("%C1 %C2") { context in
                context.left.selection = []
                context.right.selection = ["r.txt"]
            } == "\"/A dir/my file.txt\" /B/r.txt"
        )
        // The right panel is the source: source and target swap, %X names the sides themselves.
        let rightActive: (inout ExpansionContext) -> Void = { $0.sourceIsRight = true }
        #expect(
            expand("%P %T", rightActive) == "/B/ \"/A dir/\""
                && expand("%X%P %T %x%P", rightActive) == "\"/A dir/\" /B/ /B/"
        )
        #expect(expand("%X%N %M %S1 %R") == "\"my file.txt\" other.md a.txt other.md")
        #expect(expand("%C1 %C2", rightActive) == "\"/A dir/a.txt\" /B/other.md")
    }

    /// `%A` and its ranges insert the words passed to a user command.
    @Test
    internal func argumentsOfAUserCommand() {
        #expect(expand("%A") == "one \"two words\" three" && expand("%q%A") == "one two words three")
        #expect(expand("/L=%A1 /R=%A2") == "/L=one /R=\"two words\"")
        #expect(
            expand("%A-1 %A2+ [%A2-] %A1-2 %A-3-2 %A-2- %A9")
                == "three \"two words\" three [\"two words\" three] one \"two words\" one \"two words\" "
                + "\"two words\" three"
        )
        #expect(
            ParameterExpander(context: context).expand("%A1").usedArguments
                && !ParameterExpander(context: context).expand("%N").usedArguments
        )
    }

    /// A question mark at the start asks the user first; one elsewhere is text.
    @Test
    internal func aLeadingQuestionMarkAsksFirst() {
        let asked = ParameterExpander(context: context).expand("?-v %N")
        #expect(asked.asksFirst && asked.text == "-v \"my file.txt\"")
        #expect(!ParameterExpander(context: context).expand("-v ?").asksFirst)
    }

    /// The list placeholders write the names to a file in the list folder and insert its path.
    @Test
    internal func listFilesAreWrittenToTheListFolder() throws {
        let box = try Sandbox()
        let path = box.url("lists/list-test.txt").path
        let withPaths = try list("tar -T %L", in: box)
        #expect(
            withPaths.text == "tar -T " + path
                && withPaths.written == Data("/A dir/a.txt\n/A dir/b c.txt\n/A dir/d.tar.gz\n".utf8)
        )
        #expect(try list("%F", in: box).written == Data("a.txt\nb c.txt\nd.tar.gz\n".utf8))
        #expect(
            try list("%l", in: box).written == withPaths.written && list("%D", in: box).written == withPaths.written
                && list("%d", in: box).written == list("%f", in: box).written
        )
        #expect(
            try list("%UF", in: box).written == Data([0xEF, 0xBB, 0xBF]) + Data("a.txt\nb c.txt\nd.tar.gz\n".utf8)
        )
        let wide = try #require(try list("%WL", in: box, unselected).written)
        #expect(
            wide.prefix(2) == Data([0xFF, 0xFE])
                && String(bytes: wide.dropFirst(2), encoding: .utf16LittleEndian) == "/A dir/my file.txt\n"
        )
        // The target panel's selection is added with %a; only the first list of a command counts.
        #expect(
            try list("%a%L", in: box) { $0.right.selection = ["r.txt"] }.written
                == Data("/A dir/a.txt\n/A dir/b c.txt\n/A dir/d.tar.gz\n/B/r.txt\n".utf8)
        )
        #expect(try list("%F %L", in: box).text == path)
        // Nothing selected: the cursor file; %Y an empty list; %y no list parameter at all.
        #expect(try list("%F", in: box, unselected).written == Data("my file.txt\n".utf8))
        #expect(try list("%Y%F", in: box, unselected).written == Data())
        let dropped = try list("-x %y%L", in: box, unselected)
        #expect(dropped.text == "-x" && dropped.written == nil)
        #expect(try list("%Y%y%F", in: box, unselected).written == Data("my file.txt\n".utf8))
        #expect(
            try list("%Y%y%F", in: box) { context in
                context.left.selection = []
                context.left.cursorName = nil
            }
            .written == nil
        )
        #expect(try list("%UX", in: box).text == "%UX")
    }
}
