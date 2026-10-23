import AFMKernel
import Foundation

/// When two lines count as equal (spec 09 › Comparison rules).
///
/// The options only decide equality; inside a line that differs, the characters are compared
/// exactly.
public struct DiffOptions: Equatable, Codable, Sendable {
    /// Lines that differ only in upper and lower case are equal ("Case sensitive" off).
    public var ignoreCase = true
    /// Runs of spaces and tabs count as one space, and those at the start and end of a line
    /// as none.
    public var ignoreRepeatedSpaces = true
    /// `\n`, `\r\n` and `\r` are the same line break.
    public var ignoreLineEndings = true

    /// Options that ignore what is set here; by default case, repeated spaces and line breaks.
    public init(ignoreCase: Bool = true, ignoreRepeatedSpaces: Bool = true, ignoreLineEndings: Bool = true) {
        self.ignoreCase = ignoreCase
        self.ignoreRepeatedSpaces = ignoreRepeatedSpaces
        self.ignoreLineEndings = ignoreLineEndings
    }

    /// What a line is compared by: two lines are equal exactly when their keys are.
    public func key(_ line: TextLine) -> String {
        var text = line.text
        if ignoreRepeatedSpaces {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf8.count)
            var gap = false
            for byte in text.utf8 {
                if byte == 0x20 || byte == 0x09 {
                    gap = true
                } else {
                    if gap, !bytes.isEmpty {
                        bytes.append(0x20)
                    }
                    gap = false
                    bytes.append(byte)
                }
            }
            // Only spaces and tabs were taken out of valid UTF-8: nothing needs repairing.
            text = String(repairingUTF8: bytes)
        }
        if ignoreCase {
            text = text.lowercased()
        }
        return ignoreLineEndings ? text : text + line.ending.rawValue
    }

    /// A 64-bit hash of a line's key, made without building the key as a string.
    ///
    /// Equal keys have equal hashes; equal hashes are checked again with `isSameKey` where it
    /// matters.
    internal func hash(_ line: TextLine) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var text = line.text
        let hashed: Bool = text.withUTF8 { bytes in
            // Only ASCII is hashed as it is. Other text takes the slow path through `key`: it folds
            // case, and it is put in one form, so that a composed and a decomposed `é` are equal.
            if bytes.contains(where: { byte in byte >= 0x80 }) {
                return false
            }
            var gap = false
            var started = false
            for var byte in bytes {
                if ignoreRepeatedSpaces {
                    if byte == 0x20 || byte == 0x09 {
                        gap = true
                        continue
                    }
                    if gap, started {
                        hash = (hash ^ 0x20) &* 0x100_0000_01b3
                    }
                    gap = false
                    started = true
                }
                if ignoreCase, byte >= 0x41, byte <= 0x5A {
                    byte += 0x20
                }
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            return true
        }
        if !hashed {
            hash = 0xcbf2_9ce4_8422_2325
            for byte in key(line).precomposedStringWithCanonicalMapping.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        } else if !ignoreLineEndings {
            for byte in line.ending.rawValue.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return hash
    }

    /// Whether two lines have the same key; the exact test behind equal hashes.
    internal func isSameKey(_ first: TextLine, _ second: TextLine) -> Bool {
        (first.text == second.text && (ignoreLineEndings || first.ending == second.ending)) || key(first) == key(second)
    }

    /// The hashes of many lines; long files are spread over all cores, because folding case
    /// and spaces is the expensive part of preparing a comparison.
    internal func hashes(_ lines: [TextLine]) -> [UInt64] {
        guard lines.count >= 20_000 else {
            return lines.map(hash)
        }
        let size = max(2_000, lines.count / (ProcessInfo.processInfo.activeProcessorCount * 4))
        let ranges = stride(from: 0, to: lines.count, by: size).map { start in start..<min(start + size, lines.count) }
        return Parallel.map(ranges) { range in lines[range].map(hash) }.flatMap(\.self)
    }
}
