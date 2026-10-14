import Foundation

// ./cf2 <left scalars: count x hex, comma separated> <right ...>   e.g. 128x15,1xFFFD 1xFFFD

/// Stops with a usage line when the command line cannot be read.
///
/// - Parameter why: What was wrong with the arguments.
/// - Returns: Never returns.
internal func usage(_ why: String) -> Never {
    FileHandle.standardError.write(Data("cf2: \(why)\nusage: cf2 <count>x<hex>[,...] <count>x<hex>[,...]\n".utf8))
    exit(2)
}

/// Builds a string from a list of runs such as `128x15,1xFFFD` (128 times U+0015, then one U+FFFD).
///
/// - Parameter spec: The comma separated runs, each `count x hex scalar`.
/// - Returns: The string the runs describe.
internal func make(_ spec: String) -> String {
    var text = ""
    for part in spec.split(separator: ",") {
        let fields = part.split(separator: "x")
        guard fields.count == 2,
            let count = Int(fields[0]),
            let value = UInt32(fields[1], radix: 16),
            let scalar = Unicode.Scalar(value)
        else {
            usage("cannot read the run \"\(part)\"")
        }

        text += String(repeating: String(scalar), count: count)
    }
    return text
}

guard CommandLine.arguments.count > 2 else {
    usage("two arguments are needed")
}

/// The left name.
internal let kLeft = make(CommandLine.arguments[1])
/// The right name.
internal let kRight = make(CommandLine.arguments[2])

print(kLeft.localizedCaseInsensitiveCompare(kRight).rawValue)
print("no crash")
