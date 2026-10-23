import AFMKernel
import Foundation

/// The addresses the user typed in person (`ServerConsentService`): their servers count as
/// chosen.
///
/// A location of another file system, or one that names no server, is ignored.
internal final class TypedAddresses: ServerConsentService {
    /// The center told about each server the user chose.
    private let center: ConnectionCenter

    /// A service that tells `center` about the servers of typed addresses.
    internal init(center: ConnectionCenter) {
        self.center = center
    }

    /// Notes the server of `location` as chosen, so connecting to it asks nothing more.
    internal func userChose(_ location: URL) {
        guard let key = ServerKey(location), ServerKey.schemes.contains(key.scheme) else {
            return
        }
        center.noteChosen(key)
    }

    deinit {
        // Nothing to release.
    }
}
