import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Blocking questions on the kernel's own threads, bounded (review 2, K004, K007, K040).
@Suite(.serialized)
internal struct BlockingCallTests {
    /// The owner the questions are asked of: what they are counted by.
    private final class Owner: Sendable {
        deinit {
            // Nothing to release.
        }
    }

    /// Waits for `release` to be signalled by the test, at most as long as any wait lasts.
    private static func hold(_ release: DispatchSemaphore) {
        _ = release.wait(timeout: .now() + Wait.ceiling)
    }

    /// Twelve threads that ask the same question while it is under way share one asking and its answer.
    @Test
    internal func theSameQuestionIsAskedOnceForAllWhoWait() {
        let owner = Owner()
        let (asked, back) = (Counter(), Counter())
        let release = DispatchSemaphore(value: 0)
        let answers = Counter()
        let done = Counter()
        for _ in 0..<12 {
            OtherThread.start {
                let answer = BlockingCalls.answer(from: owner, to: "volume /dead") { _ -> Int in
                    asked.add()
                    Self.hold(release)
                    back.add()
                    return 7
                }
                if answer == 7 {
                    answers.add()
                }
                done.add()
            }
        }
        #expect(Wait.until { asked.count == 1 })
        // Nobody else asks meanwhile: an absence, which no condition can show, so it is looked
        // for after a moment.
        usleep(50_000)
        #expect((asked.count, back.count) == (1, 0))
        release.signal()
        #expect(Wait.until { done.count == 12 })
        // Whoever came after the answer asked again; nobody asked while it was under way.
        for _ in 0..<12 {
            release.signal()
        }
        #expect(Wait.until { answers.count == 12 })
        #expect(Wait.until { back.count == asked.count })
    }

    /// Fifty tries at a question that does not answer, each given up, ask it once and are told
    /// so; other questions are not held up, and once it is back it can be asked afresh.
    @Test
    internal func aQuestionThatWasGivenUpIsNotAskedAgainUntilItComesBack() {
        let owner = Owner()
        let (asked, back) = (Counter(), Counter())
        let release = DispatchSemaphore(value: 0)
        let flags = Shared<[CancellationFlag]>([])
        for _ in 0..<50 {
            let cancellation = CancellationFlag()
            let returned = Signal<Bool>()
            OtherThread.start {
                let answer = BlockingCalls.answer(
                    from: owner,
                    to: "volume /dead",
                    cancellation: cancellation
                ) { flag -> Int in
                    flags.modify { $0.append(flag) }
                    asked.add()
                    Self.hold(release)
                    back.add()
                    return 1
                }
                returned.set(answer == nil)
            }
            #expect(Wait.until { asked.count >= 1 })
            cancellation.cancel()
            // Giving up ends the wait at once, though the question itself goes on.
            #expect(returned.wait() == true)
        }
        #expect((asked.count, back.count) == (1, 0))
        // The question was told that nobody waits.
        #expect(flags.value.first?.isCancelled == true)
        // Another question to the same owner, and the same one to another owner, are not held up.
        #expect(BlockingCalls.answer(from: owner, to: "volume /alive") { _ in 2 } == 2)
        #expect(BlockingCalls.answer(from: Owner(), to: "volume /dead") { _ in 3 } == 3)
        // Once it has come back, the question can be asked afresh.
        release.signal()
        #expect(Wait.until { back.count == 1 })
        release.signal()
        let fresh = BlockingCalls.answer(from: owner, to: "volume /dead") { _ -> Int in
            Self.hold(release)
            return 4
        }
        #expect(fresh == 4 && asked.count == 1)
    }

    /// No more than 64 questions of one owner are under way at once; the
    /// rest wait their turn and are all asked in the end.
    @Test
    internal func oneOwnerHasABoundedNumberOfQuestionsUnderWay() {
        let owner = Owner()
        // The kernel's bound.
        let limit = 64
        let started = Counter()
        let release = DispatchSemaphore(value: 0)
        let done = Counter()
        let total = limit + 10
        for index in 0..<total {
            OtherThread.start {
                _ = BlockingCalls.answer(from: owner, to: "item \(index)") { _ -> Int in
                    started.add()
                    Self.hold(release)
                    return index
                }
                done.add()
            }
        }
        #expect(Wait.until { started.count == limit })
        // No more start meanwhile: an absence, which no condition can show, so it is looked for
        // after a moment.
        usleep(50_000)
        #expect(started.count == limit)
        for _ in 0..<total {
            release.signal()
        }
        #expect(Wait.until { done.count == total })
        #expect(started.count == total)
    }

    /// Work runs on the kernel's own thread, not on a dispatch queue, and a long list handed
    /// to `Discard` is freed there.
    @Test
    internal func workRunsOffTheDispatchQueuesAndListsAreReleasedThere() {
        let name = Signal<String>()
        BlockingCalls.run { name.set(Thread.current.name ?? "") }
        #expect(name.wait() == "AFM.Blocking")
        // A long list of objects handed to `Discard` is freed without the caller doing it.
        let before = Tracked.count
        var list = (0..<(Discard.threshold + 5)).map { _ in Tracked() }
        #expect(Tracked.count == before + list.count)
        Discard.later(&list)
        #expect(list.isEmpty)
        #expect(Wait.until { Tracked.count == before })
    }
}
