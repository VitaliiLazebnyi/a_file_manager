import Foundation

public struct VolumeInfo: Equatable, Sendable {
    public let name: String
    public let freeBytes: Int64?
    public let totalBytes: Int64?
    /// False for network shares and other places where every question about a file travels:
    /// the panel then avoids anything that would ask about files one by one.
    public let isLocal: Bool

    public init(name: String, freeBytes: Int64? = nil, totalBytes: Int64? = nil, isLocal: Bool = true) {
        self.name = name
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.isLocal = isLocal
    }
}
