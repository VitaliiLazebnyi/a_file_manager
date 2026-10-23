public import AFMKernel
public import Foundation

/// What a volume is called, how full it is and whether it is a disk of this Mac.
extension LocalFileSystem {
    /// The volume a location is on.
    ///
    /// A location that does not exist yet (the target of a copy that will create it) is answered
    /// for the nearest folder above it that does.
    ///
    /// Asking the disk can take for ever when it is a share that went away, and this is asked
    /// often (every listing, every job): the question is put on a thread of the kernel's own
    /// (`BlockingCalls`) and waited for for a moment. A volume is asked one question at a
    /// time: whoever asks while one is under way waits for the same answer, and once the
    /// volume has not answered in time, everybody is answered at once from what was last
    /// known, until the question comes back. `FileSystemRegistry.volumeInfoDidChange` then
    /// tells those who were given the old figures to ask again.
    public func volume(of url: URL) -> VolumeInfo? {
        volume(of: url, waitingUnless: nil)
    }

    /// The same, given up at once (with nil) when `cancellation` is set: the caller neither
    /// waits out the moment a volume is given, nor for a thread to ask on.
    ///
    /// The question itself is one the system cannot be made to take back; it stays with its thread,
    /// and while it is unanswered nobody asks that volume again (see above).
    public func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo? {
        volume(of: url, waitingUnless: cancellation)
    }

    /// The volume a path is on when a test stands in for the system: the test's own volume
    /// (the nearest folder above that it says is not local), else the real mount.
    internal func volumeKey(_ path: String) -> String {
        var current = path
        var remote: String?
        while current != "/", !current.isEmpty {
            if probes.isLocal?(current) == false { remote = current } else if remote != nil { break }
            current = Self.parentPath(of: current)
        }
        return remote ?? MountTable.shared.mount(containing: path).path
    }

    /// Asks the volume `url` is on once, or joins the question under way, and waits for the
    /// answer for a moment (or until `cancellation` is set).
    private func volume(of url: URL, waitingUnless cancellation: CancellationFlag?) -> VolumeInfo? {
        if cancellation?.isCancelled == true {
            return nil
        }
        let path = url.standardizedFileURL.path
        let isProbed = probes.isLocal != nil || probes.willAsk != nil
        let mount = isProbed ? volumeKey(path) : MountTable.shared.mount(containing: path).path
        let patience = UInt64(probes.volumePatience * 1_000_000_000)
        volumeLock.lock()
        let question: VolumeQuestion
        var isNew = false
        if let asked = volumeQuestions[mount] {
            question = asked
            if DispatchTime.now().uptimeNanoseconds &- asked.asked > patience {
                // The volume has not answered in time: what was last known, at once.
                asked.wasAnsweredFromMemory = true
                defer { volumeLock.unlock() }
                return rememberedVolume(at: mount)
            }
        } else {
            question = VolumeQuestion()
            volumeQuestions[mount] = question
            isNew = true
        }
        volumeLock.unlock()
        if isNew { ask(question, about: url, mountedAt: mount) }
        switch question.wait(until: question.asked &+ patience, cancellation) {
        case .answered(let info):
            return info

        case .cancelled:
            return nil

        case .late:
            volumeLock.lock()
            defer { volumeLock.unlock() }
            // Still the question that is unanswered? Then whoever asks next is not kept waiting either.
            if volumeQuestions[mount] === question { question.wasAnsweredFromMemory = true }
            return rememberedVolume(at: mount)
        }
    }

    /// What was last known of the volume at `mount`, or its folder name; called with
    /// `volumeLock` held.
    private func rememberedVolume(at mount: String) -> VolumeInfo {
        lastVolumes[mount]
            ?? VolumeInfo(
                name: URL(fileURLWithPath: mount).lastPathComponent,
                isLocal: probes.isLocal?(mount) ?? MountTable.shared.isLocal(mount)
            )
    }

    /// Puts `question` to the volume at `mount` on a thread of the kernel's own.
    ///
    /// If the volume never answers, it is that thread which stays, and not one of the few a
    /// dispatch queue has. One per volume: whoever asks meanwhile waits for the same answer.
    private func ask(_ question: VolumeQuestion, about url: URL, mountedAt mount: String) {
        BlockingCalls.run { [self] in
            let info = queryVolume(of: url)
            volumeLock.lock()
            if let info { lastVolumes[mount] = info }
            volumeQuestions[mount] = nil
            let wasMissed = question.wasAnsweredFromMemory
            volumeLock.unlock()
            question.finish(info)
            // Somebody was given the old figures meanwhile: they are told to ask again.
            if wasMissed {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: FileSystemRegistry.volumeInfoDidChange,
                        object: self,
                        userInfo: [
                            FileSystemRegistry.volumeRootKey: URL(fileURLWithPath: mount, isDirectory: true)
                        ]
                    )
                }
            }
        }
    }

    /// Asks the system, which may wait for as long as the volume likes (on a thread of its
    /// own: see `volume(of:)`).
    ///
    /// Nil when the volume does not answer the questions, which happens when it has gone meanwhile.
    private func queryVolume(of url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsLocalKey
        ]
        var existing = url.standardizedFileURL
        probes.willAsk?(existing.path)
        while existing.path != "/", !fileManager.fileExists(atPath: existing.path) {
            existing = existing.deletingLastPathComponent()
        }
        // A URL remembers what it was asked before; a fresh one gives today's free space.
        existing.removeAllCachedResourceValues()
        var info = statfs()
        guard let values = try? existing.resourceValues(forKeys: keys), let name = values.volumeName,
            probes.system("statfs", existing.path, { statfs(existing.path, &info) }) == 0
        else { return nil }
        let available =
            probes.freeSpace.map { $0(existing.path).available } ?? values.volumeAvailableCapacity.map(Int64.init)
        // Network shares report only the plain figure for free space.
        let free =
            freeForImportantUsage(
                on: existing,
                mountPoint: MountTable.mountPoint(of: info),
                fsid: info.f_fsid,
                available: available
            )
            ?? available ?? Int64(info.f_bavail) * Int64(info.f_bsize)
        // (Every volume that answers states its size and whether it is local.)
        return VolumeInfo(
            name: name,
            freeBytes: free,
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            isLocal: values.volumeIsLocal != false
        )
    }
}
