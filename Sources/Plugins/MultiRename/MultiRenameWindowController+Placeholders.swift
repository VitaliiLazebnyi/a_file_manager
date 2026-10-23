import AFMKernel
import AppKit

/// The buttons and menus that insert placeholders into the masks (spec 09 › Mask fields, insert
/// buttons and menus).
extension MultiRenameWindowController {
    /// The menu "More fields": each placeholder with what it stands for.
    private static let moreFields: [(String, String)] = [
        ("[P]", "Parent folder"), ("[G]", "Grandparent folder"), ("[A]", "Name with extension"), ("[E]", "Extension"),
        ("[d]", "Date (regional format)"), ("[t]", "Time (regional format)"), ("[S]", "Size"),
        ("[T4]", "From here on: date taken (pictures) instead of date changed"),
        ("[U]", "All characters after this position in uppercase"),
        ("[L]", "All characters after this position in lowercase"),
        ("[F]", "First letter of each word uppercase after this position"),
        ("[f]", "First letter of each word uppercase after this position (English in Titles)"),
        ("[n]", "All characters after this position again as in original name"), ("[%USER%]", "User name"),
        ("[[]", "Square bracket: open"), ("[]]", "Square bracket: close"), ("[X]", "Clipboard text"),
        ("[c]", "Number of files in the list"),
        ("[I]", "Folders only (on/off): The name [N] includes the extension, [E] is not used")
    ]

    /// The menu "Ranges of other fields": the letter of each field with what it is.
    private static let rangeFields: [(String, String)] = [
        ("", "Full path+name"), ("P", "Parent folder"), ("G", "Grandparent folder"), ("A", "Name with extension"),
        ("E", "Extension"), ("X", "Clipboard text")
    ]

    /// Puts a placeholder at the cursor of a mask field, in place of what is selected there.
    internal func insert(_ text: String, into field: NSTextField) {
        if let editor = field.currentEditor() {
            editor.replaceCharacters(in: editor.selectedRange, with: text)
        } else {
            field.stringValue += text
        }
        fieldsChanged()
    }

    /// "[N] Name".
    @objc
    internal func insertName() { insert("[N]", into: nameMaskBox) }

    /// "[C] Counter" of the name.
    @objc
    internal func insertNameCounter() { insert("[C]", into: nameMaskBox) }

    /// "[YMD] Date".
    @objc
    internal func insertDate() { insert("[YMD]", into: nameMaskBox) }

    /// "[hms] Time".
    @objc
    internal func insertTime() { insert("[hms]", into: nameMaskBox) }

    /// "[E] Ext.".
    @objc
    internal func insertExtension() { insert("[E]", into: extensionField) }

    /// "[C] Counter" of the extension.
    @objc
    internal func insertExtensionCounter() { insert("[C]", into: extensionField) }

    /// "[N#-#] Range".
    @objc
    internal func insertNameRange() { insertRange(of: "N", into: nameMaskBox) }

    /// "[E#-#] Range".
    @objc
    internal func insertExtensionRange() { insertRange(of: "E", into: extensionField) }

    /// "+": the menu of more fields, under the button.
    @objc
    internal func showMoreFields(_ sender: NSButton) {
        let menu = NSMenu()
        for (code, label) in Self.moreFields {
            let item = NSMenuItem(title: "\(code)  \(label)", action: #selector(insertFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            menu.addItem(item)
        }
        popUpMenu(menu, sender)
    }

    /// "#": the menu of the ranges of other fields, under the button.
    @objc
    internal func showRangeFields(_ sender: NSButton) {
        let menu = NSMenu()
        for (letter, label) in Self.rangeFields {
            let item = NSMenuItem(
                title: "[\(letter)#-#]  \(label)",
                action: #selector(insertRangeFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = letter
            menu.addItem(item)
        }
        popUpMenu(menu, sender)
    }

    @objc
    private func insertFromMenu(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String {
            insert(code, into: nameMaskBox)
        }
    }

    @objc
    private func insertRangeFromMenu(_ sender: NSMenuItem) {
        if let letter = sender.representedObject as? String {
            insertRange(of: letter, into: nameMaskBox)
        }
    }

    /// The range picker "Select the characters to insert" (spec 09 › Mask fields, insert
    /// buttons and menus), as a form: positions are typed instead of marked with the mouse.
    private func insertRange(of letter: String, into field: NSTextField) {
        let sample =
            (session.rowCount > 0 ? session.row(at: 0) : nil)
            .map { row -> String in
                let parts = row.entry.item.isFolder ? (row.entry.name, "") : FileItem.split(row.entry.name)
                return letter == "N" ? parts.0 : letter == "E" ? parts.1 : row.entry.name
            } ?? ""
        let fields: [FormField] = [
            .text("first", "First character:", "1"), .text("last", "Last character (empty = to the end):", ""),
            .checkbox("firstFromEnd", "Measure first character from the end"),
            .checkbox("lastFromEnd", "Measure last character from the end"),
            .checkbox("length", "Use [first,length] instead of [first-last]")
        ]
        guard
            let answer = kernel.interaction.form(
                "Select the characters to insert:",
                detail: sample,
                fields: fields,
                buttons: ["OK"]
            ),
            let first = Int(answer.text("first").trimmingCharacters(in: .whitespaces)), first > 0
        else {
            return
        }
        var range = (answer.flag("firstFromEnd") ? "-" : "") + String(first)
        if let last = Int(answer.text("last").trimmingCharacters(in: .whitespaces)), last > 0 {
            range += answer.flag("length") ? ",\(last)" : "-" + (answer.flag("lastFromEnd") ? "-" : "") + String(last)
        } else {
            range += "-"
        }
        insert("[\(letter)\(range)]", into: field)
    }
}
