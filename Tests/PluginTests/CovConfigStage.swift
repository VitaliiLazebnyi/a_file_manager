import AFMKernel
import AppKit
import LocalFileSystemPlugin
import NavigationPlugin
import SelectionPlugin
import TestSupport

@testable import ConfigurationPlugin

/// The Configuration plugin on a bench, with recorders in place of the beep, the modal run,
/// the file panel and putting windows on screen: nothing reaches the desktop.
@MainActor
internal final class CovConfigStage {
    /// The folders the panels show, `A` and `B`, and the list files.
    internal let box: Sandbox
    /// The settings of the bench.
    internal let settings = MemorySettings()
    /// The plugin, started.
    internal let plugin: ConfigurationPlugin
    /// The kernel with fake panels the plugin runs in.
    internal let bench: TestBench
    /// What the plugin's windows and commands share.
    internal let center: ConfigurationCenter
    /// Where copied names go.
    internal let pasteboard = NSPasteboard.withUniqueName()
    /// How often the user would have heard a beep.
    internal private(set) var beeps = 0
    /// The windows that would have been put on screen.
    internal private(set) var presented: [NSWindowController] = []
    /// How often a modal run was ended.
    internal private(set) var modalStops = 0
    /// How often the About panel was asked for.
    internal private(set) var aboutPanels = 0
    /// The files the panels were asked for: whether for saving, and the product's name.
    internal private(set) var fileRequests: [(saving: Bool, product: String)] = []
    /// What watches the key presses now, as the program would call it.
    internal private(set) var keyHandler: ((NSEvent) -> NSEvent?)?
    /// What the file panel answers.
    internal var chosenFile: URL?
    /// The menu bar the plugin sees.
    internal var mainMenu: NSMenu?
    /// The windows the plugin sees.
    internal var windows: [NSWindow] = []
    /// What the user does while the command picker runs modally.
    internal var whilePicking: (NSWindow) -> Void = { _ in
        // The user does nothing: the picker ends without a choice.
    }

    /// The kernel's commands.
    internal var commands: CommandRegistry { bench.commands }
    /// The scripted user.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// `stored` is in the settings before the plugins start; without `settingsKeys` the plugin
    /// asks its store for the keys.
    internal init(stored: [String: Data], settingsKeys: (() -> [String])?) throws {
        box = try Sandbox()
        try box.folder("A")
        try box.folder("B")
        for (key, value) in stored { settings.set(value as Data?, forKey: key) }
        plugin = ConfigurationPlugin(
            launchesApplications: false,
            background: nil,
            listFolder: box.url("lists"),
            settingsKeys: settingsKeys
        )
        bench = TestBench(
            plugins: [NavigationPlugin(), SelectionPlugin(), plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        guard let started = plugin.center else { throw CocoaError(.featureUnsupported) }
        center = started
        center.effects = recorders()
    }

    /// A stage with nothing stored and one extra settings key.
    internal convenience init() throws {
        try self.init(stored: [:]) { ["extra.key"] }
    }

    /// Every view of `type` below `view`, in order.
    internal static func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else {
            return []
        }
        return view.subviews.flatMap { subview in [subview as? View].compactMap(\.self) + views(type, in: subview) }
    }

    /// The button with this title below `view`.
    internal static func button(_ title: String, in view: NSView?) -> NSButton? {
        views(NSButton.self, in: view).first { $0.title == title }
    }

    /// Clicks the button with this title below `view`, as the user would; false when there is none.
    @discardableResult
    internal static func press(_ title: String, in view: NSView?) -> Bool {
        guard let button = button(title, in: view) else {
            return false
        }
        return button.sendAction(button.action, to: button.target)
    }

    /// Closes every window the plugin made.
    internal func close() {
        plugin.stop()
    }

    /// The effects that record what they are asked.
    private func recorders() -> ConfigurationEffects {
        ConfigurationEffects(
            present: { [weak self] in self?.presented.append($0) },
            beep: { [weak self] in self?.beeps += 1 },
            runModal: { [weak self] in self?.whilePicking($0) },
            stopModal: { [weak self] in self?.modalStops += 1 },
            chooseSettingsFile: { [weak self] saving, product in
                self?.fileRequests.append((saving, product))
                return self?.chosenFile
            },
            showAbout: { [weak self] in self?.aboutPanels += 1 },
            mainMenu: { [weak self] in self?.mainMenu },
            windows: { [weak self] in self?.windows ?? [] },
            pasteboard: pasteboard,
            monitorKeys: { [weak self] handler in
                self?.keyHandler = handler
                return "monitor"
            },
            removeKeyMonitor: { [weak self] _ in self?.keyHandler = nil }
        )
    }

    deinit {
        // Nothing to release.
    }
}
