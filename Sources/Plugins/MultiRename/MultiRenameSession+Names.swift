import AFMContracts
import AFMKernel
import Foundation

/// Names from a list (spec 09 › Name-list menu), the saved settings and the histories of the fields.
extension MultiRenameSession {
    /// Takes the new names from a text, one per line, in list order.
    internal func loadNames(fromText text: String) {
        guard !isBusy else {
            return
        }
        applyGivenNames(RenameNameList.names(in: text))
    }

    /// Reads a list of names from a file on any file system, off the main thread; the text is
    /// split into lines there too. `completion`, if any, follows on the main thread.
    internal func loadNames(from url: URL, completion: (@MainActor @Sendable () -> Void)?) {
        guard !isBusy else {
            return
        }
        let fileSystems = kernel.fileSystems
        @Sendable
        func read() -> Result<[String], any Error> {
            Result {
                let reader = try fileSystems.provider(for: url).read(url)
                defer { reader.close() }
                var data = Data()
                // A list of names is small; what is beyond 32 MB is not one.
                while data.count < 32 << 20, let block = try reader.read(upToCount: 1 << 20) {
                    data.append(block)
                }
                return RenameNameList.names(in: RenameNameList.text(from: data))
            }
        }
        // Weak: read in the background, the names may come when the session has gone.
        let finish: @MainActor @Sendable (Result<[String], any Error>) -> Void = { [weak self] result in
            self?.namesRead(result)
            completion?()
        }
        guard previewsInBackground else {
            finish(read())
            return
        }
        // (The file may lie on a server: on a thread of the kernel's own.)
        BlockingCalls.run {
            let result = autoreleasepool { read() }
            performOnMainLoop { finish(result) }
        }
    }

    /// "Edit names": the new names as text, one per line, for the user to change.
    internal func editNames() {
        guard !isBusy else {
            return
        }
        // Weak: a long text is put together in the background, and the session may go meanwhile.
        let ask: @MainActor @Sendable (String) -> Void = { [weak self] in self?.askNames($0) }
        // The text of a long list is put together in the background.
        guard previewsInBackground, entries.count >= Self.backgroundSortThreshold else {
            ask(targetNames.joined(separator: "\n"))
            return
        }
        let (current, names, generation) = (entries, newNames, listGeneration)
        DispatchQueue.global(qos: .userInitiated)
            .async { [weak self] in
                let text = current.indices.map { names[$0] ?? current[$0].name }.joined(separator: "\n")
                performOnMainLoop { [weak self] in
                    guard let self, listGeneration == generation else {
                        return
                    }
                    ask(text)
                }
            }
    }

    /// Back to names made by the masks.
    internal func clearGivenNames() {
        guard !isBusy else {
            return
        }
        givenNames = []
        listChanged(keepingFolders: true)
    }

    /// Saves what the fields hold under `name` (trimmed, at most 252 characters); an empty name saves nothing.
    internal func save(as name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(252))
        guard !trimmed.isEmpty else {
            return
        }
        store.saved[trimmed] = settings
        onChange?()
    }

    /// Puts the settings saved as `name` into the fields; false when there are none of that name.
    @discardableResult
    internal func load(_ name: String) -> Bool {
        guard let saved = store.saved[name] else {
            return false
        }
        settings = saved
        return true
    }

    /// Deletes the settings saved as `name`.
    internal func deleteSaved(_ name: String) {
        store.saved[name] = nil
        onChange?()
    }

    /// Puts what is in the fields at the top of their histories; done when a run starts.
    internal func rememberFields() {
        store.remember(settings.nameMask, in: .nameMask)
        store.remember(settings.search, in: .search)
        store.remember(settings.replacement, in: .replacement)
    }

    private func applyGivenNames(_ names: [String]) {
        givenNames = names
        listChanged(keepingFolders: true)
    }

    /// Takes the names read from a file, or tells why there are none.
    private func namesRead(_ result: Result<[String], any Error>) {
        switch result {
        case .success(let names):
            applyGivenNames(names)

        case .failure(let error):
            kernel.interaction.report(error, title: "The names cannot be loaded!")
        }
    }

    /// Asks for the new names as text, one per line, starting from `text`.
    private func askNames(_ text: String) {
        let fields = [FormField.lines("names", "", text)]
        guard
            let answer = kernel.interaction.form(
                "Edit names",
                detail: "One name per line, in the order of the list.",
                fields: fields,
                buttons: ["OK"]
            )
        else {
            return
        }
        loadNames(fromText: answer.text("names"))
    }
}
