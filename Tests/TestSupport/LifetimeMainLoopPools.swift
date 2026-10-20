import Foundation

/// The autorelease pool of the program's event loop, for the main run loop of a test process.
///
/// The program's event loop (`NSApplication.run`) keeps an autorelease pool around all it does and empties it after
/// every event. A test process turns the main run loop without it: Swift Testing's main executor runs the loop
/// plainly, and the loop has a pool only around each piece of work it calls (a block, a timer, an observer). When it
/// lets go of a block it ran, it does so after that pool, outside any pool, and AppKit hands it blocks that hold
/// controls (a combo box, a text view). A control freed there autoreleases what its `dealloc` touches, and that is
/// never released while the process lives. Worse, a window freed there takes every other window along: AppKit looks
/// for it in its list of windows, and reading that weak list autoreleases each window in it. So the window of a
/// program that a test stopped and let go of may stay, with its panels and kernel, until the process ends, because
/// another test let go of its window at the wrong moment.
///
/// `install()` gives that work a pool, emptied each time the loop wakes up: a block of its own is handed to the loop
/// then, and when the loop lets go of it, outside any pool, the pool of the last time is emptied and a new one
/// started. Main thread only.
@preconcurrency
@MainActor
public enum LifetimeMainLoopPools {
    /// `objc_autoreleasePoolPush` and `objc_autoreleasePoolPop`: what `@autoreleasepool` compiles to, with no Swift
    /// spelling for a pool that is started in one call and emptied in another.
    private typealias Push = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Pop = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// Does `action` when the main run loop lets go of the block that holds it.
    private final class Renewal {
        /// What is done then.
        let action: @MainActor () -> Void

        /// Does `action` when it goes.
        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        deinit {
            MainActor.assumeIsolated(action)
        }
    }

    /// The runtime's two functions, once installed.
    private static var pools: (push: Push, pop: Pop)?
    /// The pool that is filling now; nil until the first renewal.
    private static var pool: UnsafeMutableRawPointer?
    /// How often the main run loop runs inside itself now (a test, a menu or a combo box's list that runs it until
    /// something is done).
    private static var nesting = 0
    /// The observers on the main run loop.
    private static var observers: [CFRunLoopObserver] = []

    /// From here on, what the main run loop autoreleases outside its own pools is released each time it wakes up.
    ///
    /// Returns once the first pool is in place. Once per process; later calls only wait for that.
    public static func install() async {
        if pools == nil {
            pools = runtimePools()
            // Every run of the loop is counted, whatever its mode. The block that renews, and the observer that
            // hands it over, only in the default mode the main executor runs the loop in: a block counts as work
            // done, and a loop that runs until it has done something (the list of a combo box) must not end early
            // for it.
            observers = [
                observe(.entry, in: .commonModes) { nesting += 1 },
                observe(.exit, in: .commonModes) { nesting -= 1 },
                observe(.afterWaiting, in: .defaultMode) { handOver() }
            ]
            handOver()
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        await AppWait.until { pool != nil }
    }

    /// Calls `handler` at every `activity` of the main run loop in `mode`.
    private static func observe(
        _ activity: CFRunLoopActivity,
        in mode: CFRunLoopMode,
        _ handler: @escaping @MainActor () -> Void
    ) -> CFRunLoopObserver {
        let observer: CFRunLoopObserver = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated(handler)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, mode)
        return observer
    }

    /// Hands the main run loop a block that renews the pool when the loop lets go of it.
    private static func handOver() {
        let renewal = Renewal { renew() }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { _ = renewal }
    }

    /// Empties the pool and starts the next; only in the loop's own pass, where no other pool is open.
    ///
    /// A block let go of by a loop that runs inside the loop is let go of inside a pool of the outer pass, which is
    /// emptied after this one: nothing is done then, and the next wake-up renews.
    private static func renew() {
        guard nesting == 0, let pools else {
            return
        }
        if let pool {
            pools.pop(pool)
        }
        pool = pools.push()
    }

    /// The runtime's functions for starting and emptying a pool.
    private static func runtimePools() -> (push: Push, pop: Pop) {
        // RTLD_DEFAULT: the Objective-C runtime is in every process that uses Foundation.
        let runtime = UnsafeMutableRawPointer(bitPattern: -2)
        guard let push = dlsym(runtime, "objc_autoreleasePoolPush"), let pop = dlsym(runtime, "objc_autoreleasePoolPop")
        else {
            preconditionFailure("The Objective-C runtime has no autorelease pools")
        }
        return (unsafeBitCast(push, to: Push.self), unsafeBitCast(pop, to: Pop.self))
    }
}
