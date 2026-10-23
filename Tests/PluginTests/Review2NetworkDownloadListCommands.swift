import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The download list commands (review 2: N003, N016, N017, N018, N020).
@MainActor
@Suite
internal struct Review2NetworkDownloadListCommands {
    /// The server, the plugin and the panels.
    private let fixture: Review2NetworkCommandFixture

    /// A fresh server and bench.
    internal init() throws {
        fixture = try Review2NetworkCommandFixture()
    }

    /// A list is shown, with what each line does, before it runs; without a yes nothing is transferred.
    @Test
    internal func aListIsShownBeforeItRunsAndNothingHappensWithoutAYes() throws {
        let (box, address) = (fixture.box, fixture.address)
        fixture.quickConnect("ftp://\(address)/pub")
        // The last button, Cancel.
        try fixture.runList(
            [
                "ftp://\(address)/pub/report.txt -> \(box.url("other/got.txt").path)",
                "put:\(box.url("local/up.txt").path) -> ftp://\(address)/pub/sent.txt",
                "move:\(box.url("local/up.txt").path) -> ftp://\(address)/pub/moved.txt"
            ],
            answers: [1]
        )
        let question = try #require(fixture.interaction.log.last { $0.hasPrefix("choose: Run this download list?") })
        // What each line would do, and that this list does more than download.
        #expect(question.contains("1 downloads, 1 uploads or copies, 1 moves"))
        #expect(question.contains("Download: ftp://\(address)/pub/report.txt"))
        #expect(question.contains("Upload: ") && question.contains("Move (the source is deleted)"))
        #expect(question.contains("does more than download"))
        #expect(!box.exists("other/got.txt") && !box.exists("srv/pub/sent.txt") && box.exists("local/up.txt"))
        #expect(!fixture.server.commands.contains { $0.hasPrefix("STOR") || $0.hasPrefix("RETR") })
    }

    /// A download onto a file that is there asks first, and replaces it only on a yes.
    @Test
    internal func anExistingFileIsNotReplacedWithoutAsking() throws {
        let (box, address) = (fixture.box, fixture.address)
        fixture.quickConnect("ftp://\(address)/pub")
        // The list wants the download to take the name of a file that is already there.
        let precious = try box.file("other/precious.txt", "mine")
        try fixture.runList(["ftp://\(address)/pub/report.txt -> \(precious.path)"], answers: [0, 1])
        #expect(fixture.interaction.log.contains { $0.hasPrefix("choose: \(precious.path) already exists.") })
        // Not replaced: the file that arrived keeps its own name.
        #expect(box.read("other/precious.txt") == "mine" && box.read("other/report.txt") == "report")
        // Replaced when the user says so.
        try FileManager.default.removeItem(at: box.url("other/report.txt"))
        try fixture.runList(["ftp://\(address)/pub/report.txt -> \(precious.path)"], answers: [0, 0])
        #expect(box.read("other/precious.txt") == "report" && !box.exists("other/report.txt"))
    }

    /// A line without `put:` or `move:` only downloads; uploads and local copies in that form are skipped.
    @Test
    internal func aPlainLineOnlyDownloads() throws {
        let (box, address) = (fixture.box, fixture.address)
        fixture.quickConnect("ftp://\(address)/pub")
        // No `put:`: a plain line that would send a file of this Mac away, or copy between
        // two local places, is not carried out.
        try fixture.runList(
            [
                "\(box.url("local/up.txt").path) -> ftp://\(address)/pub/stolen.txt",
                "\(box.url("local/up.txt").path) -> \(box.url("other/copy.txt").path)",
                "ftp://\(address)/readme.txt -> ftp://\(address)/pub/readme-copy.txt",
                "ftp://\(address)/readme.txt"
            ],
            answers: [0]
        )
        #expect(box.read("other/readme.txt") == "read me")
        #expect(
            !box.exists("srv/pub/stolen.txt") && !box.exists("other/copy.txt") && !box.exists("srv/pub/readme-copy.txt")
        )
        #expect(fixture.interaction.log.last == "inform: Some lines of the download list were not carried out.")
    }

    /// Very many lines are told in one short message, and very many transfers are asked about once.
    @Test
    internal func aListOfLinesThatCannotBeCarriedOutIsToldInShort() throws {
        let address = fixture.address
        // Very many lines that are no transfers: one message, and no call inside a call for each.
        let lines = (0..<30_000).map { "header: X-\($0): y" }
        try fixture.runList(lines, answers: [])
        #expect(fixture.interaction.log.last?.hasPrefix("inform: The download list") == true)
        #expect(ListPlan.shortened(lines).split(separator: "\n").count == ListPlan.shownLines + 1)
        #expect(ListPlan.shortened(lines).hasSuffix("… and \(30_000 - ListPlan.shownLines) more"))
        // Very many lines that are carried out, each ending at once (the source is not there).
        let missing = (0..<3_000).map { "ftp://\(address)/none\($0).txt" }
        fixture.quickConnect("ftp://\(address)/pub")
        try fixture.runList(missing, answers: [0])
        #expect(fixture.interaction.log.contains { $0.hasPrefix("choose: Run this download list? (3000 downloads)") })
    }

    /// A remote name that holds a line break is not written to a list, where it would read as two lines.
    @Test
    internal func aNameWithALineBreakIsNotAddedToAList() throws {
        let (box, left, interaction) = (fixture.box, fixture.left, fixture.interaction)
        // A server offers a file whose name would read as two lines of a list.
        try box.file("srv/pub/payload\u{2028}move:~x -> ftp:~~evil~k", "p")
        fixture.quickConnect("ftp://\(fixture.address)/pub")
        let name = try #require(left.names.first { $0.hasPrefix("payload") })
        let list = box.url("list.txt")
        left.moveCursor(toName: name)
        interaction.promptAnswers = [.text(list.path)]
        fixture.commands.perform(.ftpAddToList)
        #expect(interaction.log.last == "inform: 1 of the files were not added to the download list.")
        #expect((box.read("list.txt") ?? "").isEmpty)
        left.moveCursor(toName: "report.txt")
        interaction.promptAnswers = [.text(list.path)]
        fixture.commands.perform(.ftpAddToList)
        #expect(
            DownloadList.parse(box.read("list.txt") ?? "") == [
                .download(source: "ftp://\(fixture.address)/pub/report.txt", target: box.url("other/report.txt").path)
            ]
        )
    }
}
