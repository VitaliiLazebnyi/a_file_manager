import Foundation

/// What happens to the permissions of an item (spec 07 › Change attributes, adapted: the Mac
/// has permissions where Windows has `r a h s`).
internal enum PermissionChange: Equatable {
    /// A whole new mode.
    ///
    /// With `keepingSpecialBits` (the mode was written in letters, which cannot name them),
    /// set-user-ID, set-group-ID and sticky stay as they are. An octal mode is the whole mode,
    /// as it is for `chmod`: `755` clears the three, `4755` sets set-user-ID.
    case absolute(UInt16, keepingSpecialBits: Bool)
    /// Changes to the mode the item has, applied one clause after the other.
    case symbolic([Clause])
    /// The permissions stay as they are.
    case unchanged

    /// A part of the text that names no class of users.
    private struct Unreadable: Error {}

    /// One `who op permissions` part of a symbolic change, as `chmod` writes it: `go-w`.
    internal struct Clause: Equatable {
        /// The classes it applies to, as shifts of their three bits: 6 owner, 3 group, 0 others.
        internal var shifts: [UInt16]
        /// `+` adds the bits, `-` takes them away, `=` sets them and clears the rest of the class.
        internal var operation: Character
        /// `r` 4, `w` 2, `x` 1.
        internal var bits: UInt16
        /// `X`: execute only for folders and for files that are executable for someone already.
        internal var conditionalExecute: Bool

        /// Adds the permission letter `r`, `w`, `x` or `X`; false for any other character.
        internal mutating func add(_ permission: Character) -> Bool {
            switch permission {
            case "r":
                bits |= 4

            case "w":
                bits |= 2

            case "x":
                bits |= 1

            case "X":
                conditionalExecute = true

            default:
                return false
            }
            return true
        }
    }

    /// Whether the new mode depends on the mode the item has.
    internal var needsCurrentMode: Bool {
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
    internal var text: String {
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

    /// Reads `755`, `0755`, `rwxr-xr-x` or `chmod` clauses such as `u+x,go-w` and `a+rX`.
    ///
    /// An empty text changes nothing; nil when the text is none of these.
    internal init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            self = .unchanged
        } else if (3...4).contains(trimmed.count), trimmed.allSatisfy({ ("0"..."7").contains($0) }),
            let mode = UInt16(trimmed, radix: 8)
        {
            self = .absolute(mode, keepingSpecialBits: false)
        } else if let mode = Self.mode(fromLetters: trimmed) {
            self = .absolute(mode, keepingSpecialBits: true)
        } else {
            let clauses = trimmed.split(separator: ",", omittingEmptySubsequences: false)
                .map { Self.clause(String($0)) }
            guard !clauses.contains(nil) else {
                return nil
            }
            self = .symbolic(clauses.compactMap(\.self))
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

    /// One clause such as `go-w`; nil when it is not one.
    ///
    /// No classes before the operator means all three.
    private static func clause(_ text: String) -> Clause? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let operatorIndex = trimmed.firstIndex(where: { "+-=".contains($0) }),
            let shifts = try? shifts(of: trimmed[..<operatorIndex])
        else { return nil }
        var clause = Clause(
            shifts: shifts.isEmpty ? [6, 3, 0] : shifts,
            operation: trimmed[operatorIndex],
            bits: 0,
            conditionalExecute: false
        )
        for permission in trimmed[trimmed.index(after: operatorIndex)...] {
            guard clause.add(permission) else {
                return nil
            }
        }
        return clause
    }

    /// The shifts of the classes `u`, `g`, `o` and `a` (all three).
    ///
    /// Throws for any other letter.
    private static func shifts(of classes: Substring) throws(Unreadable) -> [UInt16] {
        var shifts: [UInt16] = []
        for who in classes {
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
                throw Unreadable()
            }
        }
        return shifts
    }

    /// The mode `mode` becomes; `isDirectory` decides what a conditional execute (`X`) does.
    internal func applied(to mode: UInt16, isDirectory: Bool) -> UInt16 {
        switch self {
        case .unchanged:
            return mode

        case .absolute(let new, let keepingSpecialBits):
            return keepingSpecialBits ? (mode & 0o7000) | (new & 0o777) : new & 0o7777

        case .symbolic(let clauses):
            var result = mode
            for clause in clauses {
                var bits = clause.bits
                if clause.conditionalExecute, isDirectory || result & 0o111 != 0 { bits |= 1 }
                for shift in clause.shifts {
                    switch clause.operation {
                    case "+":
                        result |= bits << shift

                    case "-":
                        result &= ~(bits << shift)

                    default:
                        result = (result & ~(7 << shift)) | (bits << shift)
                    }
                }
            }
            return result
        }
    }
}
