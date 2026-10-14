public import AFMKernel
public import Foundation

/// How the file system shows itself to the user: its paths, its place and its volume.
extension MemoryFileSystem {
    /// `<scheme>:<path>`, as the user sees a location (`mem:/work`).
    public func displayPath(_ url: URL) -> String {
        "\(scheme):\(decoded(key(url)))"
    }

    /// Reads both its own short notation (`mem:/work`) and the full URL (`mem:///work`).
    public func location(from text: String) -> URL? {
        guard text.hasPrefix(scheme + ":") else {
            return nil
        }
        let path = String(text.dropFirst(scheme.count + 1))
        return url(path.hasPrefix("//") ? String(path.drop { $0 == "/" }) : path)
    }

    /// One place, "Memory", at the root, shown as an external disk.
    public func places() -> [Place] {
        [Place(name: "Memory", url: url("/"), kind: .externalDisk)]
    }

    /// The volume "Memory", local or not as `isLocal` says.
    public func volume(of _: URL) -> VolumeInfo? {
        VolumeInfo(name: "Memory", isLocal: isLocal)
    }
}
