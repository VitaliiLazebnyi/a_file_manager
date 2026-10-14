public import Foundation

/// An entry of the volume list: a disk, a mounted folder or a well-known place.
public struct Place: Sendable {
    /// What a place is, for its picture and for where the list puts it.
    public enum Kind: Sendable {
        /// A disk that is not built into the Mac, or a share.
        case externalDisk
        /// A folder that is not a volume of its own.
        case folder
        /// The user's home folder.
        case home
        /// A disk built into the Mac, the start-up disk among them.
        case internalDisk
    }

    /// What the system said to one question about a volume.
    public enum Fact: Equatable, Sendable {
        /// The system answered yes or no.
        case known(Bool)
        /// The system said nothing.
        case unknown
    }

    /// What the system says of a volume, as far as the volume list needs it.
    public struct VolumeTraits: Sendable {
        /// Where the volume is mounted.
        public var path: String
        /// Whether it is the disk the Mac started from.
        public var isRootFileSystem = Fact.unknown
        /// Whether it is built into the Mac (a card in the Mac's own reader is too).
        public var isInternal = Fact.unknown
        /// Whether it is a disk of this Mac rather than a server's share.
        public var isLocal = Fact.unknown
        /// Whether its medium can be taken out (a card, a stick).
        public var isRemovable = Fact.unknown
        /// Whether the system itself would offer to eject it.
        public var isEjectable = Fact.unknown

        /// The one rule for which volumes may be ejected.
        ///
        /// Never the start-up disk or a system volume, and never a disk built into the Mac; a USB stick, a card, a disk
        /// image, an external disk and a server's share may. A disk the system does not call external is taken for an
        /// internal one.
        public var mayBeEjected: Bool {
            if isRootFileSystem == .known(true) || path == "/" || path.hasPrefix("/System/") {
                return false
            }
            // A card in the Mac's own reader is internal and removable: it may go.
            if isEjectable == .known(true) || isRemovable == .known(true) {
                return true
            }
            if isLocal == .known(false) {
                return true
            }
            return isInternal == .known(false)
        }

        /// A volume the system has said nothing about yet.
        public init(path: String) {
            self.path = path
        }

        /// What the system said, in the values of a location on the volume (nil: nothing).
        public init(path: String, values: URLResourceValues?) {
            self.path = path
            isRootFileSystem = values?.volumeIsRootFileSystem.map(Fact.known) ?? .unknown
            isInternal = values?.volumeIsInternal.map(Fact.known) ?? .unknown
            isLocal = values?.volumeIsLocal.map(Fact.known) ?? .unknown
            isRemovable = values?.volumeIsRemovable.map(Fact.known) ?? .unknown
            isEjectable = values?.volumeIsEjectable.map(Fact.known) ?? .unknown
        }
    }

    /// The name shown in the list.
    public let name: String
    /// Where the place is.
    public let url: URL
    /// What it is.
    public let kind: Kind
    /// A drive that can be taken from the Mac: it gets an eject button.
    ///
    /// Never a disk inside the Mac (`VolumeTraits.mayBeEjected`), never a place that is not a volume.
    public let canBeEjected: Bool

    /// A place of the list; one that cannot be ejected unless said otherwise.
    public init(name: String, url: URL, kind: Kind, canBeEjected: Bool = false) {
        self.name = name
        self.url = url
        self.kind = kind
        self.canBeEjected = canBeEjected
    }
}
