public import AFMKernel
public import Foundation

/// Moving and renaming within a volume.
extension LocalFileSystem {
    /// The name an item has in its folder, byte for byte as it is stored (a volume that ignores
    /// case or the form of accents answers to other spellings too; this is the one it keeps).
    ///
    /// Empty when it cannot be read (no name is empty).
    internal static func storedName(of url: URL) -> [UInt8] {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
        var reply = [UInt8](
            repeating: 0,
            count: 4 + MemoryLayout<attribute_set_t>.size + MemoryLayout<attrreference_t>.size + Int(NAME_MAX) * 4 + 8
        )
        guard getattrlist(url.path, &request, &reply, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            return []
        }
        return reply.withUnsafeBytes { raw in
            let offset = 4 + MemoryLayout<attribute_set_t>.size
            let reference = raw.loadUnaligned(fromByteOffset: offset, as: attrreference_t.self)
            // Kept inside the reply whatever the system says; its last bytes are always zero.
            let start = min(max(offset + Int(reference.attr_dataoffset), 0), raw.count - 1)
            return Array(raw[start...].prefix { $0 != 0 })
        }
    }

    /// Renames `source` to `destination`; an existing destination is refused unless `replacing`.
    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try moveItem(source, to: destination, replacing: replacing, LocalCall(probes))
    }

    /// The same; the flag ends a call that waits and keeps the next one from being begun.
    public func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try change(at: source, cancellation) { try self.moveItem(source, to: destination, replacing: replacing, $0) }
    }

    /// Renames, and sorts out what the system does not: two names of one file, a locked copy
    /// made here, a volume that cannot rename exclusively.
    private func moveItem(_ source: URL, to destination: URL, replacing: Bool, _ call: LocalCall) throws {
        let (origin, target) = (source.path, destination.path)
        // Without `replacing` the system itself refuses an existing destination, in the same
        // step as the rename, so nothing can slip in between a check and the move.
        // Renames, and returns the system's error number when that fails.
        func rename() throws -> Int32? {
            let result = try call.run(origin) {
                replacing
                    ? probes.system("rename", origin) { Darwin.rename(origin, target) }
                    : probes.system("renamex_np", origin) { renamex_np(origin, target, UInt32(RENAME_EXCL)) }
            }
            guard result != 0 else {
                return nil
            }
            guard errno == ENOTSUP, !replacing else {
                return errno
            }
            // A volume that cannot rename exclusively: check, then rename.
            var status = stat()
            if try call.run(target, { lstat(target, &status) }) == 0 { throw FileSystemError.alreadyExists(target) }
            return try call.run(origin) { Darwin.rename(origin, target) } == 0 ? nil : errno
        }
        // Two names of one file (hard links): rename(2) then does nothing and says it succeeded.
        // They are two names only if each is, letter for letter, an entry of its folder; a change
        // of the letters' case or of the accents' form names the same entry twice, and that is a
        // plain rename, after which nothing may be removed.
        var (before, after) = (stat(), stat())
        let areTwoLinks =
            try replacing && origin != target && call.run(origin) { lstat(origin, &before) } == 0
            && call.run(target) { lstat(target, &after) } == 0 && before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && Self.storedName(of: source) == Array(source.lastPathComponent.utf8)
            && Self.storedName(of: destination) == Array(destination.lastPathComponent.utf8)
        var code = try rename()
        // A locked file cannot be renamed. The copy of one that was made here (under a
        // temporary name, to be given its real name now) is unlocked for the moment of the
        // rename and ends up locked like the file it was copied from.
        if code == EPERM, let flags = unlockOwnCopy(source) {
            do {
                code = try rename()
            } catch {
                lchflags(origin, flags)
                throw error
            }
            lchflags(code == nil ? target : origin, flags)
        }
        if code == nil, areTwoLinks {
            // The other name of the file is taken away, so that the move has moved. Not
            // stopped half way by a flag: the rename has been done.
            guard probes.system("unlink", origin, { unlink(origin) }) == 0 else {
                throw Self.posixError(errno, source)
            }
        }
        switch code {
        case nil:
            forgetLockedCopy(source)

        case EXDEV:
            throw FileSystemError.crossesVolumes

        case EEXIST:
            throw FileSystemError.alreadyExists(target)

        case let code?:
            throw Self.posixError(code, source)
        }
    }
}
