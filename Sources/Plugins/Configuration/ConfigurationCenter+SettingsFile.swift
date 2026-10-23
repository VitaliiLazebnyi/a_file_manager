import AFMKernel
import Foundation

/// The settings as a whole: their schema, export, import and reset.
extension ConfigurationCenter {
    /// What is known about the settings now, for import and export.
    internal func settingsSchema() -> SettingsSchema {
        var schema = SettingsSchema()
        for preference in kernel.preferences.pages.flatMap(\.preferences) {
            schema.preferences[preference.key] = preference.kind
        }
        schema.known = Set(settingsKeys())
        // Copied here, on the main thread where the registry lives: the schema is used on any thread.
        let declared = kernel.settingsKeys.all
        let exact = declared.reduce(into: [String: SettingsKeyKind]()) { kinds, declaration in
            if !declaration.isPrefix { kinds[declaration.key] = declaration.kind }
        }
        let families = declared.filter(\.isPrefix)
        schema.declaredKind = { key in
            // As the registry answers: the key itself, else the longest family it belongs to.
            exact[key]
                ?? families.filter { key.utf8.starts(with: $0.key.utf8) }.max { $0.key.utf8.count < $1.key.utf8.count }?
                .kind
        }
        return schema
    }

    /// Asks what an export is to hold besides the settings themselves.
    ///
    /// Nil when the user gave up.
    internal func askExportOptions() -> SettingsExportOptions? {
        let fields: [FormField] = [
            .note(
                "The file holds the options of all pages, the key bindings, the button bar, the user commands, "
                    + "the Start menu, the directory hotlist and the panels' tabs. "
                    + "Passwords are never in it, and only you can read the file."
            ),
            .checkbox("history", "Also include " + SettingsExportOptions.historyNote),
            .checkbox("connections", "Also include " + SettingsExportOptions.connectionsNote)
        ]
        guard let answer = kernel.interaction.form("Export Settings", detail: "", fields: fields, buttons: ["Export…"])
        else {
            return nil
        }
        return SettingsExportOptions(
            includesHistory: answer.flag("history"),
            includesConnections: answer.flag("connections")
        )
    }

    /// Writes the settings to a file only the user can read.
    ///
    /// What the user did rather than set up (histories), and the servers the user connects to, are
    /// in it only when `options` says so. With `tellsWhatIsIncluded` the user is told afterwards what
    /// the file holds.
    internal func exportSettings(to url: URL, options: SettingsExportOptions, tellsWhatIsIncluded: Bool) {
        let keys = options.included(settingsKeys(), schema: settingsSchema())
        let archive = SettingsArchive.capture(from: kernel.settings, keys: keys)
        // Weak: the file is written off the main thread, and the plugin may be gone when that is done.
        runner.offMain(
            { Result { try archive.write(to: url) } },
            then: { [weak self] result in
                self?
                    .exported(
                        result,
                        detail: tellsWhatIsIncluded ? options.description(count: archive.values.count) : nil
                    )
            }
        )
    }

    /// Tells how an export went: a failure, or with `detail` what was exported.
    private func exported(_ result: Result<Void, any Error>, detail: String?) {
        switch result {
        case .failure(let error):
            kernel.interaction.report(error, title: "The settings could not be exported")

        case .success:
            if let detail {
                kernel.interaction.inform("The settings were exported", detail: detail, style: .information)
            }
        }
    }

    /// Reads a settings file, checks it, shows what it would change and stores it when the
    /// user agrees.
    ///
    /// What can run programs, rebind keys or change whom the program trusts is stored only when the
    /// user ticks it. Nothing is ever imported without this question, whoever asked for the import.
    internal func importSettings(from url: URL) {
        let schema = settingsSchema()
        let knownKeys = settingsKeys()
        // Weak: the file is read and checked off the main thread, and the plugin may be gone when
        // that is done.
        runner.offMain(
            { Result { try CheckedSettings(SettingsArchive(data: CheckedSettings.read(url)), schema: schema) } },
            then: { [weak self] result in self?.checked(result, of: url, knownKeys: knownKeys, schema: schema) }
        )
    }

    /// Goes on with an import once its file is read: a failure is told, a checked file is
    /// compared with what is stored, off the main thread again, and then offered.
    private func checked(
        _ result: Result<CheckedSettings, any Error>,
        of url: URL,
        knownKeys: [String],
        schema: SettingsSchema
    ) {
        switch result {
        case .failure(let error):
            kernel.interaction.report(error, title: "The settings could not be imported")

        case .success(let checked):
            var current: [String: Data] = [:]
            for key in Set(knownKeys).union(checked.values.keys) {
                current[key] = kernel.settings.data(forKey: key)
            }
            runner.offMain(
                { [current] in
                    SettingsImportPlan(checked, current: current, knownKeys: knownKeys, schema: schema)
                },
                then: { [weak self] plan in self?.confirmAndApply(plan, fileName: url.lastPathComponent) }
            )
        }
    }

    /// Shows what an import would change, part by part, and stores the parts the user ticks.
    private func confirmAndApply(_ plan: SettingsImportPlan, fileName: String) {
        guard !plan.isEmpty else {
            kernel.interaction.inform(
                "Nothing to import",
                detail: plan.summary(fileName: fileName),
                style: .information
            )
            return
        }
        var fields: [FormField] = [.note(plan.summary(fileName: fileName))]
        for part in plan.parts {
            fields.append(.checkbox(part.group.rawValue, part.title, false))
            fields.append(.lines(part.group.rawValue + ".contents", "", part.lines.joined(separator: "\n")))
        }
        guard let answer = kernel.interaction.form("Import Settings", detail: "", fields: fields, buttons: ["Import"])
        else {
            return
        }
        let accepted = Set(plan.parts.map(\.group).filter { answer.flag($0.rawValue) })
        plan.apply(to: kernel.settings, accepting: accepted)
        applyStoredSettings()
        let skipped = plan.parts.filter { !accepted.contains($0.group) }.count
        kernel.interaction.inform(
            "The settings were imported",
            detail: (skipped > 0 ? "\(skipped) parts were not ticked and stay as they were. " : "")
                + "Some settings take effect when the program is started again.",
            style: .information
        )
    }

    /// Removes every known setting after asking; returns whether it did.
    @discardableResult
    internal func resetSettings() -> Bool {
        let answer = kernel.interaction.choose(
            "Reset all settings?",
            detail: "Options, key bindings, the button bar, user commands and the Start menu "
                + "go back to how the program came. Export the settings first to keep them.",
            buttons: ["Reset", "Cancel"],
            style: .critical
        )
        guard answer == 0 else {
            return false
        }
        SettingsArchive().restore(into: kernel.settings, replacing: settingsKeys())
        applyStoredSettings()
        return true
    }
}
