import AFMKernel
import AppKit

/// Running a search: the walk, the duplicate finder and Spotlight, each handing its results to the
/// main thread.
extension FindFilesWindowController {
    /// Runs `search` on this thread and hands its hits to `deliver` in batches, by count and by time, so
    /// a large search does not flood the window and a folder with a million hits does not arrive in one
    /// piece; `deliver` also hears of the folder being searched, now and then.
    nonisolated private static func run(_ search: FileSearch, inBatches deliver: ([FileItem], URL?) -> Void) {
        // These variables belong to the search thread.
        var pending: [FileItem] = []
        var lastFlush = Date()
        func flush(_ directory: URL?) {
            let batch = pending
            pending = []
            lastFlush = Date()
            deliver(batch, directory)
        }
        search.run(
            onDirectory: { directory in
                if Date().timeIntervalSince(lastFlush) > 0.1 {
                    flush(directory)
                }
            },
            onMatch: { item in
                pending.append(item)
                if pending.count >= batchSize
                    || (pending.count.isMultiple(of: 128) && Date().timeIntervalSince(lastFlush) > 0.1)
                {
                    flush(nil)
                }
            }
        )
        flush(nil)
    }

    /// Stops the running search if it looks through `volume` (which is about to be ejected).
    internal func cancelSearch(ifItReads volume: URL) {
        guard isSearching else {
            return
        }
        let places = form.settings.searchIn.split(separator: ";")
            .map { part in
                kernel.fileSystems.location(
                    from: String(part).trimmingCharacters(in: .whitespaces),
                    relativeTo: startDirectory
                )
            }
        // A search whose places are not known is stopped too: better a search again than a drive refused.
        if places.isEmpty
            || places.contains(where: { $0.isFileURL && ($0.isSameLocation(as: volume) || $0.isInside(volume)) })
        {
            cancelSearch()
        }
    }

    /// Stops the running search; it ends through the usual path with what it has.
    internal func cancelSearch() {
        search?.cancel()
        if let spotlight {
            spotlight.stop()
            self.spotlight = nil
            finish(built: Built.make(items: []), notes: [])
        }
    }

    /// Walks the folders for `search`, listing the hits as they come.
    internal func walk(_ search: FileSearch) {
        let deliver: @Sendable ([FileItem], URL?) -> Void = { [weak self] batch, directory in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.search === search else {
                    return
                }
                append(batch)
                if let directory {
                    statusLabel.stringValue = kernel.fileSystems.displayPath(directory)
                }
            }
        }
        // On a thread of the kernel's own, like everything here that waits for a file
        // system: a search on a share that has stopped answering keeps its thread, and the
        // system's shared pool has none to spare for that.
        BlockingCalls.run { [weak self] in
            Self.run(search, inBatches: deliver)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.search === search else {
                    return
                }
                finish(built: nil, notes: notes(of: search))
            }
        }
    }

    /// Duplicates are only known when everything has been found and compared, so nothing is
    /// listed before the end; the status line tells how far the work is.
    internal func walkForDuplicates(_ search: FileSearch) {
        let fileSystems = kernel.fileSystems
        let show: @MainActor @Sendable (String) -> Void = { [weak self] text in
            guard let self, self.search === search else {
                return
            }
            statusLabel.stringValue = text
        }
        BlockingCalls.run { [weak self] in
            // Used by one thread at a time: the walk reports its folders first, and the comparing
            // that follows reports under the lock of `DuplicateFinder`.
            nonisolated(unsafe) var lastReport = Date.distantPast
            // Whether a tenth of a second has passed since the status line last changed: if so, it changes now.
            @Sendable
            func isDue() -> Bool {
                guard Date().timeIntervalSince(lastReport) > 0.1 else {
                    return false
                }
                lastReport = Date()
                return true
            }
            let groups = search.runForDuplicates(
                onDirectory: { directory in
                    // The path is only made when it is shown: a walk meets very many folders.
                    if isDue() {
                        let text = fileSystems.displayPath(directory)
                        DispatchQueue.main.async { show(text) }
                    }
                },
                onHashing: { done, total in
                    // A file was read whole for this: the text costs nothing beside that. The
                    // first file says at once that the comparing has begun.
                    let text = "Comparing contents: \(done) of \(total)"
                    if done == 1 || isDue() {
                        DispatchQueue.main.async { show(text) }
                    }
                }
            )
            let built = Built.make(groups: groups)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.search === search else {
                    return
                }
                finish(built: built, notes: notes(of: search))
            }
        }
    }

    /// Asks Spotlight for `search`; its answer is checked in the background against the whole search.
    internal func askSpotlight(_ spotlight: any SpotlightQuestion, for search: FileSearch) {
        self.spotlight = spotlight
        statusLabel.stringValue = "[Asking Spotlight...]"
        let (fileSystems, limit) = (kernel.fileSystems, spotlight.limit)
        spotlight.start { [weak self] paths, truncated in
            guard let self, self.search === search else {
                return
            }
            self.spotlight = nil
            statusLabel.stringValue = "[Checking \(paths.count) files...]"
            BlockingCalls.run { [weak self] in
                let items = SpotlightQuery.verify(paths, with: search, fileSystems: fileSystems)
                let groups =
                    search.query.duplicates.isActive
                    ? DuplicateFinder.groups(
                        of: items,
                        options: search.query.duplicates,
                        fileSystems: fileSystems,
                        cancellation: search.cancellation
                    )
                    : nil
                let built = groups.map(Built.make(groups:)) ?? Built.make(items: items)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.search === search else {
                        return
                    }
                    var notes = notes(of: search)
                    if truncated {
                        notes.append(
                            "Spotlight gave more than \(limit) files, the rest were left out"
                        )
                    }
                    finish(built: built, notes: notes)
                }
            }
        }
    }

    /// What the summary has to add about a search that did not go as asked.
    private func notes(of search: FileSearch) -> [String] {
        var notes: [String] = []
        if search.reachedResultLimit {
            notes.append("stopped at \(limits.results) results")
        }
        if search.regexTimedOut {
            notes.append("a regular expression was too slow for some names")
        }
        return notes
    }

    private func append(_ batch: [FileItem]) {
        guard !batch.isEmpty else {
            return
        }
        let first = rows.count
        rows.reserveCapacity(first + batch.count)
        for item in batch {
            rows.append(.item(item))
            resultURLs.append(item.url)
            if item.isDirectory {
                foundDirectories += 1
            } else {
                foundFiles += 1
            }
        }
        resultsTable.insertRows(at: IndexSet(integersIn: first..<rows.count))
    }
}
