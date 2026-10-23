public import Foundation

/// What is known of the volume a folder is on.
public struct VolumeFacts: Equatable, Sendable {
    /// Where the volume is mounted; nil when the folder's volume is not known.
    public var url: URL?
    /// The volume's name as the Finder shows it; empty when not known.
    public var name = ""
    /// The volume may be ejected: a drive that can be taken out, or a share of a server.
    public var canBeEjected = false
    /// A share of a server: unmounted, there is no disk to eject.
    public var isNetwork = false

    /// Facts of the values given; the defaults stand for a volume nothing is known of.
    public init(url: URL? = nil, name: String = "", canBeEjected: Bool = false, isNetwork: Bool = false) {
        (self.url, self.name, self.canBeEjected, self.isNetwork) = (url, name, canBeEjected, isNetwork)
    }
}
