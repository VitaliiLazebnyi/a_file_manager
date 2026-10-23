/// Which members of an archive an operation takes: all of them, or those at some paths.
internal enum MemberChoice: Equatable {
    /// Every member.
    case all
    /// The members at these paths, in this order.
    case paths([String])

    /// The members of `entries` that are taken, in the order of `entries`.
    internal func pick(from entries: [ArchiveEntry]) -> [ArchiveEntry] {
        switch self {
        case .all:
            return entries

        case .paths(let paths):
            let wanted = Set(paths)
            return entries.filter { wanted.contains($0.path) }
        }
    }
}
