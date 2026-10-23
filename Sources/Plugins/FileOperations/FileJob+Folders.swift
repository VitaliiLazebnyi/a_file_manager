import AFMKernel
import Foundation

/// Copy and move of a folder: its target made ready, its entries walked, its attributes and
/// marks put on last, and the questions about merging and other volumes.
extension FileJob {
    /// How the target of a folder was made ready.
    private enum FolderStart: Equatable {
        /// Not at all: the user did not want it merged into the folder that is there.
        case declined
        /// The folder was moved there as a whole; nothing is left to walk.
        case moved
        /// The target is ready for the entries; `createdHere` when the job made it.
        case ready(createdHere: Bool)

        /// Whether the job made the target folder.
        var createdHere: Bool { self == .ready(createdHere: true) }
    }

    /// Copies or moves a folder with everything in it to `destination`.
    ///
    /// `position` is where the copy filter stands inside the folder.
    internal func transferFolder(
        _ folder: FileItem,
        to destination: URL,
        inside position: CopyFilter.Position,
        at place: Place
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
        var start = FolderStart.declined
        let ready = try attempt(verb, at: source, target: destination) {
            start = try self.prepare(
                folder,
                at: destination,
                isTopLevel: place.isTopLevel,
                createsLater: createsLater,
                predicted: predicted
            )
            return start != .declined
        }
        guard ready else {
            add(predicted ? Measure(items: 1) : measuredBefore(folder))
            return .skipped
        }
        if start == .moved {
            return Outcome(finished: true, emptied: true, target: destination)
        }
        if predicted {
            // The rename did not happen; the folder is copied item by item, so it counts as that.
            let inside = measure(folder)
            counters.withLock { total += Measure(items: inside.items - 1, bytes: inside.bytes) }
        }

        add(Measure(items: 1))
        // A folder whose contents could not be read was not transferred; it must stay.
        guard let listed = try listing(of: source, sorted: true) else {
            return .skipped
        }
        let outcomes = try transferChildren(listed.items, of: source, to: destination, inside: position, at: place)
        // What was refused for its name stays where it is.
        let outcome = Outcome(
            finished: listed.rejected == 0 && outcomes.allSatisfy { $0?.finished == true },
            emptied: listed.rejected == 0 && outcomes.allSatisfy { $0?.emptied == true },
            target: destination
        )
        // A folder that waited for its first file (a filter was in the way) is the job's too, if one came.
        let madeLate = createsLater && !start.createdHere && (try? entry(at: destination)) != nil
        try finishFolder(folder, at: destination, createdHere: start.createdHere || madeLate)
        return try settle(outcome, of: source, tree: place.tree)
    }

    /// Makes the target of a folder ready: checks that it does not lie inside the folder itself,
    /// merges with a folder of the name that is there, moves the folder as a whole where a rename
    /// can, or creates the target (unless a filter makes that wait for the first file).
    private func prepare(
        _ folder: FileItem,
        at destination: URL,
        isTopLevel: Bool,
        createsLater: Bool,
        predicted: Bool
    ) throws -> FolderStart {
        let source = folder.url
        if destination.isSameLocation(as: source) { throw FileJobError.copyToItself }
        if destination.isInside(source) || (isTopLevel && FileIdentity.isInside(destination, folder: source)) {
            throw FileJobError.intoOwnSubfolder(display(source))
        }
        if let existing = try entry(at: destination) {
            return try meet(existing, with: folder, at: destination)
        }
        let (from, onto) = (try fileSystems.provider(for: source), try fileSystems.provider(for: destination))
        if isMove, from === onto, options.filter.isEmpty {
            // A folder that does not exist at the target moves as a whole, when renaming can do it.
            // The size of what moves is known from the first count; only a folder that no one
            // has counted is walked, and it is not walked when the rename comes first.
            do {
                try from.move(source, to: destination, replacing: false, cancellation: cancellation)
                add(predicted ? Measure(items: 1) : measuredBefore(folder))
                record(.move, source, destination, .done)
                return .moved
            } catch FileSystemError.crossesVolumes {
                // The two places lie on different volumes: the folder is copied item by item.
            }
        }
        if createsLater {
            return .ready(createdHere: false)
        }
        try createFolder(destination, in: onto)
        record(.makeFolder, destination, nil, .done)
        return .ready(createdHere: true)
    }

    /// What happens to a folder whose name is taken at the target by `existing`.
    ///
    /// The folder itself under another spelling (letter case) is renamed by a move and refused by
    /// a copy, which would merge it into itself. A folder there is merged with, if the user
    /// agrees; a file there is in the way.
    private func meet(_ existing: FileItem, with folder: FileItem, at destination: URL) throws -> FolderStart {
        let source = folder.url
        if FileIdentity.sameEntry(existing.url, source) {
            guard isMove else { throw FileJobError.copyToItself }
            try fileSystems.provider(for: source)
                .move(source, to: destination, replacing: true, cancellation: cancellation)
            // (A folder whose name is taken, by itself, was not taken for one rename.)
            add(measuredBefore(folder))
            record(.move, source, destination, .done)
            return .moved
        }
        // An existing folder is merged with the incoming one.
        guard existing.isRealDirectory else { throw FileJobError.targetIsFile(display(destination)) }
        return try mayMerge(into: existing, folder) ? .ready(createdHere: false) : .declined
    }

    /// Copies or moves the entries of the folder at `source` into `destination`; returns how each
    /// ended, in the order of `listed` (nil for one that was not reached).
    private func transferChildren(
        _ listed: [FileItem],
        of source: URL,
        to destination: URL,
        inside position: CopyFilter.Position,
        at place: Place
    ) throws -> [Outcome?] {
        // Between two file systems the files are read in the order the source reads them best.
        var children = listed
        if !source.isFileURL, let from = try? fileSystems.provider(for: source),
            let onto = try? fileSystems.provider(for: destination), from !== onto
        {
            children = inReadOrder(children, from: from)
        }
        let batch = Batch(count: children.count)
        batch.isSerial = children.count == listed.count && zip(children, listed).contains { $0.url != $1.url }
        // A second source folder that lands in this target folder meets what the first one
        // brought; that is this job's own work and no rule "for all" overwrites it.
        batch.isShared = !enteredTargets.insert(Self.claimHash(destination)).inserted
        // Nothing of this folder is still being written when this function is left, however it is left.
        defer { batch.group.wait() }
        let tree = place.tree ?? source
        for (slot, child) in children.enumerated() {
            try autoreleasepool {
                let childTarget = destination.appending(name: child.name)
                report { ["From: \(self.display(child.url))", "To: \(self.display(childTarget))"] }
                let inner = Place(batch: batch, slot: slot, position: position, tree: tree, depth: place.depth + 1)
                try transfer(child, to: childTarget, at: inner)
            }
        }
        let settled = batch.settled()
        if settled.cancelled { throw Cancelled() }
        return settled.outcomes
    }

    /// The end of a folder whose entries were dealt with: a move takes the folder away when
    /// nothing is left in it (or notes it for after the commit), and with a filter a folder that
    /// was entered counts as processed (07 › Only files of this type).
    private func settle(_ walked: Outcome, of source: URL, tree: URL?) throws -> Outcome {
        var outcome = walked
        if isMove, outcome.emptied, defersRemovals {
            postponeRemoval(of: source, isFolder: true, tree: tree)
        } else if isMove, outcome.emptied {
            // The provider removes only an empty folder, so whatever was not moved survives.
            outcome.emptied = try attempt(.removeFolder, at: source, target: nil) {
                try self.remove(source, below: tree)
                return true
            }
            outcome.finished = outcome.finished && outcome.emptied
        }
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
        let onto = try fileSystems.provider(for: destination)
        if attributes.modified != nil || attributes.permissions != nil {
            try? onto.setAttributes(attributes, of: destination, cancellation: cancellation)
        }
        guard createdHere else {
            return
        }
        // Last of all: tags, flags and the date of creation come along, and a lock that does
        // would forbid the changes above. A file system that cannot do it does without.
        // The origin mark goes on before them: a lock among the flags would refuse it.
        if let origin = originMark(of: folder.url, copiedTo: destination) {
            mark(destination, with: origin, in: onto, shownAs: folder.url)
        }
        if options.preservesAttributes {
            try? onto.copyMetadata(from: folder.url, to: destination, cancellation: cancellation)
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
        guard let from = try? fileSystems.provider(for: folder), let onto = try? fileSystems.provider(for: destination),
            from !== onto
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
