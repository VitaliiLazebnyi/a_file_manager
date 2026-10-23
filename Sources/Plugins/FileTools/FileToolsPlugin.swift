import AFMContracts
public import AFMKernel
public import AppKit

/// Split, combine, encode, decode and checksums (spec 08).
public final class FileToolsPlugin: Plugin {
    /// The plugin's name in the kernel's list of plugins.
    public let name = "FileTools"
    /// Where Verify looks for a checksum; nil for the general pasteboard.
    private let pasteboard: NSPasteboard?

    /// `pasteboard` is where Verify looks for a checksum; by default the general pasteboard.
    public init(pasteboard: NSPasteboard? = nil) {
        self.pasteboard = pasteboard
    }

    /// The page of the plugin's settings in the preferences window.
    private static func preferencePage() -> PreferencePage {
        PreferencePage(
            title: "File Tools",
            preferences: [
                Preference(
                    FileTools.Keys.onlyErrors,
                    "Verify checksums: show only the errors",
                    .flag(default: false)
                ),
                Preference(
                    FileTools.Keys.appendExtension,
                    "Separate checksum files: add the extension to the file's name (off: replace its extension)",
                    .flag(default: true)
                ),
                Preference(
                    FileTools.Keys.extraTypes,
                    "More masks for checksum files (e.g. *.sum *.crc32)",
                    .text(default: "")
                )
            ]
        )
    }

    /// Registers the six commands with their menu items, toolbar buttons and preference page.
    ///
    /// Called once on the main thread when the kernel loads the plugin.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let tools = FileTools(kernel, pasteboard: pasteboard ?? .general)
        let source = { kernel.panels.source.model }
        let onFile = { source().cursorItem.map { item in !item.isDirectory } ?? false }
        let hasOperands = { source().hasOperands }
        let commands = kernel.commands
        // The four take the file under the cursor; they are offered only on a file.
        let file = { source().cursorItem }
        commands.register(Command(.splitFile, "Split File…"), enabled: onFile) { _ = file().map(tools.split) }
        commands.register(Command(.combineFiles, "Combine Files…"), enabled: onFile) { _ = file().map(tools.combine) }
        commands.register(Command(.encodeFile, "Encode File (MIME, UUE, XXE)…"), enabled: onFile) {
            _ = file().map(tools.encode)
        }
        commands.register(Command(.decodeFile, "Decode File (MIME, UUE, XXE, yEnc)…"), enabled: onFile) {
            _ = file().map(tools.decode)
        }
        commands.register(
            Command(.createChecksums, "Create Checksum File(s) (CRC32, MD5, SHA)…"),
            enabled: hasOperands,
            tools.createChecksums
        )
        commands.register(Command(.verifyChecksums, "Verify Checksums"), enabled: hasOperands, tools.verifyChecksums)
        kernel.menus.add(
            [.splitFile, .combineFiles, .encodeFile, .decodeFile, .createChecksums, .verifyChecksums],
            to: .filesTransform
        )
        kernel.menus.addToContextMenu([.createChecksums, .verifyChecksums], in: .tools, onItemOnly: true)
        kernel.toolbar.add(
            .createChecksums,
            symbol: "number.square",
            group: 60,
            hint: "Create checksum files (MD5, SHA and others) for the selected files."
        )
        kernel.toolbar.add(
            .verifyChecksums,
            symbol: "checkmark.seal",
            group: 60,
            hint: "Check the selected files against their checksum file, to find damaged copies."
        )
        kernel.toolbar.setSymbol("scissors", for: .splitFile)
        kernel.toolbar.setSymbol("link", for: .combineFiles)
        kernel.preferences.add(Self.preferencePage())
    }

    deinit {
        // Nothing to release.
    }
}
