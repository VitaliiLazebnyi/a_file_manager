public import AFMKernel
public import AppKit

/// Runs the program: a kernel, the given plugins, and the shell on top.
///
/// The application's delegate. Main thread only.
@preconcurrency
@MainActor
public final class ShellApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// How long quitting waits for settings that are still on their way to the disk.
    public static let settingsPatience: TimeInterval = 5

    /// The name of the program, for the menus and the window title.
    private let productName: String
    /// The plugins, started in this order.
    private let plugins: [any Plugin]
    /// The kernel, once the program has started.
    private var kernel: Kernel?
    /// The shell, once the program has started.
    private var shell: Shell?
    /// The preferences, once the program has started.
    private var settings: UserDefaultsSettings?

    /// The program called `productName`, with `plugins`.
    public init(productName: String, plugins: [any Plugin]) {
        self.productName = productName
        self.plugins = plugins
    }

    /// Starts the kernel, the plugins and the shell, and shows the main window.
    ///
    /// The program's own preferences and alerts; a refused command beeps.
    public func applicationDidFinishLaunching(_: Notification) {
        let windows = start(settings: UserDefaultsSettings(), interaction: AlertInteraction()) { NSSound.beep() }
        MenuBuilder.install(windows.makeMainMenu())
        windows.showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Starts the kernel with `settings` and `interaction`, the plugins and the shell, without
    /// showing anything; `rejected` is called for a command that cannot run now.
    @discardableResult
    internal func start(
        settings preferences: UserDefaultsSettings,
        interaction: any UserInteraction,
        rejected: @escaping () -> Void
    ) -> Shell {
        let program = Kernel(productName: productName, settings: preferences, interaction: interaction)
        program.load(plugins)
        program.commands.onRejected = rejected
        let windows = Shell(kernel: program)
        settings = preferences
        kernel = program
        shell = windows
        return windows
    }

    /// Quitting asks the plugins first, then stops the file jobs and lets the plugins finish.
    ///
    /// A plugin with unsaved work asks the user, who may call the quit off. The jobs tidy up,
    /// so no half-written file is left behind, and the plugins write what they have not written
    /// yet. The program stays in use until all of that has been answered (`Shell.finishToQuit`).
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestQuit { sender.reply(toApplicationShouldTerminate: $0) }
    }

    /// Whether the program may quit now, never, or after `reply` is called with the answer
    /// (on the main thread, from the run loop).
    internal func requestQuit(then reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard let shell else {
            return .terminateNow
        }
        guard shell.mayQuit() else {
            return .terminateCancel
        }
        shell.finishToQuit(then: reply)
        return .terminateLater
    }

    /// Saves what the next start needs and ends the shell, the plugins and the writing of settings.
    public func applicationWillTerminate(_: Notification) {
        shell?.saveState()
        shell?.shutDown()
        kernel?.shutdown()
        // Large values are written in the background; the last ones are waited for, not for ever.
        settings?.waitForWrites(atMost: Self.settingsPatience)
    }

    /// The program keeps running without a window, as Mac programs do.
    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// Opens the configuration dialog; the menu bar's "Settings…" entry, whichever window is in front.
    ///
    /// The application's delegate is the last stop of every menu action.
    @objc
    internal func showSettings(_: Any?) {
        shell?.showSettings()
    }

    /// Brings the main window back; the Window menu's entry for it.
    @objc
    internal func showMainWindow(_: Any?) {
        shell?.showMainWindow()
    }

    /// "Settings…" can be chosen while a plugin provides the dialog; every other entry this
    /// object answers can.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(showSettings(_:)) ? shell?.canShowSettings ?? false : true
    }

    /// Clicking the program in the Dock brings the main window back when none is on screen.
    public func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            shell?.showMainWindow()
        }
        return true
    }

    deinit {
        // Nothing to release.
    }
}
