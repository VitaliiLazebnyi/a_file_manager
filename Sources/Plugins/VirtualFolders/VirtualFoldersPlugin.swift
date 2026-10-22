public import AFMContracts
public import AFMKernel
public import Foundation

extension CommandID {
    /// Branch view of the selected folders only (spec 03 › Selected branch).
    internal static let branchViewSelected: CommandID = "cm_DirBranchSel"
    internal static let leftBranchView: CommandID = "cm_LeftDirBranch"
    internal static let rightBranchView: CommandID = "cm_RightDirBranch"
    internal static let leftBranchViewSelected: CommandID = "cm_LeftDirBranchSel"
    internal static let rightBranchViewSelected: CommandID = "cm_RightDirBranchSel"
    /// `.location` or `.text`: a text file with one path per line, shown like a search result
    /// (spec 09 › Feed to listbox, `LOADLIST`); without, the user is asked for the file.
    internal static let loadFileList: CommandID = "LOADLIST"
}

/// Branch view and file lists shown as folders (spec 03 › Branch view, 09 › Feed to listbox).
///
/// The plugin provides the `vfolder:` file system, the commands that put a panel into branch
/// view and take it out again, and `FileListService` for plugins that have a list of files to
/// show (Find Files). Commands and the service are used on the main thread; reading happens in
/// the file system, on the panel's background threads.
public final class VirtualFoldersPlugin: Plugin, FileListService {
    internal static let listsFoldersKey = "virtualFolders.listsFolders"
    internal static let entersPackagesKey = "virtualFolders.entersPackages"

    public let name = "VirtualFolders"

    /// The file system this plugin provides; nil until the plugin has started.
    public private(set) var fileSystem: VirtualFileSystem?

    public init() {}

    /// Hands the user's options to the file system, which reads them on background threads.
    private static func applyOptions(_ settings: any SettingsStore, to fileSystem: VirtualFileSystem) {
        fileSystem.options = VirtualFileSystem.Options(
            listsFolders: settings.flag(listsFoldersKey, default: false),
            entersPackages: settings.flag(entersPackagesKey, default: false)
        )
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let fileSystem = VirtualFileSystem(fileSystems: kernel.fileSystems)
        self.fileSystem = fileSystem
        kernel.fileSystems.register(fileSystem)
        kernel.services.register((any FileListService).self, self)
        Self.applyOptions(kernel.settings, to: fileSystem)

        let commands = kernel.commands
        let source = { kernel.panels.source }
        let isVirtual = { (panel: (any PanelHandle)) in VirtualLocation(panel.model.directory) != nil }
        let isBranch = { (panel: (any PanelHandle)) -> Bool in
            switch VirtualLocation(panel.model.directory) {
            case .branch, .picked:
                return true

            default:
                return false
            }
        }

        commands.register(
            Command(.branchView, "Branch View (With Subdirs)", [Shortcut(.character("b"), .control)]),
            checked: { isBranch(source()) },
            parameterized: { [self] in
                setBranchView($0, in: source(), selectedOnly: false, kernel: kernel, fileSystem: fileSystem)
            }
        )
        commands.register(
            Command(
                .branchViewSelected,
                "Branch View of Selected Folders",
                [Shortcut(.character("b"), [.control, .shift])]
            ),
            enabled: { isVirtual(source()) || source().model.hasOperands },
            parameterized: { [self] in
                setBranchView($0, in: source(), selectedOnly: true, kernel: kernel, fileSystem: fileSystem)
            }
        )
        let sided: [(CommandID, String, Bool, Bool)] = [
            (.leftBranchView, "Left: Branch View", true, false),
            (.rightBranchView, "Right: Branch View", false, false),
            (.leftBranchViewSelected, "Left: Branch View of Selected Folders", true, true),
            (.rightBranchViewSelected, "Right: Branch View of Selected Folders", false, true)
        ]
        for (id, title, isLeft, selectedOnly) in sided {
            let panel = { isLeft ? kernel.panels.left : kernel.panels.right }
            commands.register(
                Command(id, title),
                checked: { isBranch(panel()) },
                parameterized: { [self] in
                    setBranchView($0, in: panel(), selectedOnly: selectedOnly, kernel: kernel, fileSystem: fileSystem)
                }
            )
        }
        commands.register(
            Command(.loadFileList, "Load File List into Panel…"),
            parameterized: { [self] in loadList($0, kernel: kernel) }
        )

        kernel.menus.add([.branchView, .branchViewSelected], to: .commandsPlaces)
        kernel.toolbar.add(
            .branchView,
            symbol: "list.bullet.indent",
            group: 30,
            hint: "Show the files of this folder and of all its subfolders in one list."
        )
        kernel.toolbar.setSymbol("list.bullet.rectangle", for: .loadFileList)
        kernel.preferences.add(
            PreferencePage(
                title: "Branch View",
                preferences: [
                    Preference(
                        Self.listsFoldersKey,
                        "List the folders too, not only the files in them",
                        .flag(default: false)
                    ),
                    Preference(
                        Self.entersPackagesKey,
                        "Show the contents of packages (applications, bundles)",
                        .flag(default: false)
                    )
                ],
                onChange: {
                    Self.applyOptions(kernel.settings, to: fileSystem)
                    for panel in kernel.panels.all where isVirtual(panel) { panel.reload() }
                }
            )
        )
    }

    // MARK: FileListService

    /// Shows `files` in `panel`. `[..]` leads back to the real directory the panel showed.
    public func show(_ files: [URL], title: String, in panel: any PanelHandle) {
        show(files, title: title, in: panel, isUnique: false)
    }

    /// With `isUnique` the list is not looked through for doubles (see `register(files:…isUnique:)`).
    public func show(_ files: [URL], title: String, in panel: any PanelHandle, isUnique: Bool) {
        guard let fileSystem else {
            return
        }
        let directory = panel.model.directory
        let origin = VirtualLocation(directory).map(\.realDirectory) ?? directory
        panel.show(fileSystem.register(files: files, title: title, origin: origin, isUnique: isUnique))
    }

    // MARK: Branch view

    /// The commands take the specification's tri-state parameter (17 › Command parameters):
    /// none or 0 toggles, 1 switches on, 2 or -1 off.
    private func setBranchView(
        _ argument: CommandArgument,
        in panel: any PanelHandle,
        selectedOnly: Bool,
        kernel: Kernel,
        fileSystem: VirtualFileSystem
    ) {
        let location = VirtualLocation(panel.model.directory)
        let isOn = location != nil
        let wanted: Bool
        switch argument.index ?? argument.text.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) ?? 0 {
        case 1:
            wanted = true

        case 2, -1:
            wanted = false

        default:
            wanted = !isOn
        }
        guard wanted != isOn else {
            return
        }
        if let location {
            leave(panel, location, kernel: kernel, fileSystem: fileSystem)
        } else {
            enter(panel, selectedOnly: selectedOnly, fileSystem: fileSystem)
        }
    }

    private func enter(_ panel: any PanelHandle, selectedOnly: Bool, fileSystem: VirtualFileSystem) {
        let model = panel.model
        if selectedOnly {
            let items = model.operands()
            guard !items.isEmpty else {
                return
            }
            panel.show(fileSystem.registerPicked(items.map(\.url), in: model.directory))
        } else {
            panel.show(fileSystem.branch(of: model.directory))
        }
    }

    /// Leaves the view for the real folder of the item under the cursor, with the cursor on
    /// it (spec 03 › Branch view, "Leaving with Ctrl+B").
    ///
    /// On `[..]` the panel goes back to the directory the view was made from; after a selected
    /// branch, the items it was made from are selected again.
    private func leave(
        _ panel: any PanelHandle,
        _ location: VirtualLocation,
        kernel: Kernel,
        fileSystem: VirtualFileSystem
    ) {
        let tab = panel.model
        if let item = tab.cursorItem,
            let folder = (try? kernel.fileSystems.provider(for: item.url))?.parent(of: item.url)
        {
            panel.show(folder, focus: item.url.lastPathComponent)
            return
        }
        guard let directory = location.realDirectory else {
            kernel.commands.onRejected()
            return
        }
        func show(selecting names: [String]) {
            panel.show(directory, focus: names.last, history: .record) { worked in
                guard worked, tab.directory.isSameLocation(as: directory) else {
                    return
                }
                tab.setSelected(true, names: names)
            }
        }
        guard case .picked = location else {
            show(selecting: [])
            return
        }
        // The names of what the view was made from are taken in the background: there may be
        // hundreds of thousands.
        let virtual = tab.directory
        kernel.jobs.run(
            title: "Leave selected branch",
            work: { _ in
                (fileSystem.entries(of: virtual) ?? []).map(\.lastPathComponent)
            },
            completion: { names in show(selecting: names) }
        )
    }

    // MARK: Lists from files

    private func loadList(_ argument: CommandArgument, kernel: Kernel) {
        let panel = kernel.panels.source
        let base = VirtualLocation(panel.model.directory).map(\.realDirectory) ?? panel.model.directory
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let typed =
            argument.text
            ?? (argument.location == nil ? kernel.interaction.prompt("Load the list of files from:", value: "") : nil)
        guard
            let file = argument.location
                ?? typed.map({ kernel.fileSystems.location(from: $0, relativeTo: base ?? home) })
        else { return }
        let fileSystems = kernel.fileSystems
        // The list file is read in the background; a job keeps other commands away meanwhile.
        kernel.jobs.run(
            title: "Load file list",
            work: { _ in
                Result { try FileListFile.read(file, fileSystems: fileSystems, relativeTo: base ?? home) }
            },
            completion: { [self] result in
                switch result {
                case .success(let files):
                    show(files, title: FileItem.split(file.lastPathComponent).base, in: panel)

                case .failure(let error):
                    kernel.interaction.report(error, title: "The list of files could not be loaded.")
                }
            }
        )
    }
}

/// A text file that names one file per line (spec 19 › List files).
///
/// Lines are full paths or paths relative to a base directory; empty lines are skipped.
///
/// A name that holds a line break or another control character, or starts or ends with a
/// space or a quote, cannot stand on a line as it is. It is written in quotes with backslash
/// escapes (`"a\nb"`: `\\`, `\"`, `\n`, `\r`, `\t` and `\u{XXXX}`), and a quoted line is read
/// back that way. Every other line is read as it stands, so list files made without quoting
/// (and names with backslashes in them) keep their meaning.
public enum FileListFile {
    public struct TooLarge: LocalizedError {
        public var errorDescription: String? { "The list of files is too large to load." }
    }

    /// The most a list file may hold (bytes) and name (lines): more is not a list a person made.
    public static let sizeLimit = 16 << 20
    public static let lineLimit = 1_000_000

    /// The lines of a list file.
    ///
    /// UTF-8 with or without a byte-order mark and UTF-16 with one are read; line ends may be LF or
    /// CRLF.
    public static func lines(in data: Data) -> [String] {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text =
                String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        }
        return (text ?? "").split(whereSeparator: \.isNewline)
            .compactMap { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    return nil
                }
                return unquoted(line) ?? line
            }
    }

    /// The name a quoted line stands for; nil when the line is not quoted, or holds an escape
    /// that is none of ours (then it is an old, unquoted line).
    internal static func unquoted(_ line: String) -> String? {
        guard line.unicodeScalars.count >= 2, line.unicodeScalars.first == "\"", line.unicodeScalars.last == "\"" else {
            return nil
        }
        let body = Array(line.unicodeScalars.dropFirst().dropLast())
        var result = String.UnicodeScalarView()
        var index = 0
        while index < body.count {
            let scalar = body[index]
            index += 1
            guard scalar == "\\" else {
                // An unescaped quote inside means the line is no quoted name.
                if scalar == "\"" {
                    return nil
                }
                result.append(scalar)
                continue
            }
            guard index < body.count else {
                return nil
            }
            let escape = body[index]
            index += 1
            switch escape {
            case "\\", "\"":
                result.append(escape)

            case "n":
                result.append("\n")

            case "r":
                result.append("\r")

            case "t":
                result.append("\t")

            case "u":
                guard index < body.count, body[index] == "{", let close = body[index...].firstIndex(of: "}") else {
                    return nil
                }
                let digits = String(String.UnicodeScalarView(body[(index + 1)..<close]))
                guard !digits.isEmpty, digits.count <= 6, let value = UInt32(digits, radix: 16),
                    let unicode = Unicode.Scalar(value)
                else { return nil }
                result.append(unicode)
                index = close + 1

            default:
                return nil
            }
        }
        return String(result)
    }

    /// One line for a name: as it is when that reads back the same, otherwise quoted.
    public static func line(for name: String) -> String {
        let scalars = name.unicodeScalars
        let needsQuotes =
            scalars.first == "\"" || scalars.contains { isUnsafe($0) }
            || scalars.first.map({ $0.properties.isWhitespace }) == true
            || scalars.last.map({ $0.properties.isWhitespace }) == true
        guard needsQuotes else {
            return name
        }
        var text = "\""
        for scalar in scalars {
            switch scalar {
            case "\\":
                text += "\\\\"

            case "\"":
                text += "\\\""

            case "\n":
                text += "\\n"

            case "\r":
                text += "\\r"

            case "\t":
                text += "\\t"

            default:
                if isUnsafe(scalar) {
                    text += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        return text + "\""
    }

    /// The text of a list file naming `names`, one per line.
    public static func text(for names: [String]) -> String {
        names.map(line(for:)).joined(separator: "\n") + (names.isEmpty ? "" : "\n")
    }

    /// A scalar that cannot stand in a line as it is: a control character or a line or
    /// paragraph break.
    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            return true

        default:
            return false
        }
    }

    /// Reads a list file from any file system.
    ///
    /// Blocks: for a background thread. Only files of this computer and of the file system the list
    /// file is on are taken over from it: a list file must not make the program connect to any host
    /// it names.
    public static func read(_ file: URL, fileSystems: FileSystemRegistry, relativeTo base: URL) throws -> [URL] {
        let reader = try fileSystems.provider(for: file).read(file)
        defer { reader.close() }
        var data = Data()
        while let block = try reader.read(upToCount: 1 << 20), !block.isEmpty {
            data.append(block)
            if data.count > sizeLimit { throw TooLarge() }
        }
        let lines = lines(in: data)
        if lines.count > lineLimit { throw TooLarge() }
        return lines.map { fileSystems.location(from: $0, relativeTo: base) }.filter { isTrusted($0, listedIn: file) }
    }

    /// Whether a file named by a list file may be listed: a local file, or one on the very
    /// server (scheme, host, port) the list file itself was read from.
    internal static func isTrusted(_ url: URL, listedIn file: URL) -> Bool {
        if url.isFileURL {
            return true
        }
        return url.scheme == file.scheme && url.host == file.host && url.port == file.port
    }
}
