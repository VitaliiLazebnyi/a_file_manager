public import AFMKernel
public import Foundation

/// How a virtual folder is named, typed and placed on a volume.
extension VirtualFileSystem {
    /// `/Users/x/dir (branch)`, `/Users/x/dir (selected branch 3)`, `Search result (list 7)`.
    public func displayPath(_ url: URL) -> String {
        switch VirtualLocation(url) {
        case .branch(let real):
            return fileSystems.displayPath(real) + " (branch)"

        case .picked(let id, let real):
            return fileSystems.displayPath(real) + " (selected branch \(id))"

        case .list(let id, let title, _):
            return "\(title) (list \(id))"

        case nil:
            return url.absoluteString
        }
    }

    /// Reads what `displayPath` writes, and the URL itself.
    public func location(from text: String) -> URL? {
        if text.lowercased().hasPrefix(scheme + ":") {
            return URL(string: text).flatMap { url in VirtualLocation(url) == nil ? nil : url }
        }
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else {
            return nil
        }
        let note = text[open.upperBound...].dropLast()
        let front = String(text[..<open.lowerBound])
        if note == "branch" {
            guard !front.isEmpty else {
                return nil
            }
            return branch(of: fileSystems.location(from: front, relativeTo: URL(fileURLWithPath: "/")))
        }
        for kind in ["selected branch ", "list "] where note.hasPrefix(kind) {
            guard let id = Int(note.dropFirst(kind.count)), let list = lists.list(id) else {
                return nil
            }
            // It must be what `displayPath` writes for the list: another text that merely ends
            // alike is not this list.
            return displayPath(list.location.url) == text ? list.location.url : nil
        }
        return nil
    }

    /// The volume of the real directory; for a list, a volume named after the search result that
    /// is local when its files are.
    public func volume(of url: URL) -> VolumeInfo? {
        guard let location = VirtualLocation(url) else {
            return nil
        }
        switch location {
        case .branch(let real), .picked(_, let real):
            return (try? fileSystems.provider(for: real))?.volume(of: real)

        case .list(let id, _, _):
            // Asked on the main thread: a list that is not prepared yet is judged by its first file.
            guard let list = lists.registered(id, as: location) else {
                return VolumeInfo(name: "Search result:", isLocal: true)
            }
            return VolumeInfo(
                name: "Search result:",
                isLocal: list.preparedIfReady?.isLocal ?? (list.raw.first?.isFileURL != false)
            )
        }
    }
}
