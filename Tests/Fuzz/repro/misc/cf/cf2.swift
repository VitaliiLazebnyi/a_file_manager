import Foundation

// ./cf2 <left scalars: count x hex, comma separated> <right ...>   e.g. 128x15,1xFFFD 1xFFFD
func make(_ spec: String) -> String {
    var s = ""
    for part in spec.split(separator: ",") {
        let p = part.split(separator: "x")
        s += String(repeating: String(Unicode.Scalar(UInt32(p[1], radix: 16)!)!), count: Int(p[0])!)
    }
    return s
}
let a = make(CommandLine.arguments[1])
let b = make(CommandLine.arguments[2])
print(a.localizedCaseInsensitiveCompare(b).rawValue)
print("no crash")
