import Foundation
import os

/// The kernel has no features of its own.
///
/// It holds the registries plugins fill and the services they share, and it is the only thing plugins and the shell
/// have in common. Except where a member says otherwise, the kernel is used on the main thread.
@preconcurrency
@MainActor
public final class Kernel {
    /// One piece of work for the main thread that may be offered to it in more than one way and is done once.
    ///
    /// Unchecked: `work` is guarded by `lock`, and the thread that set it waits on `done` until it has run.
    nonisolated private final class MainThreadHop: @unchecked Sendable {
        /// Signalled once the work has run and been let go of.
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var work: (() -> Void)?

        /// Sets the work, before the hop is handed to the main thread.
        func offer(_ work: @escaping () -> Void) {
            lock.lock()
            self.work = work
            lock.unlock()
        }

        /// Does the work unless it was done; whoever waits is woken after the work has been
        /// let go of.
        func run() {
            lock.lock()
            var taken = work
            work = nil
            lock.unlock()
            guard taken != nil else {
                return
            }
            taken?()
            taken = nil
            done.signal()
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The shell's job service, whose completions come only while the kernel is there: once it
    /// has gone (the program or a test ended while a job ran), the plugins that would hear of a
    /// job went with it, and what they hold of it is no longer there to be read.
    private final class LivingJobs: JobService {
        private let service: any JobService
        private weak var kernel: Kernel?

        var isBusy: Bool { service.isBusy }

        init(_ service: any JobService, of kernel: Kernel) {
            self.service = service
            self.kernel = kernel
        }

        func run<Result: Sendable>(
            title: String,
            work: @escaping @Sendable (any JobMonitor) -> Result,
            completion: @escaping @MainActor (Result) -> Void
        ) {
            service.run(title: title, work: work) { [weak kernel] result in
                if kernel != nil { completion(result) }
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    private static let log = Log.logger("Kernel")
    private static let signposter = Log.signposter("Kernel")

    /// Writing to a pipe or socket whose other end has gone (a helper program that ended, a server that hung up) must
    /// fail with an error like any other write.
    ///
    /// Left alone, the system ends the whole program for it. Done once, before any plugin starts.
    ///
    /// The signal is caught by a handler that does nothing, not set to be ignored: "ignored"
    /// is passed on to every program this one starts (a shell command of the user's, `ssh`),
    /// which would then no longer end when the reader of its output goes away; a handler is
    /// not passed on. A handler that is installed already (by whoever embeds the kernel) is
    /// left alone.
    nonisolated private static let ignoreBrokenPipes: Void = catchBrokenPipes()

    /// The program's name, for window titles and dialogs.
    nonisolated public let productName: String
    /// Which key runs which command: the plugins' defaults and the user's own choices.
    public let keyBindings: KeyBindings
    /// Every command the plugins registered, and the one way to run them.
    public let commands: CommandRegistry
    /// Where the plugins' commands appear in the menu bar and the context menu.
    public let menus = MenuRegistry()
    /// The file systems the plugins provide.
    ///
    /// Any thread.
    nonisolated public let fileSystems = FileSystemRegistry()
    /// What opens a file when the user presses Enter on it.
    public let openers = OpenerRegistry()
    /// The services plugins offer each other.
    public let services = ServiceRegistry()
    /// Columns plugins add to the file list.
    ///
    /// Any thread.
    nonisolated public let columns = ColumnRegistry()
    /// The buttons of the button bar.
    public let toolbar = ToolbarRegistry()
    /// The pages of the configuration dialog.
    public let preferences = PreferenceRegistry()
    /// What the plugins say about the settings they keep: which are histories, which can
    /// run something, which decide whom to trust.
    public let settingsKeys = SettingsKeyRegistry()
    /// What happens in the panels, for plugins that follow them.
    public let panelEvents = PanelEvents()
    /// Values remembered between sessions.
    ///
    /// Any thread.
    nonisolated public let settings: any SettingsStore
    /// Where every question to the user goes.
    ///
    /// Reached from any thread; its questions are asked on the main thread (`askUser`).
    nonisolated public let interaction: any UserInteraction
    /// Listings of slow folders, remembered so that returning to one is immediate.
    ///
    /// Unlike the rest of the kernel it is used from any thread. The panels fill and empty it; plugins have no business
    /// with it (they report changed folders through `panels.refresh`).
    nonisolated public let listingCache = ListingCache()
    /// The plugins, in the order they were started.
    public private(set) var plugins: [any Plugin] = []
    /// Weak: the shell owns the kernel.
    private weak var shell: (any ShellServices)?

    /// The two file panels.
    ///
    /// Available to command handlers, not while a plugin starts.
    public var panels: any PanelSet { attachedShell.panels }
    /// Runs long work with a progress window. A job's completion is not called once the kernel
    /// has gone.
    public var jobs: any JobService { LivingJobs(attachedShell.jobs, of: self) }

    private var attachedShell: any ShellServices {
        guard let shell else {
            preconditionFailure("No shell is attached; use panels and jobs inside command handlers only.")
        }
        return shell
    }

    /// A kernel with empty registries; nothing runs until `attach` (the panels exist).
    public init(productName: String, settings: any SettingsStore, interaction: any UserInteraction) {
        self.productName = productName
        self.settings = settings
        self.interaction = interaction
        keyBindings = KeyBindings()
        commands = CommandRegistry(keyBindings: keyBindings)
        listingCache.isEnabled = settings.value(Bool.self, forKey: ListingCache.settingsKey) ?? true
        // Nothing can run before the panels exist.
        commands.isBlocked = { true }
        _ = Self.ignoreBrokenPipes
    }

    /// Installs the handler of `ignoreBrokenPipes` unless the signal has a handler already;
    /// any thread.
    nonisolated internal static func catchBrokenPipes() {
        var current = sigaction()
        guard sigaction(SIGPIPE, nil, &current) == 0,
            unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == 0
        else { return }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            // Nothing: the write that caused the signal fails with EPIPE instead.
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGPIPE, &action, nil)
    }

    /// Starts the plugins in the given order.
    ///
    /// The order decides where their entries appear inside a menu section and which plugin's file system is listed
    /// first.
    public func load(_ plugins: [any Plugin]) {
        for plugin in plugins {
            self.plugins.append(plugin)
            // How long each plugin takes to start, for Instruments.
            let interval = Self.signposter.beginInterval("start", id: .exclusive, "\(plugin.name, privacy: .public)")
            plugin.start(in: self)
            Self.signposter.endInterval("start", interval)
            Self.log.info("Started the plugin \(plugin.name, privacy: .public)")
        }
    }

    /// Called by the shell when its panels exist.
    ///
    /// The user's key bindings are applied on top of the plugins' defaults, and commands may run from then on.
    public func attach(_ shell: any ShellServices) {
        self.shell = shell
        keyBindings.load(from: settings)
        commands.isBlocked = { [weak shell] in shell?.jobs.isBusy ?? true }
    }

    /// Stops the plugins when the program quits.
    public func shutdown() {
        for plugin in plugins.reversed() { plugin.stop() }
        Self.log.info("Stopped \(self.plugins.count, privacy: .public) plugins")
    }

    /// Asks every plugin whether the program may quit (`Plugin.shouldTerminate`), in the order they were started; false
    /// as soon as one says no.
    ///
    /// Main thread.
    public func shouldTerminate() -> Bool {
        plugins.allSatisfy { $0.shouldTerminate() }
    }

    /// Lets every plugin finish what it has to before the program quits (`Plugin.prepareToQuit`), all at the same time,
    /// and calls `completion` on the main thread when the last one is done.
    ///
    /// Called on the main thread, by the shell, after the quit is decided and before `shutdown`; setting `cancellation`
    /// tells the plugins not to keep the user waiting.
    @preconcurrency
    public func prepareToQuit(cancellation: CancellationFlag, completion: @escaping @MainActor @Sendable () -> Void) {
        let group = DispatchGroup()
        for plugin in plugins {
            group.enter()
            // A plugin that answers twice must not end the wait for the others.
            let isDone = OSAllocatedUnfairLock(initialState: false)
            plugin.prepareToQuit(cancellation: cancellation) {
                let wasDone = isDone.withLock { done in
                    defer { done = true }
                    return done
                }
                if !wasDone { group.leave() }
            }
        }
        // Notified on the main queue.
        group.notify(queue: .main) { MainActor.assumeIsolated { completion() } }
    }

    /// Asks the user something from any thread and waits for the answer: the route for a file system that needs, say, a
    /// password in the middle of a job.
    ///
    /// Inside a job prefer `JobMonitor.ask`, which also keeps the progress window correct.
    @preconcurrency
    nonisolated public func askUser<Answer: Sendable>(
        _ question: @MainActor @Sendable (any UserInteraction) -> Answer
    ) -> Answer {
        let asked = interaction
        if Thread.isMainThread {
            return MainActor.assumeIsolated { question(asked) }
        }
        // Work that the main thread itself is waiting for must not wait for it.
        Parallel.assertMayWaitForMainThread()
        // The question is put to the main thread through its run loop, not as a block of the
        // main dispatch queue: a dialog that is shown from inside such a block keeps every
        // later block of that queue waiting until it is closed (pieces of a directory,
        // progress, timers). Where no run loop turns (a program without windows), the queue
        // is the way after all; whichever comes first asks, the other finds nothing to do.
        let hop = MainThreadHop()
        var answer: Answer?
        withoutActuallyEscaping(question) { question in
            hop.offer { answer = MainActor.assumeIsolated { question(asked) } }
            let block: @Sendable () -> Void = { hop.run() }
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(CFRunLoopGetMain())
            if hop.done.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                DispatchQueue.main.async(execute: block)
                hop.done.wait()
            }
            // Whichever block ran has let go of the question; the other holds only the hop.
        }
        // The wait above ends only after a block has run the question and set the answer.
        return answer.unsafelyUnwrapped
    }

    deinit {
        // Nothing to release.
    }
}
