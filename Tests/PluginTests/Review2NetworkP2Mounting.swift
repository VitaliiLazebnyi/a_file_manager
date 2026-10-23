import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// Mounting and ejecting through the system with the system's calls replaced (N066, N103):
/// a mount that is never answered is taken back on Cancel, and an eject that is never
/// answered is given up after its time.
@Suite
internal struct Review2NetworkP2Mounting {
    /// A mount the system never answers is cancelled with the system when the flag is set.
    @Test
    internal func aMountThatIsNeverAnsweredIsTakenBackWhenItIsCancelled() throws {
        let cancelled = Shared<[Int]>([])
        let answers = Shared<[(Int32, CFArray?) -> Void]>([])
        var calls = SystemVolumeMounter.Calls.mounting(request: 0x5EED) { _, answer in
            answers.modify { $0.append(answer) }
            return 0
        }
        calls.cancel = { request in
            cancelled.modify { $0.append(Int(bitPattern: request)) }
            return 0
        }
        let mounter = SystemVolumeMounter(calls: calls, unmountTime: 600)
        let flag = CancellationFlag()
        let share = try #require(URL(string: "smb://anna:secret@dead.invalid/share"))
        let outcome = AdoptOutcome { _ = try mounter.mount(share, cancellation: flag) }
        #expect(adoptWait { answers.value.count == 1 })
        #expect(!outcome.ended(within: 0.3), "the mount did not wait for the system")
        flag.cancel()
        #expect(outcome.ended() && outcome.failed)
        #expect(cancelled.value == [0x5EED])
        // The system's answer that comes after all goes nowhere, and harms nothing.
        answers.value.first?(0, ["/Volumes/share"] as CFArray)
    }

    /// A mount gives the system's mount points, and a failure's message names no password.
    @Test
    internal func aMountIsAnsweredAndAFailureNamesNoPassword() throws {
        let share = try #require(URL(string: "smb://host.invalid/share"))
        var calls = SystemVolumeMounter.Calls.mounting(request: 0) { _, answer in
            OtherThread.start { answer(0, ["/Volumes/share"] as CFArray) }
            return 0
        }
        let mounter = SystemVolumeMounter(calls: calls, unmountTime: 600)
        #expect(try mounter.mount(share).map(\.path) == ["/Volumes/share"])
        // A mount that names no mount point.
        calls = .mounting(request: 0) { _, answer in
            OtherThread.start { answer(0, nil) }
            return 0
        }
        #expect(try SystemVolumeMounter(calls: calls, unmountTime: 600).mount(share).isEmpty)

        calls = .mounting(request: 0) { _, answer in
            OtherThread.start { answer(ECONNREFUSED, [] as CFArray) }
            return 0
        }
        let refused = SystemVolumeMounter(calls: calls, unmountTime: 600)
        let withPassword = try #require(URL(string: "smb://anna:secret@host.invalid/share"))
        do {
            _ = try refused.mount(withPassword)
            Issue.record("the mount did not fail")
        } catch {
            #expect(
                !error.localizedDescription.contains("secret") && error.localizedDescription.contains("host.invalid")
            )
        }
        // The system refuses to even start.
        calls = .mounting(request: 0) { _, _ in EINVAL }
        #expect(throws: VolumeError.self) {
            _ = try SystemVolumeMounter(calls: calls, unmountTime: 600).mount(share)
        }
    }

    /// An eject the system never answers fails after the mounter's time; one answered in time gives the answer.
    @Test
    internal func anEjectThatIsNeverAnsweredIsGivenUpAfterItsTime() throws {
        let answers = Shared<[((any Error)?) -> Void]>([])
        var calls = SystemVolumeMounter.Calls()
        calls.unmount = { _, answer in answers.modify { $0.append(answer) } }
        // The time is the mounter's own, shortened here; the real one is a minute.
        let mounter = SystemVolumeMounter(calls: calls, unmountTime: 0.3)
        #expect(SystemVolumeMounter.unmountTime == 60)
        #expect(throws: VolumeError.self) { try mounter.unmount(URL(fileURLWithPath: "/Volumes/gone")) }
        // An answer that comes late harms nothing.
        answers.value.first?(nil)

        // An answer in time: success, or the system's error.
        calls.unmount = { _, answer in OtherThread.start { answer(nil) } }
        try SystemVolumeMounter(calls: calls, unmountTime: 600).unmount(URL(fileURLWithPath: "/Volumes/x"))
        calls.unmount = { _, answer in OtherThread.start { answer(POSIXError(.EBUSY)) } }
        #expect(throws: POSIXError.self) {
            try SystemVolumeMounter(calls: calls, unmountTime: 600).unmount(URL(fileURLWithPath: "/Volumes/x"))
        }
    }
}
