import AFMContracts
import AFMKernel
import AppKit

/// The commands of the plugin: what F4, Open With, Reveal in Finder, Share, Finder Tags and Copy as
/// Pathname do, registered with the kernel while the plugin starts (main thread).
extension MacIntegrationPlugin {
    /// The general opener, F4 and the editor of F4 (spec 10 › Editor and parameters).
    internal func registerEditCommands(_ source: SourcePanel) {
        let commands = source.kernel.commands
        // The general opener: any local file goes to its application. Plugins that understand
        // particular files (archives) add openers with a higher priority.
        source.kernel.openers.add(priority: 0) { [self] file, _ in
            guard file.url.isFileURL else {
                return false
            }
            open([file.url], with: nil)
            return true
        }
        // F4 starts the editor the user chose.
        commands.register(
            Command(.edit, "Edit", [.f(4)], barLabel: "Edit", runsDuringJobs: true),
            enabled: { source.cursorFile != nil },
            parameterized: { [self] argument in
                guard let url = argument.location ?? source.cursorFile, url.isFileURL else {
                    return
                }
                let editor = source.kernel.settings.text(Self.editorKey, default: Self.defaultEditor)
                remember(opened: [url])
                remember("edit \(DisplayText.oneLine(editor, limit: 200)) \(url.path)")
                guard let desktop else {
                    return
                }
                // (The system looks at the file and the application: on a thread of the kernel's own.)
                BlockingCalls.run { desktop.open([url], with: Self.editorApplication(named: editor)) }
            }
        )
        // `.text`: the editor's name, path or bundle identifier; `.location`: the application;
        // without, the user picks it.
        commands.register(
            Command(Self.chooseEditor, "Choose Editor for F4…", runsDuringJobs: true)
        ) { [self] (argument: CommandArgument) in
            guard
                let editor = argument.text ?? argument.location?.path
                    ?? chooseApplication(title: "Choose the editor for F4")?.path
            else { return }
            source.kernel.settings.set(editor, forKey: Self.editorKey)
        }
    }

    /// Opening with the default application or another, and showing in Finder.
    internal func registerOpenCommands(_ source: SourcePanel) {
        let commands = source.kernel.commands
        commands.register(
            Command(Self.openWithDefault, "Open with Default Application", runsDuringJobs: true),
            enabled: { source.cursorItem != nil },
            { [self] in
                // Offered only on a local item.
                _ = source.cursorItem.map { url in
                    remember("open \(url.path)")
                    open([url], with: nil)
                }
            }
        )
        commands.register(
            Command(Self.openWith, "Open With…", runsDuringJobs: true),
            enabled: { source.cursorItem != nil },
            { [self] in
                // Offered only on a local item.
                _ = source.cursorItem.map { url in openWith(url, in: source.kernel) }
            }
        )
        commands.register(
            Command(.revealInFinder, "Reveal in Finder", [.cmd("r", .shift)], runsDuringJobs: true),
            enabled: { source.model.directory.isFileURL },
            { [self] in
                let directory = source.model.directory
                let system = desktop
                // Finder is shown the first items of a very large selection; it could not show more.
                withLocalOperands(
                    of: source.model,
                    { Array($0.prefix(Self.revealLimit)) },
                    then: { [self] urls in
                        // Without operands, the folder itself.
                        let shown = urls.isEmpty ? [directory] : urls
                        remember("reveal " + Self.described(shown))
                        guard let system else {
                            return
                        }
                        // Finder is asked away from the main thread: it looks at every file it is to select.
                        BlockingCalls.run { system.reveal(shown) }
                    }
                )
            }
        )
    }

    /// Sharing, Finder tags and copying the paths.
    internal func registerShareCommands(_ source: SourcePanel) {
        let commands = source.kernel.commands
        commands.register(
            Command(Self.share, "Share…", runsDuringJobs: true),
            enabled: { source.hasLocalOperands },
            { [self] in
                // Weak: with many items the list comes later, when the plugin may have gone; while it
                // is there, so is the kernel.
                withLocalOperands(
                    of: source.model,
                    { $0 },
                    then: { [weak self] urls in self?.share(urls, in: source.kernel) }
                )
            }
        )
        commands.register(
            Command(Self.editTags, "Finder Tags…"),
            enabled: { source.hasLocalOperands },
            { [self] in
                withLocalOperands(
                    of: source.model,
                    { $0 },
                    then: { [weak self] urls in self?.editTags(of: urls, in: source.kernel) }
                )
            }
        )
        commands.register(
            Command(
                Self.copyAsPathname,
                "Copy as Pathname",
                [Shortcut(.character("c"), [.command, .option])],
                runsDuringJobs: true
            ),
            enabled: { source.model.directory.isFileURL },
            { [self] in
                let directory = source.model.directory
                // The paths of a large selection are put together off the main thread.
                withLocalOperands(
                    of: source.model,
                    { urls in (urls.isEmpty ? [directory] : urls).map(\.path).joined(separator: "\n") },
                    then: { [self] text in
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                    }
                )
            }
        )
    }
}
