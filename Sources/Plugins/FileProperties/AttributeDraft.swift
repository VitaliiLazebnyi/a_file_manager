import AFMKernel
import Foundation

/// What the Change Attributes dialog holds while the user works on it: the texts as typed, so
/// that a mistake can be corrected without starting over.
internal struct AttributeDraft {
    /// An entry of the dialog that cannot be read.
    internal struct Problem: Error {
        /// What the user is told.
        internal let message: String
    }

    private static let flagOptions = ["Unchanged", "Set", "Clear"]

    /// Recurse into subdirectories.
    internal var recurse = false
    /// The permissions field as typed.
    internal var permissions = ""
    /// What the permissions field was filled with.
    ///
    /// A field left as it was asks for no change: otherwise a change of the date alone would also
    /// set every file below a folder to the folder's own mode, and unlock a locked file.
    private var prefilledPermissions: String?

    /// The permissions as they were pre-filled, while the field still shows them.
    internal var untouchedPermissions: String? {
        guard let prefilled = prefilledPermissions, !prefilled.isEmpty,
            permissions.trimmingCharacters(in: .whitespaces) == prefilled
        else { return nil }
        return prefilled
    }

    /// What the Hidden choice asks for.
    internal var hidden = FlagChange.keep
    /// What the Locked choice asks for.
    internal var locked = FlagChange.keep
    /// The owner field as typed; empty keeps the owner.
    internal var owner = ""
    /// The group field as typed; empty keeps the group.
    internal var group = ""
    /// Change date/time.
    internal var changesDate = false
    /// Use the current date and time.
    internal var usesCurrentTime = false
    /// The date field as typed.
    internal var date = "yyyy-mm-dd"
    /// The time field as typed.
    internal var time = "hh:mm:ss"

    /// One item shows its own permissions and date; several start with everything unchanged.
    internal init(items: [FileItem]) {
        guard items.count == 1 else {
            return
        }
        permissions = PropertyText.octal(items[0].permissions)
        prefilledPermissions = permissions
        (date, time) = TimestampChange.fieldTexts(for: items[0].modified, calendar: .current)
    }

    /// What the field shows is meant after all (the user said so).
    internal mutating func confirmPermissions() {
        prefilledPermissions = nil
    }

    /// Takes the permissions and the date of another file (Load from file under cursor); what
    /// is loaded is meant to be applied.
    internal mutating func load(from item: FileItem) {
        permissions = PropertyText.octal(item.permissions)
        prefilledPermissions = nil
        (date, time) = TimestampChange.fieldTexts(for: item.modified, calendar: .current)
        (changesDate, usesCurrentTime) = (true, false)
    }

    /// Pre-fills the dialog from command parameters.
    internal mutating func take(_ change: AttributeChange) {
        recurse = change.recurse
        // Whatever the parameters ask for is shown, changes like `u+x` as they were written.
        if change.permissions != .unchanged {
            permissions = change.permissions.text
            prefilledPermissions = nil
        }
        if change.hidden != .keep { hidden = change.hidden }
        if change.locked != .keep { locked = change.locked }
        if let timestamp = change.timestamp {
            func part(_ index: Int, _ letters: String, _ width: Int) -> String {
                timestamp.parts[index].map { String(format: "%0\(width)d", $0) } ?? letters
            }
            changesDate = true
            date = [part(0, "yyyy", 4), part(1, "mm", 2), part(2, "dd", 2)].joined(separator: "-")
            time = [part(3, "hh", 2), part(4, "mm", 2), part(5, "ss", 2)].joined(separator: ":")
        }
    }

    /// The fields of the dialog; the flags, owner and group only for local items, with what
    /// `details` says the single item has now.
    internal func fields(isLocal: Bool, details: LocalDetails?) -> [FormField] {
        func options(_ flag: KeyPath<LocalDetails, Bool>) -> [String] {
            guard let details else {
                return Self.flagOptions
            }
            return ["Unchanged (\(details[keyPath: flag] ? "set" : "not set"))", "Set", "Clear"]
        }
        func now(_ name: String?) -> String { name.map { " (now \($0))" } ?? "" }
        var fields: [FormField] = [
            .checkbox("recurse", "Recurse into subdirectories", recurse),
            .text("permissions", "Permissions:", permissions),
            .note(
                "Octal (755), letters (rwxr-xr-x) or changes (u+x,go-w). Empty leaves them unchanged. "
                    + "Octal sets the mode as chmod does: 755 also clears set-user-ID, set-group-ID and sticky; "
                    + "4755 sets them. Letters and changes keep those three."
            )
        ]
        if isLocal {
            fields += [
                .choice("hidden", "Hidden:", options(\.isHidden), selected: hidden.rawValue),
                .choice("locked", "Locked (read only):", options(\.isLocked), selected: locked.rawValue),
                .text("owner", "Owner\(now(details.map { LocalInfo.userName($0.ownerID) })):", owner),
                .text("group", "Group\(now(details.map { LocalInfo.groupName($0.groupID) })):", group)
            ]
        }
        fields += [
            .checkbox("changeDate", "Change date/time", changesDate),
            .text("date", "Date (yyyy-mm-dd):", date),
            .text("time", "Time (hh:mm:ss):", time),
            .checkbox("current", "Use the current date and time", usesCurrentTime),
            .note("A part written in letters keeps the file's own value: yyyy-05-dd changes only the month.")
        ]
        return fields
    }

    /// Takes what the dialog's fields hold now.
    internal mutating func read(_ answer: FormValues) {
        recurse = answer.flag("recurse")
        permissions = answer.text("permissions")
        hidden = FlagChange(choice: answer.index("hidden"))
        locked = FlagChange(choice: answer.index("locked"))
        (owner, group) = (answer.text("owner"), answer.text("group"))
        (changesDate, usesCurrentTime) = (answer.flag("changeDate"), answer.flag("current"))
        (date, time) = (answer.text("date"), answer.text("time"))
    }

    /// The change the dialog asks for, or what is wrong with an entry.
    internal func change(isLocal: Bool) -> Result<AttributeChange, Problem> {
        var change = AttributeChange()
        change.recurse = recurse
        let unchanged = permissions.trimmingCharacters(in: .whitespaces) == prefilledPermissions
        guard let typed = PermissionChange(unchanged ? "" : permissions) else {
            return .failure(Problem(message: "The permissions \"\(permissions)\" cannot be read!"))
        }
        change.permissions = typed
        if isLocal {
            change.hidden = hidden
            change.locked = locked
            let (ownerName, groupName) = (
                owner.trimmingCharacters(in: .whitespaces), group.trimmingCharacters(in: .whitespaces)
            )
            change.owner = ownerName.isEmpty ? nil : ownerName
            change.group = groupName.isEmpty ? nil : groupName
        }
        if usesCurrentTime {
            change.timestamp = .current
        } else if changesDate {
            guard let timestamp = TimestampChange(date: date, time: time) else {
                return .failure(Problem(message: "The date \"\(date)\" or the time \"\(time)\" cannot be read!"))
            }
            change.timestamp = timestamp
        }
        return .success(change)
    }
}
