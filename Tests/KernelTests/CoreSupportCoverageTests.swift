import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Corners of the kernel's threads, questions and checks that the rest of the suite does not reach.
@Suite(.serialized)
internal struct CoreSupportCoverageTests {
    /// What a question to a file system is asked for.
    private final class Owner: Sendable {
        deinit {
            // Nothing to release.
        }
    }

    /// A question whose flag is set before it is asked is answered with nil, on the main thread,
    /// and never asked.
    @Test
    internal func aQuestionGivenUpBeforeItIsAskedIsAnsweredWithNil() async {
        let flag = CancellationFlag()
        flag.cancel()
        let asked = Shared(false)
        let answer: Int?? = await withCheckedContinuation { continuation in
            BlockingCalls.answer(
                from: Owner(),
                to: "core early",
                cancellation: flag,
                { _ -> Int in
                    asked.modify { $0 = true }
                    return 1
                },
                then: { (answer: Int?) in continuation.resume(returning: .some(answer)) }
            )
        }
        #expect(answer == .some(nil) && !asked.value)
    }

    /// While an owner has as many questions under way as it may, a second asker of a waiting
    /// question shares it, and one of the two giving up leaves it to the other.
    @Test
    internal func askersShareAQuestionThatWaitsItsTurn() {
        let owner = Owner()
        let release = DispatchSemaphore(value: 0)
        let started = Counter()
        let done = Counter()
        // Every place this owner has is taken by a question that waits.
        for index in 0..<64 {
            OtherThread.start {
                _ = BlockingCalls.answer(from: owner, to: "core busy \(index)") { _ -> Int in
                    started.add()
                    release.wait()
                    return index
                }
                done.add()
            }
        }
        #expect(Wait.until { started.count == 64 })
        let shared = Counter()
        let giving = CancellationFlag()
        let kept = Signal<Int?>()
        let gaveUp = Signal<Int?>()
        OtherThread.start {
            kept.set(
                BlockingCalls.answer(from: owner, to: "core shared") { _ -> Int in
                    shared.add()
                    return 9
                }
            )
        }
        // The second asker comes when the first one's question waits, and shares it.
        usleep(100_000)
        OtherThread.start {
            gaveUp.set(
                BlockingCalls.answer(from: owner, to: "core shared", cancellation: giving) { _ -> Int in
                    shared.add()
                    return 9
                }
            )
        }
        usleep(100_000)
        giving.cancel()
        #expect(gaveUp.wait() == .some(nil))
        for _ in 0..<64 {
            release.signal()
        }
        #expect(kept.wait() == .some(9))
        #expect(Wait.until { done.count == 64 })
        #expect(shared.count == 1)
    }

    /// A book of questions, the kernel's threads and a pool that were never used go when let go of.
    @Test
    internal func unusedPartsOfTheKernelGoWhenLetGoOf() {
        weak var book: CallBook?
        weak var threads: KernelThreads?
        weak var pool: ParallelPool?
        do {
            let (newBook, newThreads, newPool) = (CallBook(), KernelThreads(), ParallelPool(linger: 1))
            (book, threads, pool) = (newBook, newThreads, newPool)
            #expect(book != nil && threads != nil && pool != nil)
        }
        #expect(book == nil && threads == nil && pool == nil)
    }

    /// State of the main thread used from another thread is a bug that is logged with its name;
    /// on the main thread nothing is said.
    @Test
    internal func stateOfTheMainThreadUsedElsewhereIsLogged() throws {
        let start = Date()
        let done = Signal<Bool>()
        OtherThread.start {
            MainThread.assert("Core probe state")
            MainThread.assert()
            done.set(true)
        }
        #expect(done.wait() == true)
        let faults = try CoreLogged.faults(containing: "must be used on the main thread", since: start)
        #expect(faults.contains { $0.hasPrefix("Core probe state must be used on the main thread (") })
        #expect(faults.contains { $0.hasPrefix("This must be used on the main thread (") })
    }

    /// Work that the main thread waits for and that is about to wait for the main thread is a bug,
    /// which is logged; from a thread nobody waits for, nothing is said.
    @MainActor
    @Test
    internal func waitingForTheMainThreadFromWorkItWaitsForIsLogged() throws {
        let start = Date()
        _ = Parallel.map(Array(0..<4)) { _ in Parallel.assertMayWaitForMainThread() }
        Parallel.assertMayWaitForMainThread()
        let faults = try CoreLogged.faults(containing: "waits for the main thread (", since: start)
        #expect(faults.count == 4)
    }

    /// Work for a caller of low urgency, or of none, is done with the urgency of utility work at least.
    @Test
    internal func workForACallerOfLowOrNoUrgencyIsDone() {
        for urgency in [QualityOfService.background, .utility] {
            let sums = Signal<Int>()
            let thread = Thread {
                sums.set(Parallel.map(Array(0..<64)) { $0 }.reduce(0, +))
            }
            thread.qualityOfService = urgency
            thread.start()
            #expect(sums.wait() == 2_016)
        }
        // A plain POSIX thread has no urgency at all.
        let plain = Signal<Int>()
        var thread: pthread_t?
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_UNSPECIFIED, 0)
        defer { pthread_attr_destroy(&attributes) }
        let box = Unmanaged.passRetained(plain)
        pthread_create(
            &thread,
            &attributes,
            { argument in
                let signal = Unmanaged<Signal<Int>>.fromOpaque(argument).takeRetainedValue()
                signal.set(Parallel.map(Array(0..<64)) { $0 * 2 }.reduce(0, +))
                return nil
            },
            box.toOpaque()
        )
        #expect(plain.wait() == 4_032)
        if let thread {
            pthread_join(thread, nil)
        }
    }

    /// A link's target size can be forgotten again.
    @Test
    internal func aLinkTargetSizeCanBeForgotten() {
        var item = FileItem(url: URL(fileURLWithPath: "/a"), name: "a", linkTargetSize: 5)
        item.linkTargetSize = nil
        #expect(item.linkTargetSize == nil && item == FileItem(url: URL(fileURLWithPath: "/a"), name: "a"))
    }
}
