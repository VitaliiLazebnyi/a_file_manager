import AFMKernel
import Foundation

/// The overwrite rules: what happens to a file whose name is taken, and the questions about
/// protected items.
extension FileJob {
    /// Where an answer to a name that is taken leads: to a plan (nil: skip the file), or to
    /// planning again at another location.
    private enum Next {
        /// The file is planned again for this location: another name, or the old one made free.
        case again(URL)
        /// The plan for the file; nil skips it.
        case decided(Plan?)
    }

    /// The rule for the rest of the job that an answer "for all" sets; nil for an answer that
    /// holds for one file only.
    private static func rule(of answer: ConflictChoice) -> OverwriteMode? {
        switch answer {
        case .overwriteAll:
            return .overwriteAll

        case .skipAll:
            return .skipAll

        case .overwriteAllOlder:
            return .overwriteOlder

        case .overwriteAllOlderOrSame:
            return .overwriteOlderOrSame

        case .copyAllLarger:
            return .copyLarger

        case .copyAllSmaller:
            return .copySmaller

        case .renameOlderSkipNewer:
            return .renameOlderSkipNewer

        case .autoRenameCopied:
            return .autoRenameCopied

        case .autoRenameExisting:
            return .autoRenameExisting

        default:
            return nil
        }
    }

    /// Applies the overwrite rules (07 › Name collisions) to one file.
    ///
    /// Job thread only. `ownOutput`: what is found at the target may be a file this very job wrote,
    /// from another source that maps to the same name. `isTaken` names targets that are spoken for.
    /// Nil: the file is skipped.
    internal func plan(for item: FileItem, at destination: URL, ownOutput: Bool, isTaken: (URL) -> Bool) throws
        -> Plan?
    {
        if destination.isSameLocation(as: item.url) { throw FileJobError.copyToItself }
        guard let existing = try entry(at: destination) else {
            return .write(destination, replacing: false)
        }
        // A file system that only shows the files of another answers with the real file.
        // The real place is then what is compared and written: the other spelling of it
        // would hide that source and target are one file.
        if !existing.isDirectory, existing.url.scheme != destination.scheme {
            return try plan(for: item, at: existing.url, ownOutput: ownOutput, isTaken: isTaken)
        }
        // The source under another spelling (letter case on a case-insensitive volume): no
        // conflict. A move is a rename onto itself; a copy would be a copy onto itself.
        if FileIdentity.sameEntry(existing.url, item.url) {
            if isMove {
                return .rename(destination)
            }
            throw FileJobError.copyToItself
        }
        // Another name of the very same file (a hard link): there is nothing to copy.
        if FileIdentity.sameFile(existing.url, item.url) { throw FileJobError.copyToItself }
        if existing.isRealDirectory { throw FileJobError.targetIsFolder(display(destination)) }
        let choice = try conflictChoice(existing, item, ownOutput: ownOutput)
        switch try follow(choice, for: item, meeting: existing, at: destination, isTaken: isTaken) {
        case .again(let location):
            return try plan(for: item, at: location, ownOutput: ownOutput, isTaken: isTaken)

        case .decided(let plan):
            return plan
        }
    }

    /// What an answer for one file means for `item`, whose name at `destination` is taken by `existing`.
    private func follow(
        _ choice: ConflictChoice,
        for item: FileItem,
        meeting existing: FileItem,
        at destination: URL,
        isTaken: (URL) -> Bool
    ) throws -> Next {
        let folder = destination.deletingLastPathComponent()
        switch choice {
        case .skip, .skipAll, .cancel:
            return .decided(nil)

        case .rename(let name):
            return .again(folder.appending(name: name))

        case .autoRenameCopied:
            return .decided(.write(try freeName(for: destination, isTaken: isTaken), replacing: false))

        case .renameExisting(let name):
            try moveAside(destination, to: folder.appending(name: name))
            return .again(destination)

        case .autoRenameExisting:
            try moveAside(destination, to: try freeName(for: destination, isTaken: isTaken))
            return .again(destination)

        case .append, .resume:
            return .decided(try continuing(existing, with: item, at: destination, resuming: choice == .resume))

        default:
            return .decided(try mayTouch(existing, for: .overwrite) ? .write(destination, replacing: true) : nil)
        }
    }

    /// A free name next to `destination`, none of those `isTaken` names.
    private func freeName(for destination: URL, isTaken: (URL) -> Bool) throws -> URL {
        let free = UniqueName.available(for: destination, in: fileSystems, cancellation: cancellation, isTaken: isTaken)
        // A name found while the job was being stopped is not known to be free.
        try checkCancelled()
        return free
    }

    /// Renames the file at `destination` to `aside`, to make room for the one that is copied.
    private func moveAside(_ destination: URL, to aside: URL) throws {
        try fileSystems.provider(for: destination)
            .move(destination, to: aside, replacing: false, cancellation: cancellation)
        record(.rename, destination, aside, .done)
    }

    /// The plan to Append to `existing`, or to Resume it, which only a plain file allows.
    ///
    /// A resumed target must be shorter than the source; an appended one is asked about when it is protected.
    private func continuing(_ existing: FileItem, with item: FileItem, at destination: URL, resuming: Bool) throws
        -> Plan?
    {
        // A link has no length of its own and would pass for the start of anything.
        guard isPlainFile(existing) else { throw FileJobError.notPlainFile(display(destination)) }
        if resuming {
            guard existing.size < item.size else { throw FileJobError.cannotResume(display(destination)) }
            return .resume(destination)
        }
        return try mayTouch(existing, for: .overwrite) ? .append(destination) : nil
    }

    /// A file with contents of its own: not a link (a write would land on what it points to),
    /// not a pipe or device.
    ///
    /// Asks the disk again for a local file, whatever the listing said.
    internal func isPlainFile(_ item: FileItem) -> Bool {
        if item.isSymlink || item.isSpecial || item.isDirectory {
            return false
        }
        return !FileIdentity.isSymlink(item.url) && !FileIdentity.isSpecialNode(item.url, followingLinks: false)
    }

    /// The answer for this one file: from the rule that holds for the job, or from the user.
    ///
    /// What comes back is one of the single-file answers.
    private func conflictChoice(_ existing: FileItem, _ source: FileItem, ownOutput: Bool) throws -> ConflictChoice {
        try decisions.withLock {
            if mode == .ask {
                let answer = try delegateOrStop().job(self, conflictAt: existing, source: source)
                if answer == .cancel { throw Cancelled() }
                guard let rule = Self.rule(of: answer) else {
                    return answer
                }
                mode = rule
            }
            return ownOutput ? choiceForOwnOutput(existing, source) : choiceByRule(existing, source)
        }
    }

    /// The answer for a file whose name is taken by one this job wrote a moment ago.
    ///
    /// That file came from another source of the same name. No rule "for all" was given with
    /// that in mind: only an answer for this one file overwrites it. Under a rule both files are
    /// kept.
    ///
    /// Called with `decisions` held.
    private func choiceForOwnOutput(_ existing: FileItem, _ source: FileItem) -> ConflictChoice {
        switch mode {
        case .skipAll:
            return .skip

        case .autoRenameExisting:
            return .autoRenameExisting

        case .renameOlderSkipNewer:
            return isNewer(source, than: existing) ? .autoRenameExisting : .skip

        default:
            return .autoRenameCopied
        }
    }

    /// The answer the rule of the job gives for one file.
    ///
    /// Called with `decisions` held.
    private func choiceByRule(_ existing: FileItem, _ source: FileItem) -> ConflictChoice {
        switch mode {
        case .ask, .overwriteAll:
            return .overwrite

        case .skipAll:
            return .skip

        case .overwriteOlder:
            return isNewer(source, than: existing) ? .overwrite : .skip

        case .overwriteOlderOrSame:
            return !isNewer(existing, than: source) ? .overwrite : .skip

        case .copyLarger:
            return source.size > existing.size ? .overwrite : .skip

        case .copySmaller:
            return source.size < existing.size ? .overwrite : .skip

        case .autoRenameCopied:
            return .autoRenameCopied

        case .autoRenameExisting:
            return .autoRenameExisting

        case .renameOlderSkipNewer:
            return isNewer(source, than: existing) ? .autoRenameExisting : .skip
        }
    }

    /// FAT, exFAT, ZIP archives and many servers keep the time of change to two seconds (HFS+
    /// to one), so a file copied there comes back up to that much older: where one of the two
    /// files lies on such a volume, nearer than that counts as the same age.
    ///
    /// Between volumes that keep the time exactly (APFS) the times are compared as they are. Called
    /// with `decisions` held.
    private func isNewer(_ file: FileItem, than other: FileItem) -> Bool {
        file.modified.timeIntervalSince(other.modified)
            > max(Self.timestampNoise, grain(at: file.url), grain(at: other.url))
    }

    private func grain(at url: URL) -> TimeInterval {
        let key = url.deletingLastPathComponent().locationKey
        if let known = grains[key] {
            return known
        }
        let grain = FileIdentity.timestampGrain(of: url)
        if grains.count >= 256 { grains.removeAll() }
        grains[key] = grain
        return grain
    }

    /// The second question for an item nobody may write to, or a hidden one.
    ///
    /// False: leave it.
    internal func mayTouch(_ item: FileItem, for purpose: ProtectionQuestion.Purpose) throws -> Bool {
        if options.ignoresProtection || item.isSymlink {
            return true
        }
        if options.asksAboutReadOnly, item.permissions & 0o222 == 0, try !confirm(.readOnly, purpose, item) {
            return false
        }
        if options.asksAboutHidden, item.isHidden, try !confirm(.hidden, purpose, item) {
            return false
        }
        return true
    }

    /// Asks the second question about a protected item, unless "all" was answered for the same
    /// question before; false: leave it.
    internal func confirm(
        _ reason: ProtectionQuestion.Reason,
        _ purpose: ProtectionQuestion.Purpose,
        _ item: FileItem
    ) throws -> Bool {
        try decisions.withLock {
            let key = "\(reason)-\(purpose)"
            if confirmedForAll.contains(key) {
                return true
            }
            let question = ProtectionQuestion(reason: reason, purpose: purpose, item: item)
            switch try delegateOrStop().job(self, confirm: question) {
            case .proceed:
                return true

            case .all:
                confirmedForAll.append(key)
                return true

            case .skip:
                return false

            case .cancel:
                throw Cancelled()
            }
        }
    }
}
