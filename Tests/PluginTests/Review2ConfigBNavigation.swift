import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import NavigationPlugin

/// Navigation (review 2): volumes are asked in a job, the clipboard only when it changed.
@MainActor
@Suite
internal struct Review2ConfigBNavigation {
    /// The folders `/A/docs` and `/B`.
    internal let memory = MemoryFileSystem()
    /// A pasteboard of the test's own.
    private let scratch = ScratchPasteboard()
    /// The program with the navigation commands, `/A` on the left and `/B` on the right.
    internal let bench: TestBench

    /// The pasteboard the navigation commands read.
    internal var pasteboard: NSPasteboard { scratch.pasteboard }

    /// The bench over the two folders.
    internal init() {
        memory.addFile("/A/docs/in.txt")
        memory.addFile("/B/other.txt")
        bench = TestBench(
            plugins: [NavigationPlugin(pasteboard: scratch.pasteboard, home: memory.url("/home"))],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
    }

    /// Going to the next volume asks the disks in a job.
    @Test
    internal func goingToANeighbourVolumeAsksTheDisksInAJob() {
        bench.commands.perform("cm_GoToNextDrive")
        #expect(bench.jobService.titles == ["Go to volume"])
        #expect(bench.left.model.directory == memory.url("/"))
    }

    /// Whether the clipboard holds a path is asked again only when its change count changed.
    @Test
    internal func theClipboardIsAskedOnlyWhenItsChangeCountChanged() {
        pasteboard.clearContents()
        #expect(!bench.commands.isEnabled("afm_CdFromClipboard"))
        // Without a change the answer stays, whatever the menus ask.
        for _ in 0..<5 { #expect(!bench.commands.isEnabled("afm_CdFromClipboard")) }
        pasteboard.setString("/x", forType: .string)
        #expect(bench.commands.isEnabled("afm_CdFromClipboard"))
        pasteboard.clearContents()
        #expect(!bench.commands.isEnabled("afm_CdFromClipboard"))
    }
}
