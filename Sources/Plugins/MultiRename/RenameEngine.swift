/// The whole rename pipeline for one set of settings (spec 09 › Rename pipeline): masks, then
/// Search & Replace, then the case conversion.
///
/// Built once, on any thread; `newName` may then be called from several threads at once.
internal struct RenameEngine {
    /// The text the preview shows where a name could not be made.
    internal static let errorText = "<Error!>"

    /// The settings the engine was built for.
    internal let settings: RenameSettings
    /// What the masks get besides the item, with the counter of the settings.
    internal let context: RenameContext
    /// What is wrong with the settings as a whole, if anything: then no item gets a name.
    internal let problem: (any Error)?
    private let nameMask: RenameMask
    private let extensionMask: RenameMask
    private let searchReplace: SearchReplace?
    private let formats: RenameFormats
    /// Ends a regular expression that is still working on a name (the preview was overtaken, the run cancelled).
    private let cancelled: @Sendable () -> Bool

    /// Set once names were computed: a regular expression that took too long for some of them.
    internal var tooSlow: (any Error)? {
        searchReplace?.timedOut == true ? SearchReplace.Problem.tooSlow(settings.search) : nil
    }

    /// The pipeline of `settings`, whose work is never cancelled.
    internal init(_ settings: RenameSettings, context: RenameContext) {
        self.init(settings, context: context) { false }
    }

    /// The pipeline of `settings`; `cancelled` ends a regular expression that is still working on a name.
    internal init(
        _ settings: RenameSettings,
        context: RenameContext,
        cancelled: @escaping @Sendable () -> Bool
    ) {
        self.settings = settings
        self.cancelled = cancelled
        var withCounter = context
        withCounter.counter = settings.counter
        self.context = withCounter
        nameMask = RenameMask(settings.nameMask)
        extensionMask = RenameMask(settings.extensionMask)
        formats = RenameFormats(locale: context.locale, timeZone: context.timeZone)
        do {
            searchReplace = try SearchReplace(settings)
            problem = nameMask.error ?? extensionMask.error
        } catch {
            searchReplace = nil
            problem = error
        }
    }

    /// Control characters become spaces and slashes at the end are dropped.
    internal static func tidied(_ name: String) -> String {
        var tidy = String(
            name.map { character in
                character.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } ? " " : character
            }
        )
        while tidy.hasSuffix("/") {
            tidy.removeLast()
        }
        return tidy
    }

    /// Why a name cannot be given to a file; nil when it can.
    ///
    /// A slash inside the name is fine: it moves the item into that folder.
    internal static func invalidity(of name: String) -> String? {
        if name.isEmpty {
            return "The name is empty."
        }
        // Cut at the `/` byte, not at the character: a combining mark after a slash makes one
        // character with it, and the file system reads the slash all the same.
        let components = name.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
            .dropFirst(name.utf8.first == 0x2F ? 1 : 0)
        for component in components {
            if component.isEmpty {
                return "A folder name is empty."
            }
            if component.elementsEqual(".".utf8) {
                return ". is not a name."
            }
            if component.elementsEqual("..".utf8) {
                return ".. is not a name."
            }
            if component.count > 255 {
                return "The name is too long."
            }
        }
        return nil
    }

    /// The new name the masks give the item at `index` of the list; nil is `<Error!>`.
    internal func newName(for subject: RenameSubject, index: Int) -> String? {
        newName(for: subject, index: index, given: nil)
    }

    /// The new name of the item at `index` of the list.
    ///
    /// With `given`, that name (loaded from a file or typed by the user) takes the place of the
    /// masks' result. Nil is `<Error!>`.
    internal func newName(for subject: RenameSubject, index: Int, given: String?) -> String? {
        guard let searchReplace else {
            return nil
        }
        var name: String
        var ext: String
        if let given {
            // Everything from the last dot on is the extension of a given name.
            if let dot = given.lastIndex(of: "."), dot != given.startIndex, given.index(after: dot) != given.endIndex {
                (name, ext) = (String(given[..<dot]), String(given[given.index(after: dot)...]))
            } else {
                (name, ext) = (given, "")
            }
        } else {
            var state = MaskState()
            do {
                name = try nameMask.evaluate(subject, index: index, context: context, formats: formats, state: &state)
                ext = try extensionMask.evaluate(
                    subject,
                    index: index,
                    context: context,
                    formats: formats,
                    state: &state
                )
            } catch {
                return nil
            }
        }
        func joined(_ name: String, _ ext: String) -> String { ext.isEmpty ? name : name + "." + ext }
        var full: String
        if settings.searchesExtension {
            guard let replaced = searchReplace.replacing(in: joined(name, ext), cancelled: cancelled) else {
                return nil
            }
            full = replaced
        } else {
            guard let replaced = searchReplace.replacing(in: name, cancelled: cancelled) else {
                return nil
            }
            full = joined(replaced, ext)
        }
        full = settings.letterCase.apply(to: full, rule: context.titleRule)
        return Self.tidied(full)
    }
}
