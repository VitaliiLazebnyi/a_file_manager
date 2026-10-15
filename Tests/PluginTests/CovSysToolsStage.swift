import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport

@testable import SystemToolsPlugin

/// The files and the recording desktop the system tools are tested with: a sandbox with `A/one.txt`, `A/two.txt`,
/// the application folder `A/Tool.app` and the folder `B`, and a memory folder `/M` with `memo.txt`.
@MainActor
internal struct CovSysToolsStage {
    /// The folders on the disk.
    internal let box: Sandbox
    /// The folder in memory.
    internal let memory = MemoryFileSystem()
    /// The desktop that records.
    internal let recorder = CovSysToolsDesktop()

    /// The home folder as the disk writes it.
    internal var home: String {
        FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
    }

    /// Makes the files; throws when the disk refuses.
    internal init() throws {
        box = try Sandbox()
        try box.file("A/one.txt", "1")
        try box.file("A/two.txt", "2")
        try box.folder("A/Tool.app")
        try box.folder("B")
        memory.addFile("/M/memo.txt", "m")
    }

    /// The text of the multi-line field of the form shown last.
    internal static func shownText(_ interaction: ScriptedInteraction) -> String? {
        for field in interaction.forms.last ?? [] {
            if case .multilineText(let text) = field.kind {
                return text
            }
        }
        return nil
    }

    /// A bench with the tools on `desktop` and jobs that run at once, `A` on the left and `B` on the right.
    internal func bench(_ desktop: ToolsDesktop) -> (TestBench, SystemToolsPlugin) {
        let tools = SystemToolsPlugin(desktop: desktop)
        let bench = TestBench(
            plugins: [tools],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: box.url("B")
        )
        return (bench, tools)
    }

    /// A bench with the tools on the recorder's desktop, whose jobs run as `jobs` says.
    internal func bench(_ jobs: CoverageSmallJobs.Mode) -> (CoverageSmallBench, SystemToolsPlugin) {
        let tools = SystemToolsPlugin(desktop: recorder.desktop())
        let bench = CoverageSmallBench(
            jobs,
            plugins: [tools],
            fileSystems: [LocalFileSystem(), memory],
            left: box.url("A"),
            right: box.url("B")
        )
        return (bench, tools)
    }
}
