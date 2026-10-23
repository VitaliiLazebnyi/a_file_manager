import Foundation

/// One entry of a bulk read (`getattrlistbulk`), as the listing and the measuring of trees read it.
extension LocalFileSystem {
    /// What a bulk read tells about one entry, before it becomes an item.
    internal struct Entry {
        /// The attributes asked for: name, kind and date of change.
        internal static let (wantName, wantType, wantModified) = (
            attrgroup_t(ATTR_CMN_NAME), attrgroup_t(ATTR_CMN_OBJTYPE), attrgroup_t(ATTR_CMN_MODTIME)
        )
        /// The attributes asked for: rights, flags and size.
        internal static let (wantMode, wantFlags, wantSize) = (
            attrgroup_t(ATTR_CMN_ACCESSMASK), attrgroup_t(ATTR_CMN_FLAGS), attrgroup_t(ATTR_FILE_DATALENGTH)
        )
        /// The error of an entry the system could not read.
        internal static let wantError = attrgroup_t(ATTR_CMN_ERROR)

        /// The entry's name in its folder.
        internal var name = ""
        /// The kind of node (`VREG`, `VDIR`, `VLNK` …).
        internal var type: UInt32 = 0
        /// The date of last change.
        internal var modified = Date(timeIntervalSince1970: 0)
        /// The rights and the kind bits.
        internal var mode: UInt32 = 0
        /// The flags (hidden, locked …).
        internal var flags: UInt32 = 0
        /// The size of the data, for a file.
        internal var size: Int64 = 0
        /// The system could not read the entry's attributes; they are asked for one by one.
        internal var failed = false
        /// The name is not valid UTF-8 (a volume that allows it: NFS, some FUSE).
        ///
        /// It was repaired for display, so a location made of it names no file; the entry is shown
        /// but not opened.
        internal var isNameRepaired = false

        /// A name with a dot first, or the hidden flag.
        internal var isHidden: Bool { name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0 }

        /// One entry of a bulk read, and its length: the length, which attributes follow, then
        /// those attributes in the order of their bits (an error, if any, comes first).
        ///
        /// Fields are packed to four bytes, hence the unaligned loads. What was not asked for, or
        /// not answered, keeps its default.
        @inline(__always)
        internal static func read(at entry: UnsafeRawPointer) -> (entry: Self, length: Int) {
            let length = Int(entry.loadUnaligned(as: UInt32.self))
            var field = entry + MemoryLayout<UInt32>.size
            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field += MemoryLayout<attribute_set_t>.size
            var read = Self()
            if returned.commonattr & wantError != 0 {
                read.failed = field.loadUnaligned(as: UInt32.self) != 0
                field += MemoryLayout<UInt32>.size
            }
            if returned.commonattr & wantName != 0 {
                let reference = field.loadUnaligned(as: attrreference_t.self)
                let bytes = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                // A name that is not UTF-8 is shown repaired.
                let validName = String(validatingCString: bytes)
                read.name = validName ?? String(cString: bytes)
                read.isNameRepaired = validName == nil
                field += MemoryLayout<attrreference_t>.size
            }
            if returned.commonattr & wantType != 0 {
                read.type = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<UInt32>.size
            }
            if returned.commonattr & wantModified != 0 {
                let time = field.loadUnaligned(as: timespec.self)
                read.modified = Date(
                    timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
                )
                field += MemoryLayout<timespec>.size
            }
            if returned.commonattr & wantMode != 0 {
                read.mode = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<UInt32>.size
            }
            if returned.commonattr & wantFlags != 0 {
                read.flags = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<UInt32>.size
            }
            if returned.fileattr & wantSize != 0 {
                read.size = field.loadUnaligned(as: Int64.self)
            }
            return (read, length)
        }
    }

    /// What an entry of a bulk read in the folder at `path` counts for: a folder to measure (its
    /// path), or a file of a size.
    ///
    /// Nil for what is neither (a link, a pipe) and for an entry that cannot be asked about.
    internal static func measured(_ entry: Entry, in path: String) -> (folder: String?, size: Int64)? {
        guard !entry.name.isEmpty else {
            return nil
        }
        let child = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
        var (type, size) = (entry.type, entry.size)
        if entry.failed {
            // The entry is asked by itself, as the listing does.
            var status = stat()
            guard lstat(child, &status) == 0 else {
                return nil
            }
            type =
                (status.st_mode & S_IFMT) == S_IFDIR
                ? VDIR.rawValue : ((status.st_mode & S_IFMT) == S_IFREG ? VREG.rawValue : 0)
            size = Int64(status.st_size)
        }
        guard type == VDIR.rawValue || type == VREG.rawValue else {
            return nil
        }
        return type == VDIR.rawValue ? (child, 0) : (nil, size)
    }
}
