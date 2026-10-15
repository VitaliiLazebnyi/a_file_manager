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
        let calls = SystemVolumeMounter.Calls.mounting(request: 0) { _, _ in -5_999 }
        let share = try #require(URL(string: "smb://nas.invalid/share"))
        let error = #expect(throws: VolumeError.self) {
            try SystemVolumeMounter(calls: calls, unmountTime: 60).mount(share)
        }
        #expect(error?.message == "The server smb://nas.invalid/share could not be connected: error -5999.")
    }
}

/// The system's calls of a mounter with a stand-in for the mount.
extension SystemVolumeMounter.Calls {
    /// Calls whose mount hands `body` the address and a way to answer as the system does (the
    /// status and the mount points), and gives back `request` as what to cancel the mount with.
    internal static func mounting(
        request: Int,
        _ body: @escaping @Sendable (_ url: URL?, _ answer: @escaping @Sendable (Int32, CFArray?) -> Void) -> Int32
    ) -> Self {
        var calls = Self()
        calls.mount = { url, _, _, _, _, _, handle, _, report in
            handle?.pointee = UnsafeMutableRawPointer(bitPattern: request)
            return body(url.map { $0 as URL }) { status, paths in report?(status, nil, paths) }
        }
        return calls
    }
}
