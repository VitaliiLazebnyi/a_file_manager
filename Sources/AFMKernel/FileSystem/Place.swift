public import Foundation

/// An entry of the volume list: a disk, a mounted folder or a well-known place.
public struct Place: Sendable {
    public enum Kind: Sendable {
        case home, folder, internalDisk, externalDisk
    }

    public let name: String
    public let url: URL
    public let kind: Kind
    /// A drive that can be taken from the Mac: it gets an eject button. Never a disk inside
    /// the Mac (`VolumeTraits.mayBeEjected`), never a place that is not a volume.
    public let canBeEjected: Bool

    public init(name: String, url: URL, kind: Kind, canBeEjected: Bool = false) {
        self.name = name
        self.url = url
        self.kind = kind
        self.canBeEjected = canBeEjected
    }

    /// What the system says of a volume, as far as the volume list needs it; nil where it
    /// said nothing.
    public struct VolumeTraits: Sendable {
        /// Where the volume is mounted.
        public var path: String
        public var isRootFileSystem: Bool?
        public var isInternal: Bool?
        public var isLocal: Bool?
        public var isRemovable: Bool?
        public var isEjectable: Bool?

        /// A volume the system has said nothing about yet.
        public init(path: String) {
            self.path = path
        }

        /// What the system said, in the values of a location on the volume (nil: nothing).
        public init(path: String, values: URLResourceValues?) {
            self.path = path
            isRootFileSystem = values?.volumeIsRootFileSystem
            isInternal = values?.volumeIsInternal
            isLocal = values?.volumeIsLocal
            isRemovable = values?.volumeIsRemovable
            isEjectable = values?.volumeIsEjectable
        }

        /// The one rule for which volumes may be ejected. Never the start-up disk or a system
        /// volume, and never a disk built into the Mac; a USB stick, a card, a disk image, an
        /// external disk and a server's share may. A disk the system does not call external is
        /// taken for an internal one.
        public var mayBeEjected: Bool {
            if isRootFileSystem == true || path == "/" || path.hasPrefix("/System/") { return false }
            // A card in the Mac's own reader is internal and removable: it may go.
            if isEjectable == true || isRemovable == true { return true }
            if isLocal == false { return true }
            return isInternal == false
        }
    }
}
