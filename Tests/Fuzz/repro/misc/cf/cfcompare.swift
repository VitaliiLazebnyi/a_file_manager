// Standalone: Foundation's localized comparison aborts (free of a stack buffer inside
// _CFCompareStringsWithLocale) for some pairs of names. No project code involved.
// swiftc -O cfcompare.swift -o cfcompare && ./cfcompare [controls] [digits]
import Foundation

let n = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 61
let k = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 67
let m = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 66
let a =
    String(repeating: "\u{15}", count: n) + String(repeating: "\u{6}", count: k) + "\u{FFFD}a"
    + String(repeating: "0", count: m)
for other in ["\u{FFFD}", "a.txt", "sub", "b c.txt", "é.txt", "e\u{301}.txt", "\\", "x\\y", "", a] {
    print("comparing a name of \(a.utf8.count) bytes with \(other.debugDescription)")
    print(a.localizedCaseInsensitiveCompare(other).rawValue, other.localizedCaseInsensitiveCompare(a).rawValue)
}
print("no crash")
