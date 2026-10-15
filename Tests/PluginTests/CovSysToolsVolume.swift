import Foundation
import TestSupport

@testable import SystemToolsPlugin

/// A volume of the test's own: what it says of every folder, and what ejecting it answers.
internal final class CovSysToolsVolume: VolumeAccess, Sendable {
    /// What every folder is on.
    internal let facts: VolumeFacts
    /// What the next ejects answer, in order; without an answer the eject succeeds.
    internal let refusals = Shared<[EjectRefusal?]>([])
    /// How often it was ejected.
    internal let ejects = Shared(0)

    /// A volume that says `facts` of every folder.
    internal init(_ facts: VolumeFacts) {
        self.facts = facts
    }

    /// What the folder is on: always `facts`.
    internal func facts(of _: URL) -> VolumeFacts {
        facts
    }

    /// Counts the eject and answers with the next refusal.
    internal func eject(_: VolumeFacts) -> EjectRefusal? {
        ejects.modify { $0 += 1 }
        var refusal: EjectRefusal?
        refusals.modify { list in
            if let first = list.first {
                refusal = first
                list.removeFirst()
            }
        }
        return refusal
    }

    deinit {
        // Nothing to release.
    }
}
