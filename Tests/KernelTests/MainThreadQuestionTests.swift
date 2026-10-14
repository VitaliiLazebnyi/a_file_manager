import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Questions and answers that cross to the main thread (review 2, cross-requests): a question to
/// the user from another thread, and the answer to a blocking question.
@MainActor
@Suite
internal struct MainThreadQuestionTests {
    /// A question asked from another thread is put on the main thread and its answer handed
    /// back; asked on the main thread, it is asked there at once.
    @Test
    internal func aQuestionFromAnotherThreadIsAskedOnTheMainThread() async {
        let interaction = ScriptedInteraction()
        interaction.choiceAnswers = [1]
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: interaction)
        let answer: (Int, Bool) = await withCheckedContinuation { continuation in
            OtherThread.start {
                // Written on the main thread while this thread waits for the answer.
                nonisolated(unsafe) var onMain = false
                let chosen = kernel.askUser { @Sendable asked -> Int in
                    onMain = Thread.isMainThread
                    return asked.choose(
                        "Go on?",
                        detail: "",
                        buttons: ["Yes", "No"],
                        style: .warning,
                        defaultButton: nil
                    )
                }
                continuation.resume(returning: (chosen, onMain))
            }
        }
        #expect(answer.0 == 1)
        #expect(answer.1)
        #expect(kernel.askUser { _ in 7 } == 7)
    }

    /// The answer is delivered on the main thread; a question given up delivers nil, once, and
    /// the answer that comes later is dropped.
    @Test
    internal func anAnswerToABlockingQuestionCanBeDeliveredToTheMainThread() async {
        let owner = NSObject()
        var onMain = false
        let value: Int? = await withCheckedContinuation { continuation in
            BlockingCalls.answer(
                from: owner,
                to: "quick",
                { _ in 5 },
                then: { (answer: Int?) in
                    onMain = Thread.isMainThread
                    continuation.resume(returning: answer)
                }
            )
        }
        #expect(value == 5)
        #expect(onMain)
        // Given up before the answer: nil is delivered, once, and the answer that comes later is dropped.
        let (flag, release) = (CancellationFlag(), DispatchSemaphore(value: 0))
        var delivered = 0
        let none: Int? = await withCheckedContinuation { continuation in
            BlockingCalls.answer(
                from: owner,
                to: "slow",
                cancellation: flag,
                { _ -> Int in
                    _ = release.wait(timeout: .now() + Wait.ceiling)
                    return 1
                },
                then: { (answer: Int?) in
                    delivered += 1
                    continuation.resume(returning: answer)
                }
            )
            flag.cancel()
        }
        release.signal()
        #expect(none == nil)
        // The main queue comes round once more: nothing else was delivered.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            BlockingCalls.answer(from: owner, to: "after", { _ in 0 }, then: { (_: Int?) in continuation.resume() })
        }
        #expect(delivered == 1)
    }
}
