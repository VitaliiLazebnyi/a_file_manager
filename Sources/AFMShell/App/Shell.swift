import AFMContracts
import AFMKernel
import AppKit

/// The window shell: the main window with its two panels, the progress window and the menu
/// bar. It provides no file-manager features itself; it shows what the plugins registered
/// with the kernel and hands keys, clicks and menu choices to their commands. The only
/// commands of its own are those of the file list as a control (`ShellCommands`).
public final class Shell: ShellServices {
    let kernel: Kernel
    let panelCoordinator: PanelCoordinator
    let jobService = ProgressJobService()
    let layout: WindowLayout
    private(set) var mainWindow: MainWindowController!

    public var panels: PanelSet { panelCoordinator }
    public var jobs: JobService { jobService }

    /// Call after the plugins are loaded: the panels need the file systems, the menus and the
    /// function-key bar the commands.
    public init(kernel: Kernel, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.kernel = kernel
        panelCoordinator = PanelCoordinator(kernel: kernel, home: home)
        layout = WindowLayout(settings: kernel.settings)
        panelCoordinator.isPaused = { [jobService] in jobService.isBusy }
        ShellCommands.register(in: kernel, panels: panelCoordinator)
        PanelShellCommands.register(in: kernel, panels: panelCoordinator)
        WindowCommands.register(in: kernel, layout: layout) { [weak self] in self?.mainWindow }
        kernel.commands.onRejected = { NSSound.beep() }
        // From here on the key bindings are final and commands may run.
        kernel.attach(self)
        mainWindow = MainWindowController(kernel: kernel, panels: panelCoordinator, layout: layout)
        jobService.window = mainWindow.window
        // Reading ahead rests while the user works elsewhere and while a job runs.
        panelCoordinator.isWindowActive = { [weak self] in NSApp.isActive && self?.mainWindow.window?.isKeyWindow == true }
        jobService.onBusyChanged = { [weak self, weak jobService] in
            self?.panelCoordinator.updateReadAhead()
            self?.mainWindow.scheduleValidation()
            if jobService?.isBusy == false { self?.panelCoordinator.jobsEnded() }
        }
        panelCoordinator.onActivityChanged = { [weak self] in self?.mainWindow.scheduleValidation() }
        let ui = kernel.ui
        jobService.askToAbandon = { title in
            ui.choose("“\(title)” does not stop.",
                      detail: "It may be waiting for a disk or a server that does not answer. You can go on waiting, or stop waiting and "
                          + "use the program again; the operation then ends by itself as soon as the disk or server lets it.",
                      buttons: ["Stop Waiting", "Keep Waiting"], style: .warning, defaultButton: 1) == 0
        }
    }

    /// How long quitting waits for the jobs to stop before it asks the user, and for the
    /// plugins to give up once the user said not to wait for them.
    public static var quitPatience: TimeInterval = 5
    /// How long the plugins may take to finish before the user is shown that the program is
    /// still at it: nearly always they have nothing to do and nothing is shown.
    public static var quitProgressDelay: TimeInterval = 0.5

    /// What is shown while the plugins finish before the program quits; nil when nothing is
    /// being finished.
    private(set) var quitProgress: QuitProgress?

    /// Asks the plugins whether the program may quit (`Kernel.shouldTerminate`): one with
    /// work the user would lose (unsaved edits) asks about it here, and the user can call the
    /// quit off. Nothing has been stopped when this is asked. Main thread.
    public func mayQuit() -> Bool {
        MainThread.assert("Quitting")
        // A second request while the first is still being carried out changes nothing.
        guard quitProgress == nil, !jobService.isQuitting else { return false }
        return kernel.shouldTerminate()
    }

    /// Everything that has to end before the program quits, in order: the file jobs are
    /// stopped and tidy up (`stopJobsToQuit`), then every plugin finishes what it has not
    /// written yet (`Kernel.prepareToQuit`: changes inside archives, the operation log), in
    /// the background. `reply` is called once, on the main thread, from the run loop: with
    /// true when the program may quit now, with false when the user called the quit off.
    ///
    /// Plugins that are not done after `progressDelay` get a small window that says so, with
    /// two ways out. **Quit Now** tells them not to keep the user waiting (the cancellation
    /// flag of `prepareToQuit`); the program quits as soon as they have given up, and after
    /// `patience` whether they have or not. What was not written is the plugins' to keep
    /// safe, and they do (the archives keep the new members on the disk and say where).
    /// **Don't Quit** calls the quit off: the program goes on, and what the plugins were
    /// writing they go on writing.
    public func finishToQuit(patience: TimeInterval = Shell.quitPatience, progressDelay: TimeInterval = Shell.quitProgressDelay,
                             then reply: @escaping (Bool) -> Void) {
        MainThread.assert("Quitting")
        stopJobsToQuit(patience: patience) { [self] _ in
            let flag = CancellationFlag()
            let progress = QuitProgress()
            var hasReplied = false
            var stopWaiting: (() -> Void)?
            func answer(_ quits: Bool) {
                guard !hasReplied else { return }
                hasReplied = true
                stopWaiting?()
                progress.close()
                quitProgress = nil
                // The program goes on: jobs are the user's to stop again.
                if !quits { jobService.isQuitting = false }
                reply(quits)
            }
            progress.onQuitNow = {
                flag.cancel()
                // A plugin that does not even give up is not waited for for ever.
                stopWaiting = MainLoop.after(patience) { answer(true) }
            }
            progress.onDontQuit = { answer(false) }
            quitProgress = progress
            jobService.isQuitting = true
            kernel.prepareToQuit(cancellation: flag) { MainLoop.perform { answer(true) } }
            if !hasReplied { progress.show(after: progressDelay) }
        }
    }

    /// Quitting in the middle of a file job first stops the jobs and lets them tidy up, so no
    /// half-written file is left behind. `reply` is called once, on the main thread, with true
    /// when the program may quit: at once when nothing runs, otherwise when the last job has
    /// ended. A job that has not stopped after `patience` (it waits for a disk or a server
    /// that does not answer) does not keep the program from quitting for ever: the user is
    /// asked whether to quit anyway, and again after twice as long each time the answer is no.
    public func stopJobsToQuit(patience: TimeInterval = Shell.quitPatience, then reply: @escaping (Bool) -> Void) {
        guard jobService.isBusy else { return reply(true) }
        var hasReplied = false
        var stopAsking: (() -> Void)?
        let (jobService, ui) = (jobService, kernel.ui)
        func answer(_ quits: Bool) {
            guard !hasReplied else { return }
            hasReplied = true
            stopAsking?()
            reply(quits)
        }
        func ask(after wait: TimeInterval) {
            stopAsking = MainLoop.after(wait) {
                guard !hasReplied, jobService.isBusy else { return }
                // Return keeps waiting: quitting anyway may cost a file.
                let quits = ui.choose("An operation does not stop.",
                                      detail: "It may be waiting for a disk or a server that does not answer. If you quit anyway, a file "
                                          + "it was writing may be left incomplete.",
                                      buttons: ["Quit Anyway", "Keep Waiting"], style: .warning, defaultButton: 1) == 0
                if quits { answer(true) } else if !hasReplied { ask(after: wait * 2) }
            }
        }
        jobService.isQuitting = true
        jobService.cancelAll { answer(true) }
        if !hasReplied { ask(after: patience) }
    }

    public func makeMainMenu() -> NSMenu {
        MenuBuilder.mainMenu(appName: kernel.productName, kernel: kernel)
    }

    public func showMainWindow() {
        mainWindow.showWindow(nil)
    }

    /// Opens the configuration dialog, when a plugin provides one (the Mac's "Settings…").
    public func showSettings() {
        kernel.commands.perform(.configuration)
    }

    public var canShowSettings: Bool { kernel.commands.isEnabled(.configuration) }

    /// Remembers the panels' tabs and the window for the next start.
    public func saveState() {
        panelCoordinator.saveState()
        mainWindow.saveState()
    }

    /// Ends everything the shell keeps running: watching folders, reading them, the window.
    public func shutDown() {
        panelCoordinator.shutDown()
        mainWindow.close()
    }
}

/// Runs the program: a kernel, the given plugins, and the shell on top.
public final class ShellApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let productName: String
    private let plugins: [Plugin]
    private var kernel: Kernel?
    private var shell: Shell?
    private var settings: UserDefaultsSettings?

    public init(productName: String, plugins: [Plugin]) {
        self.productName = productName
        self.plugins = plugins
    }

    public func run() {
        let app = NSApplication.shared
        app.delegate = self
        app.setActivationPolicy(.regular)
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = UserDefaultsSettings()
        self.settings = settings
        let kernel = Kernel(productName: productName, settings: settings, ui: AlertInteraction())
        kernel.load(plugins)
        let shell = Shell(kernel: kernel)
        self.kernel = kernel
        self.shell = shell
        MenuBuilder.install(shell.makeMainMenu())
        shell.showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// How long quitting waits for settings that are still on their way to the disk.
    public static var settingsPatience: TimeInterval = 5

    /// Quitting asks the plugins first (one with unsaved work asks the user, who may call the
    /// quit off), then stops the file jobs and lets them tidy up, so no half-written file is
    /// left behind, then lets the plugins write what they have not written yet. The program
    /// stays in use until all of that has been answered (`Shell.finishToQuit`).
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shell else { return .terminateNow }
        guard shell.mayQuit() else { return .terminateCancel }
        var answer: Bool?
        var repliesLater = false
        shell.finishToQuit { quits in
            if repliesLater { sender.reply(toApplicationShouldTerminate: quits) } else { answer = quits }
        }
        if let answer { return answer ? .terminateNow : .terminateCancel }
        repliesLater = true
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        shell?.saveState()
        shell?.shutDown()
        kernel?.shutdown()
        // Large values are written in the background; the last ones are waited for, not for ever.
        settings?.waitForWrites(atMost: ShellApplication.settingsPatience)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // The entries of the menu bar that must work whichever window is in front; the
    // application's delegate is the last stop of every menu action.

    @objc func showSettings(_ sender: Any?) {
        shell?.showSettings()
    }

    @objc func showMainWindow(_ sender: Any?) {
        shell?.showMainWindow()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(showSettings(_:)) ? shell?.canShowSettings ?? false : true
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { shell?.showMainWindow() }
        return true
    }
}
