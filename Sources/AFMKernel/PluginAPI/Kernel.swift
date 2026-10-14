import Foundation

/// A feature of the program. A plugin registers what it provides (commands, menu entries,
/// file systems, openers, services) with the kernel when it starts, and keeps whatever state
/// it needs in itself. It never refers to another plugin.
public protocol Plugin: AnyObject {
    var name: String { get }
    /// Called once, before the window exists. Register here; use `kernel.panels` and
    /// `kernel.jobs` only later, inside command handlers.
    func start(in kernel: Kernel)
    /// Called once when the program quits, in the reverse order of `start`. On the main
    /// thread: it must return soon. Work that takes time (writing what is still in memory,
    /// uploads) belongs in `prepareToQuit`.
    func stop()
    /// Asked on the main thread when the user wants to quit, before anything is stopped. A
    /// plugin with work the user would lose (unsaved edits) asks its question here and
    /// returns false when the user cancels: the quit is then called off. The default is true.
    func shouldTerminate() -> Bool
    /// Called on the main thread once the quit is decided and before any plugin is stopped,
    /// so every service is still there. A plugin that has something to finish (changes not
    /// yet written) starts that work in the background and calls `completion`, on any thread
    /// and exactly once, when it is done or has given up because `cancellation` was set (the
    /// user did not want to wait). The default calls `completion` at once.
    func prepareToQuit(cancellation: CancellationFlag, completion: @escaping () -> Void)
}

extension Plugin {
    public func stop() {}
    public func shouldTerminate() -> Bool { true }
    public func prepareToQuit(cancellation: CancellationFlag, completion: @escaping () -> Void) { completion() }
}

/// What the window shell provides to plugins once it exists.
public protocol ShellServices: AnyObject {
    var panels: PanelSet { get }
    var jobs: JobService { get }
}

/// The kernel has no features of its own. It holds the registries plugins fill and the
/// services they share, and it is the only thing plugins and the shell have in common.
/// Except where a member says otherwise, the kernel is used on the main thread.
public final class Kernel {
    /// The program's name, for window titles and dialogs.
    public let productName: String
    public let keyBindings: KeyBindings
    public let commands: CommandRegistry
    public let menus = MenuRegistry()
    public let fileSystems = FileSystemRegistry()
    public let openers = OpenerRegistry()
    public let services = ServiceRegistry()
    /// Columns plugins add to the file list.
    public let columns = ColumnRegistry()
    /// The buttons of the button bar.
    public let toolbar = ToolbarRegistry()
    /// The pages of the configuration dialog.
    public let preferences = PreferenceRegistry()
    /// What the plugins say about the settings they keep: which are histories, which can
    /// run something, which decide whom to trust.
    public let settingsKeys = SettingsKeyRegistry()
    /// What happens in the panels, for plugins that follow them.
    public let panelEvents = PanelEvents()
    public let settings: SettingsStore
    public let ui: UserInteraction
    /// Listings of slow folders, remembered so that returning to one is immediate. Unlike the
    /// rest of the kernel it is used from any thread. The panels fill and empty it; plugins
    /// have no business with it (they report changed folders through `panels.refresh`).
    public let listingCache = ListingCache()
    public private(set) var plugins: [Plugin] = []
    private var shell: ShellServices?

    public init(productName: String, settings: SettingsStore, ui: UserInteraction) {
        self.productName = productName
        self.settings = settings
        self.ui = ui
        keyBindings = KeyBindings()
        commands = CommandRegistry(keyBindings: keyBindings)
        listingCache.isEnabled = settings.value(Bool.self, forKey: ListingCache.settingsKey) ?? true
        // Nothing can run before the panels exist.
        commands.isBlocked = { true }
        _ = Kernel.ignoreBrokenPipes
    }

    /// Writing to a pipe or socket whose other end has gone (a helper program that ended, a
    /// server that hung up) must fail with an error like any other write. Left alone, the
    /// system ends the whole program for it. Done once, before any plugin starts.
    ///
    /// The signal is caught by a handler that does nothing, not set to be ignored: "ignored"
    /// is passed on to every program this one starts (a shell command of the user's, `ssh`),
    /// which would then no longer end when the reader of its output goes away; a handler is
    /// not passed on. A handler that is installed already (by whoever embeds the kernel) is
    /// left alone.
    private static let ignoreBrokenPipes: Void = {
        var current = sigaction()
        guard sigaction(SIGPIPE, nil, &current) == 0,
            unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == 0
        else { return }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGPIPE, &action, nil)
    }()

    /// Starts the plugins in the given order. The order decides where their entries appear
    /// inside a menu section and which plugin's file system is listed first.
    public func load(_ plugins: [Plugin]) {
        for plugin in plugins {
            self.plugins.append(plugin)
            plugin.start(in: self)
        }
    }

    /// Called by the shell when its panels exist. The user's key bindings are applied on top
    /// of the plugins' defaults, and commands may run from then on.
    public func attach(_ shell: ShellServices) {
        self.shell = shell
        keyBindings.load(from: settings)
        commands.isBlocked = { [unowned shell] in shell.jobs.isBusy }
    }

    /// Stops the plugins when the program quits.
    public func shutdown() {
        plugins.reversed().forEach { $0.stop() }
    }

    /// Asks every plugin whether the program may quit (`Plugin.shouldTerminate`), in the
    /// order they were started; false as soon as one says no. Main thread.
    public func shouldTerminate() -> Bool {
        plugins.allSatisfy { $0.shouldTerminate() }
    }

    /// Lets every plugin finish what it has to before the program quits
    /// (`Plugin.prepareToQuit`), all at the same time, and calls `completion` on the main
    /// thread when the last one is done. Called on the main thread, by the shell, after the
    /// quit is decided and before `shutdown`; setting `cancellation` tells the plugins not to
    /// keep the user waiting.
    public func prepareToQuit(cancellation: CancellationFlag, completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for plugin in plugins {
            group.enter()
            // A plugin that answers twice must not end the wait for the others.
            let lock = NSLock()
            var isDone = false
            plugin.prepareToQuit(cancellation: cancellation) {
                lock.lock()
                let isFirst = !isDone
                isDone = true
                lock.unlock()
                if isFirst { group.leave() }
            }
        }
        group.notify(queue: .main, execute: completion)
    }

    private var attachedShell: ShellServices {
        guard let shell else {
            preconditionFailure("The shell is not attached yet; use panels and jobs inside command handlers only.")
        }
        return shell
    }

    /// The two file panels. Available to command handlers, not while a plugin starts.
    public var panels: PanelSet { attachedShell.panels }
    /// Runs long work with a progress window.
    public var jobs: JobService { attachedShell.jobs }

    /// Asks the user something from any thread and waits for the answer: the route for a file
    /// system that needs, say, a password in the middle of a job. Inside a job prefer
    /// `JobMonitor.ask`, which also keeps the progress window correct.
    public func askUser<Answer>(_ question: (UserInteraction) -> Answer) -> Answer {
        if Thread.isMainThread { return question(ui) }
        // Work that the main thread itself is waiting for must not wait for it.
        Parallel.assertMayWaitForMainThread()
        // The question is put to the main thread through its run loop, not as a block of the
        // main dispatch queue: a dialog that is shown from inside such a block keeps every
        // later block of that queue waiting until it is closed (pieces of a directory,
        // progress, timers). Where no run loop turns (a program without windows), the queue
        // is the way after all; whichever comes first asks, the other finds nothing to do.
        let ui = self.ui
        let hop = MainThreadHop()
        var answer: Answer?
        withoutActuallyEscaping(question) { question in
            hop.work = { answer = question(ui) }
            let block = { hop.run() }
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(CFRunLoopGetMain())
            if hop.done.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                DispatchQueue.main.async(execute: block)
                hop.done.wait()
            }
            // Whichever block ran has let go of the question; the other holds only the hop.
        }
        return answer!
    }
}

/// One piece of work for the main thread that may be offered to it in more than one way and
/// is done once.
private final class MainThreadHop {
    private let lock = NSLock()
    var work: (() -> Void)?
    let done = DispatchSemaphore(value: 0)

    /// Does the work unless it was done; whoever waits is woken after the work has been let go of.
    func run() {
        lock.lock()
        var taken = work
        work = nil
        lock.unlock()
        guard taken != nil else { return }
        taken?()
        taken = nil
        done.signal()
    }
}

/// What kind of thing a settings key holds, for whoever exports or imports settings.
public enum SettingsKeyKind {
    /// A preference or a piece of state.
    case ordinary
    /// What the user did (lines typed, folders visited): left out of exports.
    case history
    /// Holds something that is run (a command line, a program to start): taken from a file
    /// only when the user says so.
    case runsCode
    /// Decides whom the program trusts (a server's certificate or key).
    case trust
    /// The address and account of a server.
    case connection
}

/// The settings keys the plugins have declared. Filled while the plugins start; main thread.
public final class SettingsKeyRegistry {
    public struct Declaration {
        /// The key, or for a family of keys what they all begin with.
        public let key: String
        public let isPrefix: Bool
        public let kind: SettingsKeyKind
        /// Whether a value read from a file may be stored under the key; nil accepts any.
        public let check: ((Data) -> Bool)?
    }

    private var exact: [String: Declaration] = [:]
    private var families: [Declaration] = []

    public init() {}

    /// Says what a key of the plugin's is. Declaring a key twice keeps the later word.
    public func declare(_ key: String, kind: SettingsKeyKind = .ordinary, check: ((Data) -> Bool)? = nil) {
        exact[key] = Declaration(key: key, isPrefix: false, kind: kind, check: check)
    }

    /// The same for every key that begins with `prefix` (`findFiles.history.`).
    public func declare(prefix: String, kind: SettingsKeyKind = .ordinary, check: ((Data) -> Bool)? = nil) {
        families.removeAll { $0.key == prefix }
        families.append(Declaration(key: prefix, isPrefix: true, kind: kind, check: check))
    }

    /// What was declared for a key: the key itself, else the longest family it belongs to.
    public func declaration(for key: String) -> Declaration? {
        exact[key]
            ?? families.filter { key.utf8.starts(with: $0.key.utf8) }.max { $0.key.utf8.count < $1.key.utf8.count }
    }

    public func kind(of key: String) -> SettingsKeyKind? { declaration(for: key)?.kind }

    /// Whether `data` may be stored under `key`: the key is declared and its check, if it has one, passes.
    public func accepts(_ data: Data, forKey key: String) -> Bool {
        guard let declaration = declaration(for: key) else { return false }
        return declaration.check?(data) ?? true
    }

    /// Everything declared, single keys first.
    public var all: [Declaration] { exact.values.sorted { $0.key < $1.key } + families }
}

/// Typed services one plugin offers to the others, found by their protocol.
public final class ServiceRegistry {
    private var services: [ObjectIdentifier: Any] = [:]

    public func register<Service>(_ type: Service.Type, _ service: Service) {
        precondition(services[ObjectIdentifier(type)] == nil, "The service \(type) is offered twice")
        services[ObjectIdentifier(type)] = service
    }

    public func find<Service>(_ type: Service.Type) -> Service? {
        services[ObjectIdentifier(type)] as? Service
    }
}

/// Values remembered between sessions.
public protocol SettingsStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    /// A value that may be large (megabytes: a long history) and is read and written as a
    /// whole. A store that keeps such values apart from the small ones (a file each, written
    /// in the background) offers these two; the default keeps them with the rest.
    func largeData(forKey key: String) -> Data?
    func setLarge(_ data: Data?, forKey key: String)
}

extension SettingsStore {
    public func largeData(forKey key: String) -> Data? { data(forKey: key) }
    public func setLarge(_ data: Data?, forKey key: String) { set(data, forKey: key) }

    public func value<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    public func set<Value: Encodable>(_ value: Value, forKey key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// Raw data is stored as it is. (Without this, `Data` would match the generic method above
    /// better than `Data?` and be stored as JSON text.)
    public func set(_ data: Data, forKey key: String) {
        set(data as Data?, forKey: key)
    }

    /// A plugin's own corner of the settings: its keys cannot clash with anyone else's.
    public func scoped(to owner: String) -> SettingsStore {
        ScopedSettings(base: self, prefix: owner + ".")
    }
}

private final class ScopedSettings: SettingsStore {
    private let base: SettingsStore
    private let prefix: String

    init(base: SettingsStore, prefix: String) {
        self.base = base
        self.prefix = prefix
    }

    func data(forKey key: String) -> Data? { base.data(forKey: prefix + key) }
    func set(_ data: Data?, forKey key: String) { base.set(data, forKey: prefix + key) }
    func largeData(forKey key: String) -> Data? { base.largeData(forKey: prefix + key) }
    func setLarge(_ data: Data?, forKey key: String) { base.setLarge(data, forKey: prefix + key) }
}

/// Settings that live only as long as the program runs; used by tests.
public final class MemorySettings: SettingsStore {
    private var values: [String: Data] = [:]

    public init() {}
    public func data(forKey key: String) -> Data? { values[key] }
    public func set(_ data: Data?, forKey key: String) { values[key] = data }
}
