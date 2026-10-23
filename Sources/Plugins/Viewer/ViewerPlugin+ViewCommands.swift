import AFMContracts
import AFMKernel
import Foundation

/// The commands that open Lister windows on files of the source panel.
extension ViewerPlugin {
    /// Registers the commands that open Lister windows: View (F3) and its variants (`start(in:)` does).
    internal func registerViewCommands(_ owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let cursorFile = { model().cursorItem.flatMap { $0.isDirectory ? nil : $0.url } }
        // The marked files, or without any the file under the cursor (spec 10 › Keys and commands).
        let markedFiles = { model().operands().filter { !$0.isDirectory }.map(\.url) }
        // The toolbar asks `enabled` ten times a second, so it must not resolve the operands
        // (an O(n) pass with items marked); `canView` is a cheap test, `files` runs with the command.
        func viewer(
            _ id: CommandID,
            _ title: String,
            _ shortcuts: [Shortcut],
            barLabel: String? = nil,
            internalOnly: Bool = false,
            canView: (() -> Bool)? = nil,
            files: @escaping () -> [URL]
        ) {
            commands.register(
                Command(id, title, shortcuts, barLabel: barLabel, runsDuringJobs: true),
                enabled: { canView?() ?? !files().isEmpty },
                parameterized: { [weak self] argument in
                    // Not empty: the command is enabled only when there are files.
                    let urls = argument.location.map { [$0] } ?? files()
                    self?
                        .open(
                            urls.map { ViewerItem(source: .file($0), title: kernel.fileSystems.displayPath($0)) },
                            internalOnly: internalOnly,
                            followsCursor: false
                        )
                }
            )
        }
        // Something marked must be a file, or without marks the cursor must be on one (the list of
        // files is made when the command runs).
        let canView = { model().hasOperandFile }
        viewer(.view, "View", [.f(3)], barLabel: "View", canView: canView, files: markedFiles)
        viewer(.viewSingle, "View File Under Cursor", [.f(3, .shift)]) { cursorFile().map { [$0] } ?? [] }
        viewer(.viewMarked, "View Marked Files", [], canView: canView, files: markedFiles)
        viewer(.viewInternalSingle, "View as Text Only", [.f(3, [.option, .shift])], internalOnly: true) {
            cursorFile().map { [$0] } ?? []
        }
        viewer(
            .viewInternalMarked,
            "View Marked Files as Text Only",
            [],
            internalOnly: true,
            canView: canView,
            files: markedFiles
        )
    }
}
