import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FilePropertiesPlugin

/// Finder's Info window is asked for through AppleScript, which a test only notes.
@MainActor
@Suite
internal struct CoverageFilePropertiesFinder {
    /// The script of a request, the paths of the items last.
    @Test
    internal func finderIsAskedWithAScriptAndThePaths() throws {
        let box = try Sandbox()
        try box.file("A/one.txt")
        try box.folder("B")
        let scripts = Shared<[[String]]>([])
        let plugin = FilePropertiesPlugin { arguments in scripts.modify { $0.append(arguments) } }
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B")
        )
        bench.left.moveCursor(toName: "one.txt")
        bench.commands.perform("afm_FinderInfo")
        #expect(Wait.until { !scripts.value.isEmpty })
        let arguments = try #require(scripts.value.first)
        #expect(arguments == FilePropertiesPlugin.finderInfoArguments([box.url("A/one.txt")]))
        #expect(arguments.last == FilePropertiesPlugin.finderPath(of: box.url("A/one.txt")) && arguments.first == "-e")
        #expect(arguments.contains("tell application \"Finder\""))
        // A plugin that may start applications starts nothing by being made.
        #expect(FilePropertiesPlugin().finderInfoRequests.isEmpty)
    }

    /// Finder is handed the names on the way to an item, separated by `:`, a `:` in a name
    /// written as Finder shows it; the script starts from the disk under /Volumes itself.
    @Test
    internal func finderGetsTheNamesOnTheWayToTheItem() {
        let path = { (text: String) in FilePropertiesPlugin.finderPath(of: URL(fileURLWithPath: text)) }
        #expect(path("/Users/me/a:b.txt") == ":Users:me:a/b.txt")
        #expect(path("/Volumes/Backup/Photos") == ":Volumes:Backup:Photos")
        #expect(path("/") == ":")
        #expect(FilePropertiesPlugin.finderInfoArguments([]).contains("set found to disk (item 2 of names)"))
    }
}
