import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The application's delegate: starting the program, its menu entries, and quitting.
///
/// Started without being shown (`start`); what puts the program on the screen and asks the
/// system (`applicationDidFinishLaunching`, replying to a quit) is the UI tests'.
@MainActor
@Suite(.serialized)
internal struct AppDelegateTests {
    /// A plugin that may say no to quitting.
    internal final class Veto: Plugin {
        /// The plugin's name.
        internal let name = "Veto"
        /// Whether the plugin lets the program quit.
        internal var allowsQuitting = true

        /// Nothing to start.
        internal func start(in _: Kernel) {
            // Only the answer to quitting matters.
        }

        /// The plugin's answer to quitting.
        internal func shouldTerminate() -> Bool {
            allowsQuitting
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The preferences of a test, in a suite and a folder of their own.
    private let settings: UserDefaultsSettings
    /// The name of the preferences' suite.
    private let suite = "afm-tests-" + UUID().uuidString
    /// The folders of the test.
    private let sandbox: Sandbox

    /// Preferences that are the test's alone.
    internal init() throws {
        _ = NSApplication.shared
        sandbox = try Sandbox()
        let defaults = try #require(UserDefaults(suiteName: suite))
        settings = UserDefaultsSettings(defaults: defaults, largeFolder: sandbox.url("large"))
    }

    /// Before the program has started it quits at once, offers no settings and shows nothing.
    @Test
    internal func beforeTheStartItQuitsAtOnce() {
        weak var released: ShellApplication?
        autoreleasepool {
            let delegate = ShellApplication(productName: "Test", plugins: [])
            released = delegate
            checkBeforeTheStart(delegate)
        }
        #expect(released == nil)
    }

    /// The answers of a delegate whose program has not started.
    private func checkBeforeTheStart(_ delegate: ShellApplication) {
        var replies: [Bool] = []
        #expect(delegate.requestQuit { replies.append($0) } == .terminateNow && replies.isEmpty)
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(ShellApplication.showSettings(_:)),
            keyEquivalent: ""
        )
        #expect(!delegate.validateMenuItem(settingsItem))
        #expect(
            delegate.validateMenuItem(NSMenuItem(title: "Other", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        )
        delegate.showSettings(nil)
        delegate.showMainWindow(nil)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
    }

    /// Started, the program asks its plugins before it quits and answers later; a plugin can call it off.
    @Test
    internal func quittingAsksThePluginsAndAnswersLater() async {
        let veto = Veto()
        let delegate = ShellApplication(productName: "Test", plugins: [veto])
        var rejected = 0
        let shell = delegate.start(settings: settings, interaction: ScriptedInteraction()) { rejected += 1 }
        defer {
            shell.shutDown()
            UserDefaults().removePersistentDomain(forName: suite)
        }
        // A command that cannot run is refused through the program's own signal.
        #expect(!shell.kernel.commands.perform("cm_NobodyHasThis") && rejected == 1)
        veto.allowsQuitting = false
        var replies: [Bool] = []
        #expect(delegate.requestQuit { replies.append($0) } == .terminateCancel)
        veto.allowsQuitting = true
        #expect(delegate.requestQuit { replies.append($0) } == .terminateLater && replies.isEmpty)
        #expect(await AppWait.until { replies == [true] })
    }

    /// Clicking the program in the Dock with no window on screen brings the main window back;
    /// the Settings entry follows whether a plugin offers the dialog; quitting keeps the state.
    @Test
    internal func reopeningShowsTheWindowAndQuittingKeepsTheState() {
        // Nothing comes on the screen, and nothing is left open.
        // Only the program's main window: other suites' windows are theirs to close.
        let windows = StabilityWindows { $0.windowController is MainWindowController }
        defer {
            #expect(windows.shown.isEmpty && windows.open.isEmpty, "\(windows.shown) \(windows.openTitles)")
            windows.closeAll()
        }
        let delegate = ShellApplication(productName: "Test", plugins: [])
        let shell = delegate.start(settings: settings, interaction: ScriptedInteraction()) {
            // Nothing is refused here.
        }
        defer {
            shell.shutDown()
            UserDefaults().removePersistentDomain(forName: suite)
        }
        // The window is shown by asking for it; nothing comes on the screen of the test.
        var shown: [NSWindow] = []
        shell.mainWindow.present = { window, _ in shown.append(window) }
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(shown.count == 1 && shown.first === shell.mainWindow.window)
        delegate.showMainWindow(nil)
        #expect(shown.count == 2)
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(ShellApplication.showSettings(_:)),
            keyEquivalent: ""
        )
        #expect(!delegate.validateMenuItem(settingsItem) && !shell.canShowSettings)
        delegate.showSettings(nil)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(settings.data(forKey: "left.tabs") != nil)
    }
}
