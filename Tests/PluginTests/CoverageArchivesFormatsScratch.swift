import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// The folder for the plugin's temporary files, and what it notes outside itself.
@Suite
internal struct CoverageArchivesFormatsScratch {
    private let box: Sandbox

    /// A new folder for each test.
    internal init() throws {
        box = try Sandbox()
    }

    /// A file that does not carry one of the program's own temporary names is never noted, nor removed.
    @Test
    internal func onlyTheProgramsOwnNamesAreNotedOutside() throws {
        let scratch = ScratchFolder(in: try box.folder("scratch"))
        let stranger = try box.file("outside/document.txt")
        scratch.noteExternal(stranger)
        #expect(!FileManager.default.fileExists(atPath: scratch.url.path + ".external"))
        scratch.removeAll()
        #expect(FileManager.default.fileExists(atPath: stranger.path))
    }

    /// A temporary file outside goes with the folder, also when its list could not be written.
    @Test
    internal func aFileOutsideGoesWithTheFolderWhenItsListCannotBeWritten() throws {
        let scratch = ScratchFolder(in: try box.folder("scratch"))
        // Something else has taken the name of the list.
        try FileManager.default.createDirectory(
            atPath: scratch.url.path + ".external",
            withIntermediateDirectories: true
        )
        let outside = try box.file("outside/.1.afm-zip.tmp")
        scratch.noteExternal(outside)
        scratch.removeAll()
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    /// Sweeping a folder that is not there does nothing.
    @Test
    internal func sweepingAFolderThatIsNotThereDoesNothing() {
        ScratchFolder.sweepLeftovers(in: box.url("nowhere"))
        #expect(!box.exists("nowhere"))
    }

    /// Names that only begin like the program's folders, and the program's own, are left alone.
    @Test
    internal func namesThatOnlyLookLikeLeftoversAreNotTouched() throws {
        let parent = try box.folder("scratch")
        let names = [
            "\(ScratchFolder.prefix)none", "\(ScratchFolder.prefix)0-x", "\(ScratchFolder.prefix)\(getpid())-x",
            // The system's own first process: running, and not this user's to ask about.
            "\(ScratchFolder.prefix)1-x"
        ]
        for name in names {
            try FileManager.default.createDirectory(
                at: parent.appending(name: name),
                withIntermediateDirectories: true
            )
        }
        ScratchFolder.sweepLeftovers(in: parent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() == names.sorted())
    }

    /// The list of a folder that was kept stays with what it names, and a "list" that cannot be read removes nothing.
    @Test
    internal func theListOfAKeptFolderAndAListThatCannotBeReadStay() throws {
        let parent = try box.folder("scratch")
        let dead = try CoverageArchivesFormatsSupport.deadProcess()
        let kept = parent.appendingPathComponent("\(ScratchFolder.prefix)\(dead)-KEPT")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data().write(to: kept.appendingPathComponent("kept-unsaved-changes"))
        let leftover = try box.file("outside/.2.afm-zip.tmp")
        let keptList = URL(fileURLWithPath: kept.path + ".external")
        try Data("\(leftover.path)\n".utf8).write(to: keptList)
        let odd = parent.appendingPathComponent("\(ScratchFolder.prefix)\(dead)-ODD.external")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        ScratchFolder.sweepLeftovers(in: parent)
        let files = FileManager.default
        #expect(files.fileExists(atPath: keptList.path) && files.fileExists(atPath: leftover.path))
        #expect(files.fileExists(atPath: kept.path) && files.fileExists(atPath: odd.path))
    }
}
