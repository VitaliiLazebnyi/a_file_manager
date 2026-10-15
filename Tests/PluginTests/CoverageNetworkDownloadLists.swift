import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import NetworkPlugin

/// Download lists that cannot be read or written, and lists that are written in odd places.
@MainActor
@Suite
internal struct CoverageNetworkDownloadLists {
    private let fixture: CoverageNetworkBench

    private var scripted: ScriptedInteraction { fixture.scripted }

    /// A fresh bench.
    internal init() throws {
        fixture = try CoverageNetworkBench()
    }

    /// Asks to run the list file `name` of the sandbox, which holds `data`, and cancels.
    private func run(_ name: String, holding data: Data) throws {
        let list = fixture.box.url(name)
        try data.write(to: list)
        scripted.promptAnswers = [.text(list.path)]
        fixture.commands.perform(.ftpDownloadList)
    }

    /// A list that is no text, one that is too large, and a folder are not read.
    @Test
    internal func listsThatAreNoTextOrTooLargeAreNotRead() throws {
        try run("binary.txt", holding: Data([0x66, 0x81, 0x0A]))
        #expect(scripted.log.last == "inform: The download list cannot be read!")
        try run("large.txt", holding: Data(repeating: 0x0A, count: DownloadList.largestFile + 1))
        #expect(scripted.log.last == "inform: The download list cannot be read!")
        scripted.promptAnswers = [.text(fixture.box.url("other").path)]
        fixture.commands.perform(.ftpDownloadList)
        #expect(scripted.log.last == "inform: The download list cannot be read!")
        #expect(throws: VolumeError.self) { try NetworkCommands.readList(fixture.box.url("binary.txt")) }
    }

    /// A list in Windows Latin 1 is read; lines without a target go to the home folder when the
    /// target panel shows no local folder.
    @Test
    internal func aListInWindowsLatinIsRead() throws {
        fixture.quickConnect("ftp://\(fixture.address)/pub")
        fixture.right.show(fixture.url("/"))
        var data = Data("ftp://\(fixture.address)/caf".utf8)
        data.append(contentsOf: [0xE9, 0x0A])
        try run("latin.txt", holding: data)
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: "caf\u{E9}").path
        #expect(scripted.log.last?.contains("Download: ftp://\(fixture.address)/caf\u{E9}  \u{2192}  \(home)") == true)
    }

    /// A cancelled prompt, an empty name and a location that is no file are no list.
    @Test
    internal func onlyALocalFileIsAList() {
        for answer: ScriptedInteraction.PromptAnswer in [.cancel, .text("  "), .text("ftp://\(fixture.address)/l")] {
            scripted.promptAnswers = [answer]
            fixture.commands.perform(.ftpDownloadList)
        }
        #expect(scripted.log.allSatisfy { $0.hasPrefix("prompt: ") })
    }

    /// Without the file operations nothing can be copied, so no list is run.
    @Test
    internal func withoutFileOperationsNoListIsRun() throws {
        let bare = try CoverageNetworkBench(company: .navigationOnly, withMounter: false)
        let list = try bare.box.file("list.txt", "ftp://\(bare.address)/readme.txt\n")
        bare.scripted.promptAnswers = [.text(list.path)]
        bare.commands.perform(.ftpDownloadList)
        #expect(bare.scripted.log.last == "inform: Copying files is not available.")
    }

    /// Lines are added after an unfinished last line, without a target when the other panel is
    /// on a server; a list that would grow too large is not written.
    @Test
    internal func linesAreAddedAfterAnUnfinishedLastLine() throws {
        fixture.quickConnect("ftp://\(fixture.address)/")
        fixture.right.show(fixture.url("/pub"))
        let list = try fixture.box.file("list.txt", "earlier line")
        fixture.left.moveCursor(toName: "readme.txt")
        scripted.promptAnswers = [.text(list.path)]
        fixture.commands.perform(.ftpAddToList)
        #expect(fixture.box.read("list.txt") == "earlier line\nftp://\(fixture.address)/readme.txt\n")
        try Data(repeating: 0x41, count: DownloadList.largestFile - 10).write(to: list)
        scripted.promptAnswers = [.text(list.path)]
        fixture.commands.perform(.ftpAddToList)
        #expect(scripted.log.last == "inform: The download list cannot be written!")
    }

    /// With no marked files nothing is asked.
    @Test
    internal func withoutFilesNothingIsAsked() throws {
        try FileManager.default.createDirectory(at: fixture.box.url("empty"), withIntermediateDirectories: true)
        fixture.left.show(fixture.box.url("empty"))
        fixture.plugin.commands?.addToDownloadList()
        #expect(scripted.log.isEmpty)
    }

    /// A list that is written while the job is cancelled is left as it was, without a message.
    @Test
    internal func aCancelledListIsLeftAsItWas() throws {
        fixture.quickConnect("ftp://\(fixture.address)/")
        let kernel = Kernel(productName: "Test", settings: fixture.settings, interaction: fixture.scripted)
        kernel.fileSystems.register(LocalFileSystem())
        let plugin = NetworkPlugin(launchesApplications: false, passwords: MemoryPasswords())
        kernel.load([plugin])
        plugin.center.environment.declineMemory = 0
        let shell = CoverageNetworkCancelledJobs(
            left: fixture.box.url("local"),
            right: fixture.box.url("other"),
            fileSystems: kernel.fileSystems
        )
        kernel.attach(shell)
        plugin.center.announce(ConnectionProfile(key: fixture.key, anonymous: true), chosen: true)
        _ = try plugin.center.connect(fixture.key, cancellation: nil)
        shell.panelSet.leftPanel.show(fixture.url("/"))
        shell.panelSet.leftPanel.moveCursor(toName: "readme.txt")
        let list = try fixture.box.file("list.txt", "earlier\n")
        let log = scripted.log
        scripted.promptAnswers = [.text(list.path)]
        kernel.commands.perform(.ftpAddToList)
        #expect(fixture.box.read("list.txt") == "earlier\n")
        #expect(scripted.log.count == log.count + 1)
        plugin.stop()
    }
}
