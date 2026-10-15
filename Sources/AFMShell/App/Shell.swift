import AFMContracts
public import AFMKernel
public import AppKit

/// The window shell: the main window with its two panels, the progress window and the menu bar.
///
/// It provides no file-manager features itself; it shows what the plugins registered with the
/// kernel and hands keys, clicks and menu choices to their commands. The only commands of its
/// own are those of the file list as a control (`ShellCommands`) and of the window around the
/// panels (`WindowCommands`). Main thread only.
public final class Shell: ShellServices {
    /// The answer to a request to quit, given once whoever gives it first.
    @MainActor
    private final class OnceAnswer {
        /// Called with the answer before it is passed on.
        var onAnswer: ((Bool) -> Void)?
        /// Calls off the wait that would give the answer otherwise.
        var stopWaiting: (() -> Void)?
        /// Who is waiting for the answer; nil once it was given.
        private var reply: (@MainActor (Bool) -> Void)?

        /// True once the answer was given.
        var isGiven: Bool { reply == nil }

        /// An answer for `reply`.
        init(_ reply: @escaping @MainActor (Bool) -> Void) {
            self.reply = reply
        }

        /// Gives the answer, unless it was given already.
        func give(_ quits: Bool) {
            guard let reply else {
                return
            }
            self.reply = nil
            stopWaiting?()
            stopWaiting = nil
            onAnswer?(quits)
            onAnswer = nil
            reply(quits)
        }

        deinit {
            // Nothing to release.
        }
    }

    /// How long quitting waits for the jobs to stop before it asks the user, and for the
    /// plugins to give up once the user said not to wait for them.
    public static var quitPatience: TimeInterval = 5
    /// How long the plugins may take to finish before the user is shown that the program is
    /// still at it.
    ///
    /// Nearly always they have nothing to do and nothing is shown.
    public static var quitProgressDelay: TimeInterval = 0.5

    /// The kernel the shell shows; the shell owns it.
    internal let kernel: Kernel
    /// The two panels.
    internal let panelCoordinator: PanelCoordinator
    /// Runs the plugins' long work with the progress window.
    internal let jobService = ProgressJobService()
    /// What the window shows around the panels.
    internal let layout: WindowLayout
    /// The main window; made in `init` once the kernel is attached (the key bindings are final then).
    internal private(set) lazy var mainWindow = MainWindowController(
        kernel: kernel,
        panels: panelCoordinator,
        layout: layout
    )
    /// What is shown while the plugins finish before the program quits; nil when nothing is
    /// being finished.
    internal private(set) var quitProgress: QuitProgress?

    /// The two file panels, for the plugins (`Kernel.panels`).
    public var panels: any PanelSet { panelCoordinator }
    /// The job service, for the plugins (`Kernel.jobs`).
    public var jobs: any JobService { jobService }
    /// Whether a plugin provides the configuration dialog, which "Settings…" opens.
    public var canShowSettings: Bool { kernel.commands.isEnabled(.configuration) }

    /// The shell of `kernel`, with panels that start at `home` when they have no folder of their own.
    ///
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
        // The main window is made here, with the final key bindings.
        jobService.window = mainWindow.window
        connectJobsAndPanels()
    }

    /// Asks the user whether to quit although a job does not stop; true quits.
    ///
    /// Return keeps waiting: quitting anyway may cost a file.
    private static func quitsAnyway(asking interaction: any UserInteraction) -> Bool {
        interaction.choose(
            "An operation does not stop.",
            detail: "It may be waiting for a disk or a server that does not answer. If you quit anyway, a file "
                + "it was writing may be left incomplete.",
            buttons: ["Quit Anyway", "Keep Waiting"],
            style: .warning,
            defaultButton: 1
        ) == 0
    }

    /// Asks the plugins whether the program may quit (`Kernel.shouldTerminate`).
    ///
    /// One with work the user would lose (unsaved edits) asks about it here, and the user can
    /// call the quit off. Nothing has been stopped when this is asked. False as well while an
    /// earlier request to quit is still being carried out.
    public func mayQuit() -> Bool {
        // A second request while the first is still being carried out changes nothing.
        guard quitProgress == nil, !jobService.isQuitting else {
            return false
        }
        return kernel.shouldTerminate()
    }

    /// Ends everything that has to end before the program quits.
    ///
    /// In order: the file jobs are stopped and tidy up (`stopJobsToQuit`), then every plugin
    /// finishes what it has not written yet (`Kernel.prepareToQuit`: changes inside archives,
    /// the operation log), in the background. `reply` is called once, on the main thread, from
    /// the run loop: with true when the program may quit now, with false when the user called
    /// the quit off.
    ///
    /// Plugins that are not done after `progressDelay` get a small window that says so, with
    /// two ways out. **Quit Now** tells them not to keep the user waiting (the cancellation
    /// flag of `prepareToQuit`); the program quits as soon as they have given up, and after
    /// `patience` whether they have or not. What was not written is the plugins' to keep
    /// safe, and they do (the archives keep the new members on the disk and say where).
    /// **Don't Quit** calls the quit off: the program goes on, and what the plugins were
    /// writing they go on writing.
    @preconcurrency
    public func finishToQuit(
        patience: TimeInterval = Shell.quitPatience,
        progressDelay: TimeInterval = Shell.quitProgressDelay,
        then reply: @escaping @MainActor (Bool) -> Void
    ) {
        stopJobsToQuit(patience: patience) { [self] _ in
            let flag = CancellationFlag()
            let progress = QuitProgress()
            let answer = OnceAnswer(reply)
            answer.onAnswer = { [self] quits in
                progress.close()
                quitProgress = nil
                // The program goes on: jobs are the user's to stop again.
                if !quits {
                    jobService.isQuitting = false
                }
            }
            progress.onQuitNow = {
                flag.cancel()
                // A plugin that does not even give up is not waited for for ever.
                answer.stopWaiting = MainLoop.after(patience) { answer.give(true) }
            }
            progress.onDontQuit = { answer.give(false) }
            quitProgress = progress
            jobService.isQuitting = true
            kernel.prepareToQuit(cancellation: flag) { MainLoop.perform { answer.give(true) } }
            if !answer.isGiven {
                progress.show(after: progressDelay)
            }
        }
    }

    /// Stops the file jobs and lets them tidy up before the program quits, so no half-written
    /// file is left behind.
    ///
    /// `reply` is called once, on the main thread, with true when the program may quit: at
    /// once when nothing runs, otherwise when the last job has ended. A job that has not
    /// stopped after `patience` (it waits for a disk or a server that does not answer) does not
    /// keep the program from quitting for ever: the user is asked whether to quit anyway, and
    /// again after twice as long each time the answer is no.
    @preconcurrency
    public func stopJobsToQuit(
        patience: TimeInterval = Shell.quitPatience,
        then reply: @escaping @MainActor (Bool) -> Void
    ) {
        guard jobService.isBusy else {
            reply(true)
            return
        }
        let answer = OnceAnswer(reply)
        let (service, interaction) = (jobService, kernel.interaction)
        func ask(after wait: TimeInterval) {
            answer.stopWaiting = MainLoop.after(wait) {
                guard !answer.isGiven, service.isBusy else {
                    return
                }
                if Self.quitsAnyway(asking: interaction) {
                    answer.give(true)
                } else if !answer.isGiven {
                    ask(after: wait * 2)
                }
            }
        }
        service.isQuitting = true
        service.cancelAll { answer.give(true) }
        if !answer.isGiven {
            ask(after: patience)
        }
    }

    /// The menu bar of the program: the plugins' menus with the Mac's own around them.
    public func makeMainMenu() -> NSMenu {
        MenuBuilder.mainMenu(appName: kernel.productName, kernel: kernel)
    }

    /// Puts the main window on screen and in front.
    public func showMainWindow() {
        mainWindow.showWindow(nil)
    }

    /// Opens the configuration dialog, when a plugin provides one (the Mac's "Settings…").
    public func showSettings() {
        kernel.commands.perform(.configuration)
    }

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

    /// Lets the panels and the jobs follow each other.
    ///
    /// Reading ahead rests while the user works elsewhere and while a job runs; the bars are
    /// checked again when either changes; the panels are read again when the last job ended;
    /// and the user is asked about a job that does not stop.
    private func connectJobsAndPanels() {
        panelCoordinator.isWindowActive = { [weak self] in
            NSApp.isActive && self?.mainWindow.window?.isKeyWindow == true
        }
        jobService.onBusyChanged = { [weak self, weak jobService] in
            self?.panelCoordinator.updateReadAhead()
            self?.mainWindow.scheduleValidation()
            if jobService?.isBusy == false {
                self?.panelCoordinator.jobsEnded()
            }
        }
        panelCoordinator.onActivityChanged = { [weak self] in self?.mainWindow.scheduleValidation() }
        let interaction = kernel.interaction
        jobService.askToAbandon = { title in
            interaction.choose(
                "“\(title)” does not stop.",
                detail: "It may be waiting for a disk or a server that does not answer. You can go on waiting, or stop "
                    + "waiting and use the program again; the operation then ends by itself as soon as the disk or "
                    + "server lets it.",
                buttons: ["Stop Waiting", "Keep Waiting"],
                style: .warning,
                defaultButton: 1
            ) == 0
        }
    }

    deinit {
        // Nothing to release: the window and the panels go with the shell.
    }
}
