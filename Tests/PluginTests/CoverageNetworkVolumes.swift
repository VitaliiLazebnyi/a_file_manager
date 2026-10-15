import AFMKernel
import Foundation
import Testing

@testable import NetworkPlugin

/// Mounting and ejecting through the system, at the edges the other tests leave out.
@Suite
internal struct CoverageNetworkVolumes {
    /// A mount asked for after Cancel does not start.
    @Test
    internal func aMountAfterCancelDoesNotStart() throws {
        let mounter = CoverageNetworkMounter()
        let flag = CancellationFlag()
        flag.cancel()
        let share = try #require(URL(string: "smb://nas.invalid/share"))
        #expect(throws: NetworkError.self) { try mounter.mount(share, cancellation: flag) }
        #expect(mounter.mounted.isEmpty)
    }

    /// A status the system gives as a negative number is shown as such.
    @Test
    internal func aNegativeStatusIsShownAsANumber() throws {
        var calls = SystemVolumeMounter.Calls()
        calls.mount = { _, _ in (-5_999, nil) }
        let share = try #require(URL(string: "smb://nas.invalid/share"))
        let error = #expect(throws: VolumeError.self) {
            try SystemVolumeMounter(calls: calls, unmountTime: 60).mount(share)
        }
        #expect(error?.message == "The server smb://nas.invalid/share could not be connected: error -5999.")
    }

    /// The system's own eject refuses a folder that is no volume.
    @Test
    internal func theSystemDoesNotEjectAFolder() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #expect(throws: (any Error).self) { try SystemVolumeMounter().unmount(folder) }
    }

    /// The system's own mount of a server that does not answer ends with Cancel.
    @Test
    internal func theSystemsMountEndsWithCancel() throws {
        // A server that takes the connection and never says a word.
        let listener = try TestFTPServer.listen()
        defer { close(listener) }
        let share = try #require(URL(string: "smb://127.0.0.1:\(TestFTPServer.port(of: listener))/share"))
        let flag = CancellationFlag()
        flag.cancel()
        #expect(throws: NetworkError.self) { try SystemVolumeMounter().mount(share, cancellation: flag) }
    }
}
