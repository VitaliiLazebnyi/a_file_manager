import AFMKernel
import AppKit

/// Find, and the repeating of a search (spec 10 › Find dialog, Result and repeating).
extension ViewerPane {
    /// Which way a repeated search goes.
    internal enum SearchDirection {
        /// Backwards (Shift+F3).
        case backwards
        /// The other way than the last search went (Ctrl+F3).
        case reversed
        /// The way the last search was asked to go (F3).
        case same
    }

    /// The Find dialog (spec 10 › Find dialog).
    internal func find() {
        guard showsText else {
            return
        }
        let options = lastSearch?.options ?? settings.searchOptions
        let history = settings.searchHistory
        var fields: [FormField] = [.text("text", "Enter search text:", lastSearch?.text ?? history.first ?? "")]
        if history.count > 1 {
            fields.append(.choice("history", "Earlier searches:", ["(as typed above)"] + history, selected: 0))
        }
        fields += [
            .checkbox("words", "Whole words only", options.wholeWords),
            .checkbox("case", "Case sensitive", options.caseSensitive),
            .checkbox("backwards", "Search backwards", options.backwards),
            .checkbox("hex", "Search hex string", options.hex),
            .checkbox("regex", "RegEx", options.regex)
        ]
        guard let answer = kernel.interaction.form("Find", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        let picked = answer.index("history")
        let text = picked > 0 && picked <= history.count ? history[picked - 1] : answer.text("text")
        let chosen = SearchOptions(
            wholeWords: answer.flag("words"),
            caseSensitive: answer.flag("case"),
            backwards: answer.flag("backwards"),
            hex: answer.flag("hex"),
            regex: answer.flag("regex")
        )
        guard !text.isEmpty else {
            return
        }
        lastSearch = (text, chosen)
        settings.searchOptions = chosen
        settings.searchHistory = [text] + history.filter { $0 != text }
        search(backwards: chosen.backwards)
    }

    /// F3 / Shift+F3 / Ctrl+F3 (spec 10 › Result and repeating).
    internal func findAgain(_ direction: SearchDirection) {
        guard let lastSearch else {
            find()
            return
        }
        switch direction {
        case .same:
            search(backwards: lastSearch.options.backwards)

        case .backwards:
            search(backwards: true)

        case .reversed:
            search(backwards: !lastSearchWentBackwards)
        }
    }

    /// Searches the whole file from the current place on, off the main thread, with progress
    /// in the status line; Esc or Cancel stops it.
    internal func search(backwards: Bool) {
        guard let lastSearch, let document = pager.document, let loaded, activity == nil else {
            return
        }
        let pattern: SearchPattern
        do {
            pattern = try SearchPattern(lastSearch.text, options: lastSearch.options, encoding: document.encoding)
        } catch {
            kernel.interaction.report(error, title: "Find")
            return
        }
        lastSearchWentBackwards = backwards
        let cancel = CancellationFlag()
        let generation = loadGeneration
        let start = pager.searchStart(backwards: backwards)
        activity = Activity(text: "Searching for \"\(lastSearch.text)\"…", progress: 0, cancel: cancel)
        let parallelism = loaded.parallel ? ProcessInfo.processInfo.activeProcessorCount : 1
        workQueue.async { [weak self] in
            // The tables of a double-byte code page take a moment to build: not on the main thread.
            let boundaries = document.characterBoundaries
            var lastReport = Date.distantPast
            let result = Result {
                try ViewerSearch.find(
                    ViewerSearch.Request(pattern: pattern, start: start, backwards: backwards),
                    in: ViewerSearch.Subject(
                        source: document.source,
                        content: document.content,
                        encoding: document.encoding,
                        boundaries: boundaries
                    ),
                    tuning: ViewerSearch.Tuning(chunkSize: 1 << 20, parallelism: parallelism, rawBytes: true),
                    cancellation: cancel
                ) { fraction in
                    guard Date().timeIntervalSince(lastReport) > 0.1 else {
                        return
                    }
                    lastReport = Date()
                    DispatchQueue.main.async {
                        guard let self, self.activity?.cancel === cancel else {
                            return
                        }
                        self.activity?.progress = fraction
                    }
                }
            }
            DispatchQueue.main.async {
                self?.searchFinished(result, for: lastSearch.text, in: document, generation: generation, cancel: cancel)
            }
        }
    }

    /// Shows what a search found; nothing when the file or the search changed meanwhile.
    internal func searchFinished(
        _ result: Result<Range<Int64>?, any Error>,
        for text: String,
        in document: TextDocument,
        generation: Int,
        cancel: CancellationFlag
    ) {
        if activity?.cancel === cancel { activity = nil }
        guard loadGeneration == generation, pager.document?.source === document.source, !cancel.isCancelled else {
            return
        }
        switch result {
        case .success(let match?):
            pager.reveal(
                offset: match.lowerBound,
                select: match,
                rowsAbove: settings.searchGoBack,
                keepingSelection: false
            )

        case .success(nil):
            kernel.interaction.inform("\"\(text)\" was not found.")

        case .failure(let error):
            kernel.interaction.report(error, title: "Find")
        }
    }
}
