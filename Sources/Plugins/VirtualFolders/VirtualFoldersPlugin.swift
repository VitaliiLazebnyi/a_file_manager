public import AFMContracts
public import AFMKernel
public import Foundation

/// Branch view and file lists shown as folders (spec 03 › Branch view, 09 › Feed to listbox).
///
/// The plugin provides the `vfolder:` file system, the commands that put a panel into branch
/// view and take it out again, and `FileListService` for plugins that have a list of files to
/// show (Find Files). Commands and the service are used on the main thread; reading happens in
/// the file system, on the panel's background threads.
public final class VirtualFoldersPlugin: Plugin, FileListService {
    /// A branch view command of one side, which works on that panel whichever is the source.
    private struct SidedCommand {
        /// The branch view commands of the left and the right panel.
        static let all: [Self] = [
            Self(id: .leftBranchView, title: "Left: Branch View", isLeft: true, selectedOnly: false),
            Self(id: .rightBranchView, title: "Right: Branch View", isLeft: false, selectedOnly: false),
            Self(
                id: .leftBranchViewSelected,
                title: "Left: Branch View of Selected Folders",
                isLeft: true,
                selectedOnly: true
            ),
            Self(
                id: .rightBranchViewSelected,
                title: "Right: Branch View of Selected Folders",
                isLeft: false,
                selectedOnly: true
            )
        ]

        let id: CommandID
        let title: String
        let isLeft: Bool
        let selectedOnly: Bool
    }

    /// The setting that has branch views list the folders too.
    internal static let listsFoldersKey = "virtualFolders.listsFolders"
    /// The setting that has branch views walk into packages.
    internal static let entersPackagesKey = "virtualFolders.entersPackages"

    /// The plugin's name, which the settings and the plugin list know it by.
    public let name = "VirtualFolders"

    /// The file system this plugin provides; nil until the plugin has started.
    public private(set) var fileSystem: VirtualFileSystem?

    /// A plugin that does nothing until it is started.
    public init() {
        // The file system is made by `start`, with the kernel's registry.
    }

    /// Hands the user's options to the file system, which reads them on background threads.
    private static func applyOptions(_ settings: any SettingsStore, to fileSystem: VirtualFileSystem) {
        fileSystem.options = VirtualFileSystem.Options(
            listsFolders: settings.flag(listsFoldersKey, default: false),
            entersPackages: settings.flag(entersPackagesKey, default: false)
        )
    }

    /// Whether the panel shows a virtual folder of any kind.
    private static func isVirtual(_ panel: any PanelHandle) -> Bool {
        VirtualLocation(panel.model.directory) != nil
    }

    /// Whether the panel shows a branch view or a selected branch, not a list.
    private static func isBranch(_ panel: any PanelHandle) -> Bool {
        switch VirtualLocation(panel.model.directory) {
        case .branch, .picked:
            return true

        default:
            return false
        }
    }

    /// The Branch View page of the configuration dialog; a change is handed to the file system
    /// and every panel that shows a virtual folder reads it again.
    private static func preferencePage(owner: Kernel, fileSystem: VirtualFileSystem) -> PreferencePage {
        unowned let kernel = owner
        return PreferencePage(
            title: "Branch View",
            preferences: [
                Preference(listsFoldersKey, "List the folders too, not only the files in them", .flag(default: false)),
                Preference(
                    entersPackagesKey,
                    "Show the contents of packages (applications, bundles)",
                    .flag(default: false)
                )
            ]
        ) {
            applyOptions(kernel.settings, to: fileSystem)
            for panel in kernel.panels.all where isVirtual(panel) { panel.reload() }
        }
    }

    /// Registers the file system, the list service, the commands and the preference page.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let virtual = VirtualFileSystem(fileSystems: kernel.fileSystems)
        fileSystem = virtual
        kernel.fileSystems.register(virtual)
        kernel.services.register((any FileListService).self, self)
        Self.applyOptions(kernel.settings, to: virtual)
        registerCommands(in: kernel, fileSystem: virtual)
        kernel.menus.add([.branchView, .branchViewSelected], to: .commandsPlaces)
        kernel.toolbar.add(
            .branchView,
            symbol: "list.bullet.indent",
            group: 30,
            hint: "Show the files of this folder and of all its subfolders in one list."
        )
        kernel.toolbar.setSymbol("list.bullet.rectangle", for: .loadFileList)
        kernel.preferences.add(Self.preferencePage(owner: kernel, fileSystem: virtual))
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

    /// Registers the branch view commands of the source panel and of each side, and Load File List.
    private func registerCommands(in owner: Kernel, fileSystem: VirtualFileSystem) {
        unowned let kernel = owner
        let commands = kernel.commands
        let source = { kernel.panels.source }
        commands.register(
            Command(.branchView, "Branch View (With Subdirs)", [Shortcut(.character("b"), .control)]),
            checked: { Self.isBranch(source()) },
            parameterized: { [self] argument in
                setBranchView(argument, in: source(), selectedOnly: false, kernel: kernel, fileSystem: fileSystem)
            }
        )
        commands.register(
            Command(
                .branchViewSelected,
                "Branch View of Selected Folders",
                [Shortcut(.character("b"), [.control, .shift])]
            ),
            enabled: { Self.isVirtual(source()) || source().model.hasOperands },
            parameterized: { [self] argument in
                setBranchView(argument, in: source(), selectedOnly: true, kernel: kernel, fileSystem: fileSystem)
            }
        )
        for sided in SidedCommand.all {
            let panel = { sided.isLeft ? kernel.panels.left : kernel.panels.right }
            commands.register(
                Command(sided.id, sided.title),
                checked: { Self.isBranch(panel()) },
                parameterized: { [self] argument in
                    setBranchView(
                        argument,
                        in: panel(),
                        selectedOnly: sided.selectedOnly,
                        kernel: kernel,
                        fileSystem: fileSystem
                    )
                }
            )
        }
        commands.register(Command(.loadFileList, "Load File List into Panel…")) { [self] argument in
            loadList(argument, kernel: kernel)
        }
    }

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
        let state = argument.index ?? argument.text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        switch state {
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

    /// Shows the branch view of the panel's directory, or of its selected items only.
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
                fileSystem.entries(of: virtual).map(\.lastPathComponent)
            },
            completion: { names in show(selecting: names) }
        )
    }

    // MARK: Lists from files

    /// Load File List: reads the list file named by the argument (or typed by the user) in the
    /// background and shows its files in the source panel.
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

    deinit {
        // Nothing to release: the kernel holds what was registered.
    }
}
