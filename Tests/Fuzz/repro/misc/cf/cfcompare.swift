// Standalone: Foundation's localized comparison aborts (free of a stack buffer inside
// _CFCompareStringsWithLocale) for some pairs of names. No project code involved.
// swiftc -O cfcompare.swift -o cfcompare && ./cfcompare [controls] [digits]
import Foundation

/// Reads a count from the command line.
///
/// - Parameters:
///   - index: The position of the argument.
///   - fallback: The count when the argument is not given.
/// - Returns: The count.
internal func argument(_ index: Int, _ fallback: Int) -> Int {
    guard CommandLine.arguments.count > index else {
        return fallback
    }
    guard let value = Int(CommandLine.arguments[index]) else {
        FileHandle.standardError.write(Data("cfcompare: argument \(index) is not a number\n".utf8))
        exit(2)
    }
    return value
}

/// How many U+0015 control characters start the long name.
internal let kControls = argument(1, 61)
/// How many U+0006 control characters follow them.
internal let kAcks = argument(2, 67)
/// How many digits end the long name.
internal let kDigits = argument(3, 66)
/// The long name that makes the comparison abort.
internal let kLong =
    String(repeating: "\u{15}", count: kControls) + String(repeating: "\u{6}", count: kAcks) + "\u{FFFD}a"
    + String(repeating: "0", count: kDigits)

for other in ["\u{FFFD}", "a.txt", "sub", "b c.txt", "é.txt", "e\u{301}.txt", "\\", "x\\y", "", kLong] {
    print("comparing a name of \(kLong.utf8.count) bytes with \(other.debugDescription)")
    print(kLong.localizedCaseInsensitiveCompare(other).rawValue, other.localizedCaseInsensitiveCompare(kLong).rawValue)
}
print("no crash")
