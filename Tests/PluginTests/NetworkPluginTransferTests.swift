import AFMContracts
import AFMKernel
import Foundation
import NetworkPlugin
import TestSupport
import Testing

/// The network plugin with the real copy job: downloads, uploads, moves and changes on the server, and download
/// lists.
@MainActor
@Suite
internal struct NetworkPluginTransferTests: NetworkCommandSuite {
    /// The bench, the server and the plugin of the test.
    internal let fixture: NetworkCommandFixture

    /// A fresh fixture for every test.
    internal init() throws {
        fixture = try NetworkCommandFixture()
    }

    /// Files and folders are downloaded with the copy job, and no temporary file is left.
    @Test
    internal func downloadsWithTheCopyJob() {
        quickConnect("ftp://\(address)/pub")
        right.show(box.url("other"))
        // One file, then a folder with what is in it. The target is written as a `file:` URL:
        // a plain path typed for a server panel means a path on that server.
        left.moveCursor(toName: "report.txt")
        dialogs.promptAnswers = [.text(localTarget)]
        commands.perform(.copy)
        #expect(box.read("other/report.txt") == "report")
        left.moveCursor(toName: "sub")
        dialogs.promptAnswers = [.text(localTarget)]
        commands.perform(.copy)
        #expect(box.read("other/sub/deep.txt") == "deep")
        #expect(!dialogs.log.contains { $0.hasPrefix("choose: Error") })
        #expect(namesOnDisk(box.url("other")) == ["report.txt", "sub"], "no temporary file is left")
    }

    /// Uploads, overwriting after a question, rename, new folder and delete work on a server panel with
    /// the usual commands.
    @Test
    internal func uploadsRenamesAndDeletesWithTheUsualCommands() throws {
        quickConnect("ftp://\(address)/pub")
        bench.panelSet.source = right
        right.show(box.url("local"))
        // The proposed target is the server folder as the user reads it.
        right.model.selectAll()
        dialogs.promptAnswers = [.accept]
        commands.perform(.copy)
        #expect(dialogs.log.contains("prompt: Copy 2 file(s) to [ftp://\(address)/pub/*.*]"))
        #expect(box.read("srv/pub/up.txt") == "upload" && box.read("srv/pub/tree/inner/b.txt") == "bb")
        #expect(namesOnDisk(box.url("srv/pub")) == ["report.txt", "sub", "tree", "up.txt"])
        #expect(left.names == ["sub", "tree", "report.txt", "up.txt"], "the server panel was re-read")

        // Uploading again asks before it overwrites.
        try box.file("local/up.txt", "second version")
        right.model.clearSelection()
        right.moveCursor(toName: "up.txt")
        dialogs.promptAnswers = [.accept]
        dialogs.choiceAnswers = [0]
        commands.perform(.copy)
        #expect(
            dialogs.log.contains { $0.hasPrefix("choose: Overwrite:") }
                && box.read("srv/pub/up.txt") == "second version"
        )

        bench.panelSet.source = left
        // Rename in place, new folder, delete a tree.
        left.moveCursor(toName: "up.txt")
        commands.perform(.renameOnly, .text("renamed.txt"))
        #expect(
            box.exists("srv/pub/renamed.txt") && !box.exists("srv/pub/up.txt")
                && left.model.cursorItem?.name == "renamed.txt"
        )
        dialogs.promptAnswers = [.text("new/nested")]
        commands.perform(.makeDirectory)
        #expect(box.exists("srv/pub/new/nested"))
        left.moveCursor(toName: "tree")
        // F8 on a server deletes directly: there is no Trash. Yes, then "delete the non-empty folder".
        dialogs.choiceAnswers = [0, 0]
        commands.perform(.delete)
        #expect(!box.exists("srv/pub/tree") && left.names == ["new", "sub", "renamed.txt", "report.txt"])
        #expect(!dialogs.log.contains { $0.hasPrefix("choose: Error") })
    }

    /// A move to the disk downloads and deletes; a move within the server is a rename.
    @Test
    internal func movesBetweenServerAndDisk() {
        quickConnect("ftp://\(address)/pub")
        left.moveCursor(toName: "report.txt")
        dialogs.promptAnswers = [.text(localTarget)]
        commands.perform(.renameMove)
        #expect(box.read("other/report.txt") == "report" && !box.exists("srv/pub/report.txt"))
        // Within the server a move is a rename.
        left.moveCursor(toName: "sub")
        dialogs.promptAnswers = [.text("ftp://\(address)/moved")]
        commands.perform(.renameMove)
        #expect(box.read("srv/moved/deep.txt") == "deep" && !box.exists("srv/pub/sub"))
        #expect(server.commands.contains("RNFR /pub/sub") && server.commands.contains("RNTO /moved"))
    }

    /// Download later writes a line to the list, and running the list does what its lines say and
    /// reports those it cannot do.
    @Test
    internal func downloadListIsWrittenAndWorkedThrough() throws {
        quickConnect("ftp://\(address)/pub")
        let list = box.url("list.txt")
        left.moveCursor(toName: "report.txt")
        dialogs.promptAnswers = [.text(list.path)]
        commands.perform(.ftpAddToList)
        #expect(box.read("list.txt") == "ftp://\(address)/pub/report.txt -> \(box.url("other/report.txt").path)\n")
        #expect(!box.exists("other/report.txt"), "download later downloads nothing")

        // More lines: a target with another name, one without a target, an upload, and one that cannot be done.
        let firstLine = try #require(box.read("list.txt"))
        try
            (firstLine + "ftp://\(address)/readme.txt -> \(box.url("other/README.md").path)\n"
            + "ftp://\(address)/pub/sub/deep.txt\nput:\(box.url("local/up.txt").path) -> ftp://\(address)/pub/sub/up.txt\nheader: X: y\n")
            .write(to: list, atomically: true, encoding: .utf8)
        dialogs.promptAnswers = [.accept]
        // What the list would do is shown, and it runs when the user agrees.
        dialogs.choiceAnswers = [0]
        commands.perform(.ftpDownloadList)
        #expect(dialogs.log.contains("prompt: File name of download list: [\(list.path)]"), "the last list is proposed")
        #expect(
            dialogs.log.contains { $0.hasPrefix("choose: Run this download list? (3 downloads, 1 uploads or copies)") }
        )
        #expect(box.read("other/report.txt") == "report" && box.read("other/README.md") == "read me")
        #expect(box.read("other/deep.txt") == "deep" && box.read("srv/pub/sub/up.txt") == "upload")
        #expect(dialogs.log.last == "inform: Some lines of the download list were not carried out.")
    }
}
