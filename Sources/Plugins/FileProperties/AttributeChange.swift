import AFMKernel
import Foundation

/// What happens to the permissions of an item (spec 07 › Change attributes, adapted: the Mac
/// has permissions where Windows has `r a h s`).
enum PermissionChange: Equatable {
    /// One `who op permissions` part of a symbolic change, as `chmod` writes it: `go-w`.
    struct Clause: Equatable {
        /// The classes it applies to, as shifts of their three bits: 6 owner, 3 group, 0 others.
        var shifts: [UInt16]
        var operation: Character
        /// `r` 4, `w` 2, `x` 1.
        var bits: UInt16
        /// `X`: execute only for folders and for files that are executable for someone already.
        var conditionalExecute: Bool
    }

    case unchanged
    /// With `keepingSpecialBits` (the mode was written in letters, which cannot name them),
    /// set-user-ID, set-group-ID and sticky stay as they are. An octal mode is the whole mode,
    /// as it is for `chmod`: `755` clears the three, `4755` sets set-user-ID.
    case absolute(UInt16, keepingSpecialBits: Bool)
    case symbolic([Clause])

    /// Reads `755`, `0755`, `rwxr-xr-x` or `chmod` clauses such as `u+x,go-w` and `a+rX`.
    ///
    /// An empty text changes nothing; nil when the text is none of these.
    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            self = .unchanged
        } else if (3...4).contains(text.count), text.allSatisfy({ ("0"..."7").contains($0) }),
            let mode = UInt16(text, radix: 8)
        {
            self = .absolute(mode, keepingSpecialBits: false)
        } else if let mode = Self.mode(fromLetters: text) {
            self = .absolute(mode, keepingSpecialBits: true)
        } else {
            let clauses = text.split(separator: ",", omittingEmptySubsequences: false)
                .map {
                    Self.clause(String($0))
                }
            guard !clauses.contains(nil) else {
                return nil
            }
            self = .symbolic(clauses.compactMap { $0 })
        }
    }

    /// `rwxr-xr-x` → 0o755.
    private static func mode(fromLetters text: String) -> UInt16? {
        guard text.count == 9 else {
            return nil
        }
        var mode: UInt16 = 0
        for (index, character) in text.enumerated() {
            let expected: Character = ["r", "w", "x"][index % 3]
            if character == expected {
                mode |= 0o400 >> UInt16(index)
            } else if character != "-" {
                return nil
            }
        }
        return mode
    }

    private static func clause(_ text: String) -> Clause? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let operatorIndex = text.firstIndex(where: { "+-=".contains($0) }) else {
            return nil
        }
        var shifts: [UInt16] = []
        for who in text[..<operatorIndex] {
            switch who {
            case "u":
                shifts.append(6)

            case "g":
                shifts.append(3)

            case "o":
                shifts.append(0)

            case "a":
                shifts += [6, 3, 0]

            default:
                return nil
            }
        }
        var clause = Clause(
            shifts: shifts.isEmpty ? [6, 3, 0] : shifts,
            operation: text[operatorIndex],
            bits: 0,
            conditionalExecute: false
        )
        for permission in text[text.index(after: operatorIndex)...] {
            switch permission {
            case "r":
                clause.bits |= 4

            case "w":
                clause.bits |= 2

            case "x":
                clause.bits |= 1

            case "X":
                clause.conditionalExecute = true

            default:
                return nil
            }
        }
        return clause
    }

    /// Whether the new mode depends on the mode the item has.
    var needsCurrentMode: Bool {
        switch self {
        case .unchanged:
            return false

        case .absolute(_, let keepingSpecialBits):
            return keepingSpecialBits

        case .symbolic:
            return true
        }
    }

    /// The change as it can be typed, and read back by `init(_:)`.
    var text: String {
        switch self {
        case .unchanged:
            return ""

        case .absolute(let mode, let keepingSpecialBits):
            if !keepingSpecialBits {
                return PropertyText.octal(mode)
            }
            return (0..<9).map { index in mode & (0o400 >> UInt16(index)) != 0 ? ["r", "w", "x"][index % 3] : "-" }
                .joined()

        case .symbolic(let clauses):
            return
                clauses.map { clause in
                    let who =
                        clause.shifts == [6, 3, 0]
                        ? "a" : clause.shifts.map { $0 == 6 ? "u" : ($0 == 3 ? "g" : "o") }.joined()
                    let what =
                        (clause.bits & 4 != 0 ? "r" : "") + (clause.bits & 2 != 0 ? "w" : "")
                        + (clause.bits & 1 != 0 ? "x" : "")
                    return who + String(clause.operation) + what + (clause.conditionalExecute ? "X" : "")
                }
                .joined(separator: ",")
        }
    }

    func applied(to mode: UInt16, isDirectory: Bool) -> UInt16 {
        switch self {
        case .unchanged:
            return mode

        case .absolute(let new, let keepingSpecialBits):
            return keepingSpecialBits ? (mode & 0o7000) | (new & 0o777) : new & 0o7777

        case .symbolic(let clauses):
            var mode = mode
            for clause in clauses {
                var bits = clause.bits
                if clause.conditionalExecute, isDirectory || mode & 0o111 != 0 { bits |= 1 }
                for shift in clause.shifts {
                    switch clause.operation {
                    case "+":
                        mode |= bits << shift

                    case "-":
                        mode &= ~(bits << shift)

                    default:
                        mode = (mode & ~(7 << shift)) | (bits << shift)
                    }
                }
            }
            return mode
        }
    }
}

/// A new date and time of last change (spec 07 › Change attributes › Date and time).
///
/// The date is written `yyyy-MM-dd` and the time `HH:mm:ss`, with any separators. A part written in
/// letters (`yyyy-05-dd`, `hh:10:ss`), and an empty field, keeps what the file has.
struct TimestampChange: Equatable {
    /// Year, month, day, hour, minute, second; nil keeps that part of the file's own date.
    var parts: [Int?]
    /// The moment the command ran, for every item alike.
    var usesCurrentTime = false

    static let current = Self(parts: Array(repeating: nil, count: 6), usesCurrentTime: true)

    init(parts: [Int?], usesCurrentTime: Bool = false) {
        self.parts = parts
        self.usesCurrentTime = usesCurrentTime
    }

    /// Nil when a field is neither empty nor a date or time in the form above.
    init?(date: String, time: String) {
        guard let day = Self.fields(date, count: 3...3, limits: [1...9_999, 1...12, 1...31]),
            var clock = Self.fields(time, count: 2...4, limits: [0...23, 0...59, 0...59, 0...999])
        else { return nil }
        // Seconds that are left out become 0; fractions of a second are not kept.
        if clock.count == 2 { clock.append(0) }
        parts = day + clock.prefix(3)
    }

    private static func fields(_ text: String, count: ClosedRange<Int>, limits: [ClosedRange<Int>]) -> [Int?]? {
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if tokens.isEmpty {
            return Array(repeating: nil, count: 3)
        }
        guard count.contains(tokens.count) else {
            return nil
        }
        var fields: [Int?] = []
        for (token, limit) in zip(tokens, limits) {
            if token.allSatisfy(\.isLetter) {
                fields.append(nil)
            } else if let number = Int(token), limit.contains(number) {
                fields.append(number)
            } else {
                return nil
            }
        }
        return fields
    }

    var changesNothing: Bool { !usesCurrentTime && parts.allSatisfy { $0 == nil } }

    /// The new date of an item last changed at `original`; nil when the parts do not make a
    /// date (the 31st of a month with 30 days).
    func applied(to original: Date, now: Date, calendar: Calendar = .current) -> Date? {
        if usesCurrentTime {
            return now
        }
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: original
        )
        if let year = parts[0] { components.year = year }
        if let month = parts[1] { components.month = month }
        if let day = parts[2] { components.day = day }
        if let hour = parts[3] { components.hour = hour }
        if let minute = parts[4] { components.minute = minute }
        if let second = parts[5] {
            components.second = second
            components.nanosecond = 0
        }
        components.calendar = calendar
        guard components.isValidDate else {
            return nil
        }
        return calendar.date(from: components)
    }

    /// A date as the fields of the dialog show it.
    static func fieldTexts(for date: Date, calendar: Calendar = .current) -> (date: String, time: String) {
        func part(_ component: Calendar.Component) -> Int { calendar.component(component, from: date) }
        return (
            String(format: "%04d-%02d-%02d", part(.year), part(.month), part(.day)),
            String(format: "%02d:%02d:%02d", part(.hour), part(.minute), part(.second))
        )
    }
}

/// Everything the Change Attributes dialog can ask for.
///
/// Nil members stay as they are.
struct AttributeChange: Equatable {
    var permissions = PermissionChange.unchanged
    /// The hidden flag (`UF_HIDDEN`); local files only.
    var hidden: Bool?
    /// Finder's Locked (`UF_IMMUTABLE`), the Mac's read-only attribute; local files only.
    var locked: Bool?
    var timestamp: TimestampChange?
    /// User and group by name or number; local files only.
    var owner: String?
    var group: String?
    /// Also change everything inside the folders among the operands.
    var recurse = false

    var isEmpty: Bool {
        permissions == .unchanged && hidden == nil && locked == nil && (timestamp?.changesNothing ?? true)
            && owner == nil && group == nil
    }

    var needsLocalFileSystem: Bool { hidden != nil || locked != nil || owner != nil || group != nil }

    /// Reads the parameter text of the command, modelled on `OPENATTRIBUTES` (spec 07 ›
    /// `OPENATTRIBUTES`): `+h`/`-h` hidden, `+r`/`-r` locked (read only), `+f`/`-f` recurse,
    /// `+d<date>`, `+t<time>`, `+c` current date and time, and for the Mac `+m<permissions>`.
    ///
    /// A leading `=` means "apply without showing the dialog". Windows' `a` and `s` have no
    /// counterpart and are ignored. Nil when a token cannot be read.
    static func parse(parameters: String) -> (change: Self, applyAtOnce: Bool)? {
        var change = Self()
        var applyAtOnce = false
        var (date, time, changesDate) = ("", "", false)
        for (index, token) in parameters.split(separator: " ").enumerated() {
            if index == 0, token.hasPrefix("=") {
                applyAtOnce = true
                if token.count == 1 { continue }
            }
            let token = token.hasPrefix("=") ? token.dropFirst() : token
            guard let sign = token.first, sign == "+" || sign == "-", let letter = token.dropFirst().first else {
                return nil
            }
            let value = String(token.dropFirst(2))
            switch letter {
            case "h" where value.isEmpty:
                change.hidden = sign == "+"

            case "r" where value.isEmpty:
                change.locked = sign == "+"

            case "f" where value.isEmpty:
                change.recurse = sign == "+"

            case "a" where value.isEmpty, "s" where value.isEmpty:
                break

            case "c" where value.isEmpty:
                // Fills both fields; a later `+t` without a value empties the time again, so
                // that `+c +t` changes the date only.
                (date, time) = TimestampChange.fieldTexts(for: Date())
                changesDate = true

            case "d":
                (date, changesDate) = (value, true)

            case "t":
                (time, changesDate) = (value, true)

            case "m":
                guard let permissions = PermissionChange(value) else {
                    return nil
                }
                change.permissions = permissions

            default:
                return nil
            }
        }
        if changesDate {
            guard let typed = TimestampChange(date: date, time: time) else {
                return nil
            }
            change.timestamp = typed
        }
        return (change, applyAtOnce)
    }
}

/// Applies an `AttributeChange` to items and, with `recurse`, to everything inside them.
///
/// **Threading.** `run` blocks and is meant for a job's thread. The files of a folder and its
/// subfolders are changed on all cores at once, by the kernel's pool (`Parallel.map`): calls
/// from inside calls share its threads, and a piece that waits for a disk or a server does
/// not take a thread away from the system's queues. The outcome is the only state the
/// threads share and is guarded by a lock. Date and permissions go through the item's file-system
/// provider, so they work wherever the provider supports them; flags and owners are POSIX
/// calls and exist for `file:` URLs only.
///
/// `outcome`, `ownerID` and `groupID` are guarded by `lock`; everything else is fixed in `init`.
final class AttributeJob: @unchecked Sendable {
    struct Outcome {
        var changed = 0
        var failed = 0
        /// The first failures, ready to show: path and reason.
        var failures: [String] = []
        var cancelled = false
    }

    private let change: AttributeChange
    private let fileSystems: FileSystemRegistry
    private let cancellation: CancellationFlag
    private let meter: ProgressMeter?
    private let now = Date()
    private let lock = NSLock()
    private var outcome = Outcome()
    /// Looked up once, on the job's thread, before the parallel work starts (under `lock`).
    private var ownerID: uid_t?
    private var groupID: gid_t?

    init(
        change: AttributeChange,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag = CancellationFlag(),
        meter: ProgressMeter? = nil
    ) {
        self.change = change
        self.fileSystems = fileSystems
        self.cancellation = cancellation
        self.meter = meter
    }

    func run(_ items: [FileItem]) -> Outcome {
        if let owner = change.owner {
            guard let id = LocalInfo.userID(owner) else {
                return Outcome(failed: items.count, failures: ["There is no user called \(owner)."])
            }
            lock.withLock { ownerID = id }
        }
        if let group = change.group {
            guard let id = LocalInfo.groupID(group) else {
                return Outcome(failed: items.count, failures: ["There is no group called \(group)."])
            }
            lock.withLock { groupID = id }
        }
        each(items) { self.process($0) }
        lock.lock()
        defer { lock.unlock() }
        outcome.cancelled = cancellation.isCancelled
        return outcome
    }

    private func each(_ items: [FileItem], serialBelow threshold: Int = 2, _ body: @Sendable (FileItem) -> Void) {
        guard items.count >= threshold, items.count > 1 else {
            items.forEach(body)
            return
        }
        _ = Parallel.map(items, serialBelow: threshold) { body($0) }
    }

    private func process(_ item: FileItem) {
        guard !cancellation.isCancelled else {
            return
        }
        guard change.recurse, item.isRealDirectory else {
            apply(to: item)
            return
        }
        // The contents come first and the folder last, so that taking a folder's own
        // permissions away does not lock the job out of it. A folder that cannot be read
        // yet is changed first: the change may be what opens it.
        // Listed with the job's flag, so that a server that has stopped answering does not
        // hold the job (and a thread of the pool) after Cancel.
        let list = {
            try? self.fileSystems.provider(for: item.url)
                .list(
                    item.url,
                    showHidden: true,
                    cancellation: self.cancellation
                )
        }
        var children = list()
        // A listing that ended because of the cancel says nothing about the folder.
        guard !cancellation.isCancelled else {
            return
        }
        let changedFirst = children == nil
        if changedFirst {
            apply(to: item)
            children = list()
        }
        guard !cancellation.isCancelled else {
            return
        }
        let contents = children ?? []
        each(contents.filter { !$0.isRealDirectory }, serialBelow: 64) { self.apply(to: $0) }
        each(contents.filter(\.isRealDirectory)) { self.process($0) }
        if !changedFirst { apply(to: item) }
    }

    private func apply(to item: FileItem) {
        guard !cancellation.isCancelled else {
            return
        }
        do {
            try change(item)
            lock.lock()
            outcome.changed += 1
            lock.unlock()
        } catch {
            // What ended because the job was stopped did not fail.
            guard !cancellation.isCancelled else {
                return
            }
            lock.lock()
            outcome.failed += 1
            if outcome.failures.count < 20 {
                outcome.failures.append("\(fileSystems.displayPath(item.url)): \(error.localizedDescription)")
            }
            lock.unlock()
        }
        meter?.add(1, at: fileSystems.displayPath(item.url))
    }

    private func change(_ listed: FileItem) throws {
        let url = listed.url
        let provider = try fileSystems.provider(for: url)
        if change.needsLocalFileSystem, !url.isFileURL {
            throw FileSystemError.notSupported("Changing flags and owners")
        }
        // A locked item takes no other change, so the lock comes off first and goes on last.
        if change.locked == false { try LocalInfo.setFlag(UInt32(UF_IMMUTABLE), false, of: url) }
        // A change that starts from what the item has (`u+x`, a date with parts left as they
        // are) starts from what it has now, not from what a listing said a while ago.
        let timestamp = change.timestamp.flatMap { $0.changesNothing ? nil : $0 }
        let needsCurrent = change.permissions.needsCurrentMode || (timestamp.map { !$0.usesCurrentTime } ?? false)
        let item = needsCurrent ? (provider.item(at: url, cancellation: cancellation) ?? listed) : listed
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        // Permissions and dates of a link would land on the item it points to. The disk is
        // asked once more: what was a file when the folder was listed may be a link by now.
        if !item.isSymlink, !LocalInfo.isSymlink(url) {
            var attributes = FileAttributes()
            if change.permissions != .unchanged {
                attributes.permissions = change.permissions.applied(
                    to: item.permissions,
                    isDirectory: item.isDirectory
                )
            }
            if let timestamp {
                guard let date = timestamp.applied(to: item.modified, now: now) else { throw InvalidDate() }
                attributes.modified = date
            }
            // The file system unlocks an item that is made writable. With the lock left
            // "unchanged" that would be a change nobody asked for: a locked item is reported.
            if attributes.permissions != nil, change.locked == nil, LocalInfo.details(url)?.isLocked == true {
                throw LockedItem()
            }
            if attributes.permissions != nil || attributes.modified != nil {
                try provider.setAttributes(attributes, of: url, cancellation: cancellation)
            }
        }
        let (ownerID, groupID) = lock.withLock { (self.ownerID, self.groupID) }
        if ownerID != nil || groupID != nil { try LocalInfo.setOwner(ownerID, group: groupID, of: url) }
        if let hidden = change.hidden { try LocalInfo.setFlag(UInt32(UF_HIDDEN), hidden, of: url) }
        if change.locked == true { try LocalInfo.setFlag(UInt32(UF_IMMUTABLE), true, of: url) }
    }

    private struct LockedItem: LocalizedError {
        var errorDescription: String? {
            "The item is locked. Its permissions were not changed; choose Locked: Clear to unlock it."
        }
    }

    private struct InvalidDate: LocalizedError {
        var errorDescription: String? { "The new date does not exist in the calendar." }
    }
}
