import AFMKernel
import Foundation

/// Finding the folders of files to watch.
extension VirtualFileSystem {
    /// The folders some files are in, each once, as many as are watched (`watchLimit`): what a
    /// watcher of a list of files looks at.
    internal struct ParentFolders {
        /// The file systems that name the folder of each file.
        internal let fileSystems: FileSystemRegistry
        /// The folders found so far, in the order of the files.
        internal private(set) var found: [URL] = []
        private var keys = Set<[UInt8]>()
        /// The file system of each scheme, looked up once; nil inside for a scheme nobody serves.
        private var providers: [String: (any FileSystemProvider)?] = [:]

        /// As many folders were found as are watched; more files add nothing.
        internal var isFull: Bool { found.count >= VirtualFileSystem.watchLimit }

        /// Folders of the files the file systems of `fileSystems` hold.
        internal init(fileSystems: FileSystemRegistry) {
            self.fileSystems = fileSystems
        }

        /// Adds the folder of `file` when it is a new one and there is room for it.
        internal mutating func add(_ file: URL) {
            guard !isFull else {
                return
            }
            let scheme = file.scheme ?? "file"
            if providers[scheme] == nil { providers[scheme] = .some(try? fileSystems.provider(for: file)) }
            if let parent = providers[scheme]??.parent(of: file),
                keys.insert(VirtualFileSystem.identity(of: parent)).inserted
            {
                found.append(parent)
            }
        }
    }
}
