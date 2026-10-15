public import AFMKernel
public import AppKit

/// Runs the program: a kernel, the given plugins, and the shell on top.
///
/// The application's delegate. Main thread only.
@preconcurrency
@MainActor
public final class ShellApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The answer to a request to quit, which comes at once or later from the run loop.
    private final class QuitReply {
        /// The answer, when it came before the request returned.
        var answer: NSApplication.TerminateReply?
        /// True once the request has returned `.terminateLater`.
        var isLater = false

        deinit {
            // Nothing to release.
        }
    }

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

    /// Runs the program until the user quits.
    public func run() {
        let app = NSApplication.shared
        app.delegate = self
        app.setActivationPolicy(.regular)
        app.run()
    }

    /// Starts the kernel, the plugins and the shell, and shows the main window.
    public func applicationDidFinishLaunching(_: Notification) {
        let preferences = UserDefaultsSettings()
        let program = Kernel(productName: productName, settings: preferences, interaction: AlertInteraction())
        program.load(plugins)
        let windows = Shell(kernel: program)
        settings = preferences
        kernel = program
        shell = windows
        MenuBuilder.install(windows.makeMainMenu())
        windows.showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quitting asks the plugins first, then stops the file jobs and lets the plugins finish.
    ///
    /// A plugin with unsaved work asks the user, who may call the quit off. The jobs tidy up,
    /// so no half-written file is left behind, and the plugins write what they have not written
    /// yet. The program stays in use until all of that has been answered (`Shell.finishToQuit`).
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shell else {
            return .terminateNow
        }
        guard shell.mayQuit() else {
            return .terminateCancel
        }
        // The answer comes on the main thread: at once, or later from the run loop.
        let reply = QuitReply()
        shell.finishToQuit { quits in
            if reply.isLater {
                sender.reply(toApplicationShouldTerminate: quits)
            } else {
                reply.answer = quits ? .terminateNow : .terminateCancel
            }
        }
        if let answer = reply.answer {
            return answer
        }
        reply.isLater = true
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
