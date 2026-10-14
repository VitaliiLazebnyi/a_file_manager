import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Quitting, as other areas asked the kernel for it in review 2 (documentation/review-2/cross-requests):
/// a plugin can call the quit off, and finish its work before the program ends.
@MainActor
@Suite
internal struct QuitTests {
    /// A plugin that says whether the program may quit and finishes its work when asked to.
    internal final class QuittingPlugin: Plugin {
        /// The name it was given.
        internal let name: String
        /// What it answers when asked whether the program may quit.
        internal var mayQuit = true
        /// How often it was asked whether the program may quit.
        internal var asked = 0
        /// How often it was stopped.
        internal var stopped = 0
        /// Finishes its work on another thread, a moment later, and answers twice.
        internal var finishesLate = false
        /// The flag it was given to prepare for quitting with.
        internal var sawFlag: CancellationFlag?

        /// A plugin called `name`.
        internal init(_ name: String) { self.name = name }

        /// Nothing to start.
        internal func start(in _: Kernel) {
            // It registers nothing.
        }

        /// Counts the stop.
        internal func stop() { stopped += 1 }

        /// Counts the question and answers `mayQuit`.
        internal func shouldTerminate() -> Bool {
            asked += 1
            return mayQuit
        }

        /// Notes the flag and says it is done, at once or (`finishesLate`) twice from another thread.
        internal func prepareToQuit(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void) {
            sawFlag = cancellation
            guard finishesLate else {
                completion()
                return
            }
            OtherThread.start {
                // The work it finishes takes a moment.
                usleep(20_000)
                completion()
                completion()
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A plugin with nothing to say about quitting.
    internal final class PlainPlugin: Plugin {
        /// `plain`.
        internal let name = "plain"

        /// Nothing to start.
        internal func start(in _: Kernel) {
            // It registers nothing.
        }

        deinit {
            // Nothing to release.
        }
    }

    /// One plugin saying no calls the quit off without the next one being asked; preparing to
    /// quit hands every plugin the flag and ends on the main thread, once, when the last is done.
    @Test
    internal func aPluginCanCallTheQuitOffAndFinishItsWorkBeforeIt() async {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let (first, second) = (QuittingPlugin("first"), QuittingPlugin("second"))
        kernel.load([first, PlainPlugin(), second])
        #expect(kernel.shouldTerminate())
        #expect(first.asked == 1)
        #expect(second.asked == 1)
        first.mayQuit = false
        #expect(!kernel.shouldTerminate())
        #expect(second.asked == 1)
        second.finishesLate = true
        let flag = CancellationFlag()
        var isOnMain = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            kernel.prepareToQuit(cancellation: flag) {
                isOnMain = Thread.isMainThread
                continuation.resume()
            }
        }
        #expect(isOnMain)
        #expect(first.sawFlag === flag)
        #expect(second.sawFlag === flag)
        #expect(first.stopped == 0)
    }
}
