import AFMKernel
import AppKit

/// The places the file systems offer for the volume lists and the drive buttons.
///
/// A file system is to answer `places()` at once, but one that has to look at its volumes
/// first may take its time, so the main thread never asks: each file system is asked on a
/// thread of the kernel's for calls that block (`BlockingCalls`), one question at a time, and
/// the list here is what they answered last. Asked again when volumes come and go, when a file
/// system says its places changed, and whenever a volume list is opened. Main thread only.
@MainActor
internal final class PlacesStore {
    /// Posted by a file system (the object) when its places are no longer what it answered.
    internal static let placesDidChange = Notification.Name("AFMPlacesDidChange")

    /// Every place, in the order of the file systems.
    internal private(set) var all: [Place] = []
    /// True once every file system has answered at least once.
    internal private(set) var isComplete = false
    /// The file systems asked, in order.
    private let providers: [any FileSystemProvider]
    /// What each file system answered last.
    private var answers: [[Place]]
    /// The file systems whose answer is awaited.
    private var asking: Set<Int> = []
    /// The file systems to be asked again when their answer is there.
    private var askAgain: Set<Int> = []
    /// The file systems that have answered at least once.
    private var answered: Set<Int> = []
    /// Called whenever `all` has changed.
    private var handlers: [() -> Void] = []
    /// The notifications listened to.
    ///
    /// Unchecked: filled in `init`, emptied in `deinit`, never touched in between.
    nonisolated(unsafe) private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    /// The places of every file system of `fileSystems`, asked for at once.
    internal init(fileSystems: FileSystemRegistry) {
        providers = fileSystems.all
        answers = Array(repeating: [], count: providers.count)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ] {
            listen(to: name, in: workspace)
        }
        listen(to: Self.placesDidChange, in: NotificationCenter.default)
        refresh()
    }

    /// Whether two lists name the same places, in the same order.
    private static func areSame(_ first: [Place], _ second: [Place]) -> Bool {
        first.count == second.count
            && zip(first, second).allSatisfy { $0.name == $1.name && $0.url == $1.url && $0.kind == $1.kind }
    }

    /// Calls `handler` on the main thread whenever `all` has changed.
    internal func observe(_ handler: @escaping () -> Void) {
        handlers.append(handler)
    }

    /// The window goes away: nobody hears of the places any more, and nothing asks for them.
    internal func stop() {
        handlers = []
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
    }

    /// Asks every file system for its places again.
    ///
    /// One that has not answered the last question yet is asked once more when it has.
    internal func refresh() {
        if providers.isEmpty {
            isComplete = true
        }
        for index in providers.indices {
            ask(index)
        }
    }

    /// Asks again whenever `center` posts `name`; the notifications arrive on the main queue.
    private func listen(to name: Notification.Name, in center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        observers.append((center, token))
    }

    /// Asks the `index`th file system, unless its answer to the last question is awaited.
    private func ask(_ index: Int) {
        guard asking.insert(index).inserted else {
            askAgain.insert(index)
            return
        }
        let provider = providers[index]
        // On one of the kernel's threads for calls that block; one question per file system
        // is out at a time, whoever asks.
        BlockingCalls.answer(
            from: provider as AnyObject,
            to: "places",
            { _ in provider.places() },
            then: { [weak self] answer in
                // Without a cancellation there always is an answer.
                if let answer {
                    self?.take(answer, from: index)
                }
            }
        )
    }

    /// Takes the answer of the `index`th file system; those who observe hear of a change.
    private func take(_ places: [Place], from index: Int) {
        asking.remove(index)
        answered.insert(index)
        let wasComplete = isComplete
        isComplete = answered.count == providers.count
        if !Self.areSame(places, answers[index]) || wasComplete != isComplete {
            answers[index] = places
            all = answers.flatMap(\.self)
            for handler in handlers {
                handler()
            }
        }
        if askAgain.remove(index) != nil {
            ask(index)
        }
    }

    deinit {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
    }
}
