import AFMContracts
import AFMKernel
import Foundation
import os

extension FileJob {
    internal func transferFolder(
        _ folder: FileItem,
        to destination: URL,
        position: CopyFilter.Position,
        isTopLevel: Bool,
        tree: URL?,
        depth: Int
    ) throws -> Outcome {
        let source = folder.url
        let verb: OperationRecord.Verb = isMove ? .move : .copy
        // A folder that is another volume is not emptied by a move without somebody saying so.
        if isMove, try !mayEnter(folder, for: .move) {
            // (Another volume is never taken for one rename.)
            add(measuredBefore(folder))
            record(verb, source, destination, .skipped)
            return .skipped
        }
        // With a filter a folder that gets no file may have to stay away: it is then created
        // with its first file.
        let createsLater = !options.filter.isEmpty && (options.filter.skipsEmptyFolders || !position.admitted)
        // The first count took this folder for one rename and counted it as one item.
        let predicted = isMove && predictedRenames.contains(source.locationKey)
        var movedWhole = false
        var createdHere = false
        let ready = try attempt(verb, at: source, target: destination) {
            if destination.isSameLocation(as: source) { throw FileJobError.copyToItself }
            if destination.isInside(source) || (isTopLevel && FileIdentity.isInside(destination, folder: source)) {
                throw FileJobError.intoOwnSubfolder(self.display(source))
            }
            if let existing = try self.entry(at: destination) {
                if FileIdentity.sameEntry(existing.url, source) {
                    // The folder under another spelling (letter case): a move renames it, a copy
                    // would merge it into itself.
                    guard self.isMove else { throw FileJobError.copyToItself }
                    try self.fileSystems.provider(for: source)
                        .move(
                            source,
                            to: destination,
                            replacing: true,
                            cancellation: self.cancellation
                        )
                    // (A folder whose name is taken, by itself, was not taken for one rename.)
                    self.add(self.measuredBefore(folder))
                    movedWhole = true
                    self.record(.move, source, destination, .done)
                    return true
                }
                // An existing folder is merged with the incoming one.
                guard existing.isRealDirectory else { throw FileJobError.targetIsFile(self.display(destination)) }
                return try self.mayMerge(into: existing, folder)
            }
            let (from, to) = (
                try self.fileSystems.provider(for: source), try self.fileSystems.provider(for: destination)
            )
            if self.isMove, from === to, self.options.filter.isEmpty {
                // A folder that does not exist at the target moves as a whole, when renaming can do it.
                // The size of what moves is known from the first count; only a folder that no one
                // has counted is walked, and it is not walked when the rename comes first.
                do {
                    try from.move(source, to: destination, replacing: false, cancellation: self.cancellation)
                    self.add(predicted ? Measure(items: 1) : self.measuredBefore(folder))
                    movedWhole = true
                    self.record(.move, source, destination, .done)
                    return true
                } catch FileSystemError.crossesVolumes {}
            }
            if !createsLater {
                try self.createFolder(destination, in: to)
                createdHere = true
                self.record(.makeFolder, destination, nil, .done)
            }
            return true
        }
        guard ready else {
            add(predicted ? Measure(items: 1) : measuredBefore(folder))
            return .skipped
        }
        if movedWhole {
            return Outcome(finished: true, emptied: true, target: destination)
        }
        if predicted {
            // The rename did not happen; the folder is copied item by item, so it counts as that.
            let inside = measure(folder)
            counters.withLock { total += Measure(items: inside.items - 1, bytes: inside.bytes) }
        }

        add(Measure(items: 1))
        // A folder whose contents could not be read was not transferred; it must stay.
        guard let listed = try listing(of: source) else {
            return .skipped
        }
        // Between two file systems the files are read in the order the source reads them best.
        var children = listed.items
        if !source.isFileURL, let from = try? fileSystems.provider(for: source),
            let to = try? fileSystems.provider(for: destination), from !== to
        {
            children = inReadOrder(children, from: from)
        }
        let batch = Batch(count: children.count)
        batch.isSerial =
            children.count == listed.items.count && zip(children, listed.items).contains { $0.url != $1.url }
        // A second source folder that lands in this target folder meets what the first one
        // brought; that is this job's own work and no rule "for all" overwrites it.
        batch.isShared = !enteredTargets.insert(Self.claimHash(destination)).inserted
        // Nothing of this folder is still being written when this function is left, however it is left.
        defer { batch.group.wait() }
        for (slot, child) in children.enumerated() {
            try autoreleasepool {
                let childTarget = destination.appending(name: child.name)
                report { ["From: \(self.display(child.url))", "To: \(self.display(childTarget))"] }
                try transfer(
                    child,
                    to: childTarget,
                    from: position,
                    batch: batch,
                    slot: slot,
                    tree: tree ?? source,
                    depth: depth + 1
                )
            }
        }
        let settled = batch.settled()
        if settled.cancelled { throw Cancelled() }
        // What was refused for its name stays where it is.
        var outcome = Outcome(
            finished: listed.rejected == 0 && settled.outcomes.allSatisfy { $0?.finished == true },
            emptied: listed.rejected == 0 && settled.outcomes.allSatisfy { $0?.emptied == true },
            target: destination
        )
        // A folder that waited for its first file (a filter was in the way) is the job's too, if one came.
        let madeLate = createsLater && !createdHere && (try? entry(at: destination)) != nil
        try finishFolder(folder, at: destination, createdHere: createdHere || madeLate)
        if isMove, outcome.emptied, defersRemovals {
            postponeRemoval(of: source, isFolder: true, tree: tree)
        } else if isMove, outcome.emptied {
            // The provider removes only an empty folder, so whatever was not moved survives.
            outcome.emptied = try attempt(.removeFolder, at: source) {
                try self.remove(source, below: tree)
                return true
            }
            outcome.finished = outcome.finished && outcome.emptied
        }
        // With a filter, a folder that was entered counts as processed (07 › Only files of this type).
        if !options.filter.isEmpty { outcome.finished = true }
        return outcome
    }

    /// A folder gets its attributes when everything is inside: before, a folder without write
    /// permission could not be filled, and filling it would change its date.
    private func finishFolder(_ folder: FileItem, at destination: URL, createdHere: Bool) throws {
        let attributes = FileAttributes(
            modified: options.preservesFolderDates ? folder.modified : nil,
            permissions: createdHere && options.preservesAttributes ? folder.permissions : nil
        )
        let to = try fileSystems.provider(for: destination)
        if attributes.modified != nil || attributes.permissions != nil {
            try? to.setAttributes(attributes, of: destination, cancellation: cancellation)
        }
        guard createdHere else {
            return
        }
        // Last of all: tags, flags and the date of creation come along, and a lock that does
        // would forbid the changes above. A file system that cannot do it does without.
        // The origin mark goes on before them: a lock among the flags would refuse it.
        if let origin = originMark(of: folder.url, copiedTo: destination) {
            mark(destination, with: origin, in: to, shownAs: folder.url)
        }
        if options.preservesAttributes {
            try? to.copyMetadata(from: folder.url, to: destination, cancellation: cancellation)
        }
    }

    /// Whether the job goes into `folder`.
    ///
    /// A folder that lies on another volume than the folder it is in is a mounted disk, disk image
    /// or share: deleting or moving "the folder" would empty that volume, so somebody has to say so
    /// first. False: it stays as it is, and that is noted.
    internal func mayEnter(_ folder: FileItem, for purpose: ProtectionQuestion.Purpose) throws -> Bool {
        guard FileIdentity.isMountPoint(folder.url) else {
            return true
        }
        let allowed: Bool = try decisions.withLock {
            if entersVolumes {
                return true
            }
            if isStopping { throw Cancelled() }
            switch try delegateOrStop().job(self, crossVolumeAt: folder, purpose: purpose) {
            case .proceed:
                return true

            case .all:
                entersVolumes = true
                return true

            case .skip:
                return false

            case .cancel:
                throw Cancelled()
            }
        }
        if !allowed {
            note(
                purpose == .move ? .move : .removeFolder,
                at: folder.url,
                FileJobError.otherVolume(display(folder.url)).localizedDescription
            )
        }
        return allowed
    }

    /// The mark of coming from elsewhere for a file or folder copied from the file system of `folder`
    /// to that of `destination`: `quarantine(of:)` of the folder it is found in, asked once per folder.
    ///
    /// Nil inside one file system, which does its own copying. Job thread only, where asking the file
    /// system is allowed to take long.
    internal func originMark(of folder: URL, copiedTo destination: URL) -> Data? {
        guard let from = try? fileSystems.provider(for: folder), let to = try? fileSystems.provider(for: destination),
            from !== to
        else { return nil }
        let key = folder.locationKey
        if let known = origins[key] {
            return known
        }
        let mark = from.quarantine(of: folder)
        if origins.count < rememberedLimit { origins[key] = .some(mark) }
        return mark
    }

    private func mayMerge(into existing: FileItem, _ folder: FileItem) throws -> Bool {
        guard options.asksBeforeMerging else {
            return true
        }
        return try decisions.withLock {
            if mergeAll {
                return true
            }
            switch try delegateOrStop().job(self, mergeInto: existing, source: folder) {
            case .merge:
                return true

            case .mergeAll:
                mergeAll = true
                return true

            case .skip:
                return false

            case .cancel:
                throw Cancelled()
            }
        }
    }

    /// Creates a target folder that the walk did not create (a filter was in the way, or the
    /// target of the whole job is new), once.
    internal func ensureFolder(_ folder: URL, in provider: any FileSystemProvider) throws {
        guard !options.filter.isEmpty else {
            return
        }
        let key = folder.locationKey
        if counters.withLock({ createdFolders.contains(key) }) {
            return
        }
        if try entry(at: folder) == nil {
            try provider.createDirectory(at: folder, cancellation: cancellation)
            record(.makeFolder, folder, nil, .done)
        }
        counters.withLock { _ = createdFolders.insert(key) }
    }

    /// Makes a target folder that was not there a moment ago and is about to be filled.
    ///
    /// It is made exclusively: anything that has appeared under the name since it was looked for (a
    /// link somebody put there, which would lead everything copied into the folder somewhere else)
    /// is "already exists", and the step is asked about like any other that failed.
    private func createFolder(_ folder: URL, in provider: any FileSystemProvider) throws {
        try provider.createDirectory(at: folder, exclusive: true, cancellation: cancellation)
    }

    /// A link as the thing it points to, for a copy that follows links.
    ///
    /// A link that leads nowhere, or back to a folder it lies in, stays a link.
    internal func resolvingLink(_ item: FileItem) -> FileItem {
        guard item.isSymlink else {
            return item
        }
        var target = item
        if item.url.isFileURL {
            let resolved = item.url.resolvingSymlinksInPath()
            guard let found = fileSystems.item(at: resolved), !item.url.isInside(resolved),
                !item.url.isSameLocation(as: resolved)
            else { return item }
            // "A folder it lies in" as the disk identifies folders (device and inode), not as
            // the paths read: the way to the link may itself lead through links, and then no
            // path of the link starts with the path of where it points.
            if found.isDirectory, FileIdentity.isInside(item.url, folder: resolved) {
                return item
            }
            target = found
        }
        return FileItem(
            url: item.url,
            name: item.name,
            kind: .init(
                isDirectory: item.isDirectory,
                isPackage: target.isPackage,
                isHidden: item.isHidden,
                isSpecial: target.isSpecial
            ),
            stat: .init(size: target.size, modified: target.modified, permissions: target.permissions)
        )
    }
}
