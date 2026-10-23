import AFMContracts
import AFMKernel
import Foundation

/// Names, paths and the details lines of the operands as text, to the clipboard and to a file.
extension ClipboardPlugin {
    /// One of the commands that copy the details lines of the operands.
    private struct DetailCommand {
        let id: CommandID
        let title: String
        let style: NameList.Style
        let headers: Bool

        init(_ id: CommandID, _ title: String, _ style: NameList.Style, headers: Bool) {
            self.id = id
            self.title = title
            self.style = style
            self.headers = headers
        }
    }

    /// A name list that writes locations as the kernel's file systems do.
    private static func nameList(in kernel: Kernel) -> NameList {
        let fileSystems = kernel.fileSystems
        return NameList { url in fileSystems.displayPath(url) }
    }

    /// Puts the commands into the menus, the context menu and the toolbar, and the Clipboard
    /// page into the preferences.
    internal static func addToMenus(_ kernel: Kernel) {
        kernel.menus.add([.cutToClipboard, .copyToClipboard, .pasteFromClipboard], to: .editClipboard)
        kernel.menus.add(
            [
                ClipboardCommands.copyNames, .copyFullNames, ClipboardCommands.copyNetNames,
                ClipboardCommands.copyDetails,
                ClipboardCommands.copyDetailsWithPath, ClipboardCommands.copyDetailsWithHeaders
            ],
            to: .editNames
        )
        kernel.menus.add(
            [ClipboardCommands.copySourcePath, ClipboardCommands.copyTargetPath, ClipboardCommands.saveDetails],
            to: MenuSection(.edit, order: 30)
        )
        kernel.menus.addToContextMenu([.cutToClipboard, .copyToClipboard], in: .clipboard, onItemOnly: true)
        kernel.menus.addToContextMenu([.pasteFromClipboard], in: .clipboard)
        kernel.menus.addToContextMenu([.copyFullNames], in: .tools)
        kernel.menus.addToContextMenu([ClipboardCommands.copyNames], in: .tools, onItemOnly: true)

        kernel.toolbar.setSymbol("scissors", for: .cutToClipboard)
        kernel.toolbar.setSymbol("doc.on.doc", for: .copyToClipboard)
        kernel.toolbar.setSymbol("doc.on.clipboard", for: .pasteFromClipboard)
        kernel.toolbar.setSymbol("list.clipboard", for: .copyFullNames)
        kernel.preferences.add(
            PreferencePage(
                title: "Clipboard",
                preferences: [
                    Preference(
                        Self.pastesContentsKey,
                        "Paste a text or picture from the clipboard as a new file",
                        .flag(default: true)
                    )
                ]
            )
        )
    }

    /// Names, paths and URLs as text.
    ///
    /// They change nothing, so they also work while a job runs.
    internal func registerNameCommands(in owner: Kernel, _ conditions: Conditions) {
        unowned let kernel = owner
        let (model, hasOperands) = (conditions.model, conditions.hasOperands)
        let list = Self.nameList(in: kernel)
        let displayPath = list.displayPath

        // `text` makes the text from the operands; it may run off the main thread.
        func names(
            _ id: CommandID,
            _ title: String,
            _ shortcuts: [Shortcut],
            enabled: @escaping () -> Bool,
            _ text: @escaping @Sendable ([FileItem], URL) -> String
        ) {
            kernel.commands.register(Command(id, title, shortcuts, runsDuringJobs: true), enabled: enabled) { [self] in
                // The list of the operands is made where the text is: for a long selection
                // that is not the main thread.
                let (operands, directory) = (model().operandsSnapshot(), model().directory)
                texts.putText(for: Self.count(of: operands)) { text(operands.items(), directory) }
            }
        }
        names(ClipboardCommands.copyNames, "Copy Names", [], enabled: hasOperands) { items, _ in
            list.names(items, .name)
        }
        let always = { true }
        names(.copyFullNames, "Copy Names with Path", [.cmd("c", .shift)], enabled: always) { items, directory in
            // On `[..]` with nothing selected there is no item: the folder itself is meant.
            items.isEmpty ? displayPath(directory) : list.names(items, .fullPath)
        }
        names(ClipboardCommands.copyNetNames, "Copy Names as URLs", [], enabled: hasOperands) { items, _ in
            list.names(items, .url)
        }
        names(ClipboardCommands.copyPathOfFiles, "Copy Path of Each File", [], enabled: hasOperands) { items, _ in
            list.parentPaths(items)
        }
        kernel.commands.register(
            Command(ClipboardCommands.copySourcePath, "Copy Source Path", runsDuringJobs: true)
        ) { [self] in
            texts.put(displayPath(model().directory))
        }
        kernel.commands.register(
            Command(ClipboardCommands.copyTargetPath, "Copy Target Path", runsDuringJobs: true)
        ) { [self] in
            texts.put(displayPath(kernel.panels.target.model.directory))
        }
    }

    /// The details lines, to the clipboard and to a file.
    internal func registerDetailCommands(in owner: Kernel, _ conditions: Conditions) {
        unowned let kernel = owner
        let (hasOperands, isWritable) = (conditions.hasOperands, conditions.isWritable)
        let detailCommands = [
            DetailCommand(ClipboardCommands.copyDetails, "Copy with All Details", .name, headers: false),
            DetailCommand(
                ClipboardCommands.copyDetailsWithPath,
                "Copy with Path and Details",
                .fullPath,
                headers: false
            ),
            DetailCommand(ClipboardCommands.copyDetailsWithURL, "Copy with URL and Details", .url, headers: false),
            DetailCommand(
                ClipboardCommands.copyDetailsWithHeaders,
                "Copy with Details and Headers",
                .name,
                headers: true
            ),
            DetailCommand(
                ClipboardCommands.copyDetailsWithHeadersAndPath,
                "Copy with Path, Details and Headers",
                .fullPath,
                headers: true
            ),
            DetailCommand(
                ClipboardCommands.copyDetailsWithHeadersAndURL,
                "Copy with URL, Details and Headers",
                .url,
                headers: true
            )
        ]
        for command in detailCommands {
            kernel.commands.register(Command(command.id, command.title), enabled: hasOperands) { [self] argument in
                details(command.style, headers: command.headers, mask: argument.index, in: kernel) { [self] text in
                    texts.put(text)
                }
            }
        }
        for (id, title, headers) in [
            (ClipboardCommands.saveDetails, "Save Details to File…", false),
            (ClipboardCommands.saveDetailsWithHeaders, "Save Details with Headers to File…", true)
        ] {
            kernel.commands.register(
                Command(id, title),
                enabled: { hasOperands() && isWritable() },
                parameterized: { [self] argument in saveDetails(headers: headers, to: argument.text, in: kernel) }
            )
        }
    }

    /// Works out the details lines of the operands in a job, because the plugin columns the
    /// panel shows may block on the file system, and hands the text over on the main thread.
    private func details(
        _ style: NameList.Style,
        headers: Bool,
        mask: Int?,
        in kernel: Kernel,
        then completion: @escaping @MainActor (String) -> Void
    ) {
        let (operands, extra) = detailsInput(in: kernel)
        let list = Self.nameList(in: kernel)
        kernel.jobs.run(
            title: "Reading details:",
            work: { _ in
                list.details(operands.items(), style, headers: headers, extra: extra, mask: mask)
            },
            completion: completion
        )
    }

    /// The operands and the plugin columns the source panel shows, read on the main thread.
    private func detailsInput(in kernel: Kernel) -> (operands: PanelModel.Operands, extra: [NameList.Column]) {
        let panel = kernel.panels.source
        let shown = panel.viewMode == .full ? panel.extraColumns.compactMap { kernel.columns[$0] } : []
        return (panel.model.operandsSnapshot(), shown.map { NameList.Column(title: $0.title, value: $0.value) })
    }

    /// Writes the details lines to a file through its file system (spec 03 › Selection files,
    /// `cm_SaveDetailsToFile`); without `proposed`, the name is asked for.
    ///
    /// An existing file is replaced only after a question.
    private func saveDetails(headers: Bool, to proposed: String?, in kernel: Kernel) {
        let directory = kernel.panels.source.model.directory
        guard let text = proposed ?? kernel.interaction.prompt("Save details to file:", value: "details.txt"),
            !text.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return
        }
        let (operands, extra) = detailsInput(in: kernel)
        DetailsFile(
            url: kernel.fileSystems.location(from: text, relativeTo: directory),
            operands: operands,
            extra: extra,
            headers: headers,
            list: Self.nameList(in: kernel)
        )
        .save(in: kernel)
    }
}
