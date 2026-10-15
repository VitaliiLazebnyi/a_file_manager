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
    internal let box: Sandbox
    internal let settings = MemorySettings()
    internal let plugin: ConfigurationPlugin
    internal let bench: TestBench
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
    /// What the file panel answers.
    internal var chosenFile: URL?
    /// Where copied names go.
    internal let pasteboard = NSPasteboard.withUniqueName()
    /// What watches the key presses now, as the program would call it.
    internal private(set) var keyHandler: ((NSEvent) -> NSEvent?)?
    /// The menu bar the plugin sees.
    internal var mainMenu: NSMenu?
    /// The windows the plugin sees.
    internal var windows: [NSWindow] = []
    /// What the user does while the command picker runs modally.
    internal var whilePicking: (NSWindow) -> Void = { _ in }

    internal var commands: CommandRegistry { bench.commands }
    internal var ui: ScriptedInteraction { bench.interaction }
    internal let center: ConfigurationCenter

    /// `stored` is in the settings before the plugins start; without `settingsKeys` the plugin
    /// asks its store for the keys.
    internal init(
        plugins: [any Plugin] = [],
        stored: [String: Data] = [:],
        settingsKeys: (() -> [String])? = { ["extra.key"] }
    ) throws {
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
            plugins: [NavigationPlugin(), SelectionPlugin()] + plugins + [plugin],
            fileSystems: [LocalFileSystem()],
            left: box.url("A"),
            right: box.url("B"),
            settings: settings
        )
        guard let center = plugin.center else { throw CocoaError(.featureUnsupported) }
        self.center = center
        center.effects = ConfigurationEffects(
            present: { [unowned self] in presented.append($0) },
            beep: { [unowned self] in beeps += 1 },
            runModal: { [unowned self] in whilePicking($0) },
            stopModal: { [unowned self] in modalStops += 1 },
            chooseSettingsFile: { [unowned self] saving, product in
                fileRequests.append((saving, product))
                return chosenFile
            },
            showAbout: { [unowned self] in aboutPanels += 1 },
            mainMenu: { [unowned self] in mainMenu },
            windows: { [unowned self] in windows },
            pasteboard: pasteboard,
            monitorKeys: { [unowned self] handler in
                keyHandler = handler
                return "monitor"
            },
            removeKeyMonitor: { [unowned self] _ in keyHandler = nil }
        )
    }

    /// Closes every window the plugin made.
    internal func close() {
        plugin.stop()
    }

    /// Every view of `type` below `view`, in order.
    internal static func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        return view.subviews.flatMap { subview in [subview as? View].compactMap(\.self) + views(type, in: subview) }
    }

    /// The button with this title below `view`.
    internal static func button(_ title: String, in view: NSView?) -> NSButton? {
        views(NSButton.self, in: view).first { $0.title == title }
    }

    /// Clicks the button with this title below `view`, as the user would; false when there is none.
    @discardableResult
    internal static func press(_ title: String, in view: NSView?) -> Bool {
        guard let button = button(title, in: view) else { return false }
        return button.sendAction(button.action, to: button.target)
    }

    deinit {
        // Nothing to release.
    }
}
