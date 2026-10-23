public import AFMKernel
public import Foundation

/// Attributes, properties, occupied space, comments and links (spec 07 › Change attributes,
/// File comments, Properties, Calculate occupied space, Create shortcut), and the columns
/// that show such facts in the file list.
public final class FilePropertiesPlugin: Plugin {
    /// The keys of the plugin's settings.
    internal enum Settings {
        /// The kind of link Create Link proposes, as the index of a `LinkKind`.
        internal static let linkKind = "fileProperties.linkKind"
        /// Whether symbolic links are made with relative paths unless the dialog says otherwise.
        internal static let relativeLinks = "fileProperties.relativeLinks"
        /// Whether Calculate Occupied Space selects the folders it measured.
        internal static let selectMeasured = "fileProperties.selectMeasuredFolders"
        /// Whether a `descript.ion` written here gets the hidden flag.
        internal static let hideCommentFile = "fileProperties.hideCommentFile"
    }

    /// The most items Finder Info opens windows for, and the most requests `finderInfoRequests` keeps.
    internal static let finderInfoRequestLimit = 64

    /// The plugin's name in the list of plugins.
    public let name = "FileProperties"
    /// Runs AppleScript with these `osascript` arguments; nil starts nothing (tests).
    private let runScript: (@Sendable ([String]) -> Void)?
    /// The items Finder's Info window was asked for, whether or not Finder was really told; the
    /// most recent ones only, for tests to look at.
    public private(set) var finderInfoRequests: [URL] = []

    /// Tests turn `launchesApplications` off, so they do not start other applications.
    public convenience init(launchesApplications: Bool = true) {
        self.init(runScript: launchesApplications ? AppleScript.run : nil)
    }

    /// A plugin that hands its AppleScript to `runScript`.
    internal init(runScript: (@Sendable ([String]) -> Void)?) {
        self.runScript = runScript
    }

    /// The `osascript` arguments that open Finder's Info window of each item.
    ///
    /// Finder is handed no path: on some systems it resolves no file path it is given, as an alias
    /// or a file URL ("Can't get alias", -1728), while its own references always work. So the
    /// script walks to each item by name, from the disk it is on (`finderPath`).
    internal static func finderInfoArguments(_ urls: [URL]) -> [String] {
        let script = [
            "on run paths", "set AppleScript's text item delimiters to \":\"", "tell application \"Finder\"",
            "repeat with itemPath in paths", "set names to rest of text items of (contents of itemPath)",
            "set found to startup disk",
            "if (count of names) > 1 and item 1 of names is \"Volumes\" then",
            "set found to disk (item 2 of names)", "set names to rest of rest of names", "end if",
            "repeat with itemName in names",
            "if contents of itemName is not \"\" then set found to item (contents of itemName) of found",
            "end repeat", "open information window of found", "end repeat", "activate", "end tell", "end run"
        ]
        return script.flatMap { ["-e", $0] } + urls.map(finderPath)
    }

    /// An item's path as Finder names it: each name after a `:`, a `:` in a name written `/` (as
    /// Finder shows it), so the separator is never part of a name; the startup disk is `:`.
    internal static func finderPath(of url: URL) -> String {
        ":" + url.pathComponents.dropFirst().map { $0.replacingOccurrences(of: ":", with: "/") }.joined(separator: ":")
    }

    /// Registers the columns, the commands, the menu entries, the toolbar buttons and the
    /// preferences of the plugin; main thread.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let comments = CommentStore(fileSystems: kernel.fileSystems)
        PropertyColumns.register(in: kernel.columns, comments: comments)
        let actions = PropertyActions(kernel, comments: comments) { [weak self] urls in self?.showFinderInfo(urls) }
        Self.registerCommands(in: kernel, actions: actions)
        Self.addMenusAndButtons(in: kernel)
        Self.addPreferences(in: kernel)
    }

    /// Opens Finder's Info window for local items.
    ///
    /// Finder is asked through `osascript`, off the main thread; the first time, macOS asks the
    /// user whether the program may control Finder. Asked for local items only: the command is
    /// offered in local folders, the button of the Properties dialog for local items.
    private func showFinderInfo(_ urls: [URL]) {
        finderInfoRequests = Array((finderInfoRequests + urls).suffix(Self.finderInfoRequestLimit))
        guard let runScript else {
            return
        }
        let arguments = Self.finderInfoArguments(urls)
        // Starting a program waits for the system: on a thread for work that waits.
        BlockingCalls.run { runScript(arguments) }
    }

    deinit {
        // Nothing to release.
    }
}
