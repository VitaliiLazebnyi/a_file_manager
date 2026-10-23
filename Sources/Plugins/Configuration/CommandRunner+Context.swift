import AFMContracts
import AFMKernel
import Foundation

/// What the placeholders and the names of a Command field are read against.
extension CommandRunner {
    /// A panel as the placeholders see it, and, when its marked names are many, how to gather
    /// them away from the main thread.
    private func snapshot(of panel: any PanelHandle, withSelection: Bool) -> (
        snapshot: PanelSnapshot, gather: (@Sendable () -> [String])?
    ) {
        let model = panel.model
        // A branch view or a file list shows real files under display paths and relative
        // names; its items are given by their real paths, and the panel has no path of its own.
        let showsFiles = !model.directory.isFileURL && model.items.first?.url.isFileURL == true
        @Sendable
        func name(of item: FileItem) -> String {
            showsFiles && item.url.isFileURL ? item.url.path : item.name
        }
        var path =
            showsFiles
            ? "" : model.directory.isFileURL ? model.directory.path : kernel.fileSystems.displayPath(model.directory)
        if !path.isEmpty, !path.hasSuffix("/") { path += "/" }
        var snapshot = PanelSnapshot(path: path, cursorName: model.cursorItem.map(name(of:)))
        let count = model.selectionCount
        // The marked names cost a pass over the marks: only a text that asks for them gets them.
        guard withSelection, count > 0 else {
            return (snapshot, nil)
        }
        // The marks and the list are taken as they are (nothing is copied); the marked items,
        // which are exactly those, are picked out here for a few and away from the main thread for many.
        let operands = model.operandsSnapshot()
        guard background != nil, count >= Self.backgroundSelectionThreshold else {
            snapshot.selection = operands.markedItems().map(name(of:))
            return (snapshot, nil)
        }
        return (snapshot, { operands.markedItems().map(name(of:)) })
    }

    /// Replaces the placeholders of `template`.
    ///
    /// With many marked names the work is done away from the main thread; `completion` is called on
    /// it either way.
    internal func expand(
        _ template: [ExpandedPiece],
        arguments: [ExpandedPiece],
        then completion: @escaping @MainActor @Sendable (ExpandedParameters) -> Void
    ) {
        let panels = kernel.panels
        let needsSelection = ParameterExpander.usesSelection(template)
        let left = snapshot(of: panels.left, withSelection: needsSelection)
        let right = snapshot(of: panels.right, withSelection: needsSelection)
        var context = ExpansionContext(
            left: left.snapshot,
            right: right.snapshot,
            sourceIsRight: panels.source === panels.right,
            environment: environment,
            arguments: ShellLine.display(arguments),
            listFolder: listFolder
        )
        context.argumentPieces = arguments
        guard left.gather != nil || right.gather != nil else {
            completion(ParameterExpander(context: context).expand(template))
            return
        }
        let prepared = context
        offMain(
            {
                var gathered = prepared
                if let gather = left.gather { gathered.left.selection = gather() }
                if let gather = right.gather { gathered.right.selection = gather() }
                return ParameterExpander(context: gathered).expand(template)
            },
            then: completion
        )
    }

    /// A location written in a command, relative to the folder of the active panel.
    internal func location(_ text: String) -> URL {
        kernel.fileSystems.location(from: text, relativeTo: kernel.panels.source.model.directory)
    }

    /// A registered command by its name in any case (spec 14 › Rules: names are case-insensitive).
    internal func resolve(_ name: String) -> CommandID? {
        let lowered = name.lowercased()
        return kernel.commands.all.first { $0.id.rawValue.lowercased() == lowered }?.id
    }
}
