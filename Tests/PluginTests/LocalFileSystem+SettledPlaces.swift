import AFMKernel
import Foundation
import TestSupport

@testable import LocalFileSystemPlugin

/// The places as the tests want them: after the first reading.
extension LocalFileSystem {
    /// `places()` once the first read in the background has landed (it never waits itself), or as
    /// they are when that has not happened within `Wait.ceiling`.
    internal func settledPlaces() -> [Place] {
        let end = Date().addingTimeInterval(Wait.ceiling)
        var places = self.places()
        while !places.contains(where: { $0.url.path == "/" }), Date() < end {
            Thread.sleep(forTimeInterval: 0.02)
            places = self.places()
        }
        return places
    }
}
