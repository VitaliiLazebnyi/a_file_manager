import Foundation

/// Base64: the digits of the lines collected and decoded four at a time, up to the padding, a boundary or the
/// next file.
extension DecodeMachine {
    /// A line that starts with `--` and cannot be Base64 (after the padding it may end in): a boundary.
    private static func looksLikeBoundary(_ line: ArraySlice<UInt8>) -> Bool {
        var body = line
        while body.last == UInt8(ascii: "="), line.count - body.count < 2 {
            body = body.dropLast()
        }
        return body.contains { byte in base64Values[Int(byte)] == 255 }
    }

    /// Reads a line of a Base64 body.
    internal func readBase64(_ line: ArraySlice<UInt8>, endsAtMark: Bool, mime: Bool) throws {
        // A boundary of the mail, or the end mark of `uuencode -m`.
        if endsAtMark, line.starts(with: Array("====".utf8)) {
            sawEndMark = true
            try close()
            return
        }
        // `-` is a digit of the URL-safe alphabet: outside a mail a line starting with `--` is
        // a boundary only when it is not Base64 (a file that starts with "----" is data).
        if line.starts(with: [45, 45]), mime || Self.looksLikeBoundary(line) {
            try close()
            return
        }
        // The next file or mail part starts here, with or without a boundary in between.
        if Self.startsNewFile(line) {
            try close()
            try feed(line)
            return
        }
        if takeDigits(of: line) {
            try close()
            return
        }
        if sextets.count >= 4_096 {
            try flushBase64(final: false)
        }
    }

    /// Takes the Base64 digits of a line, and notes how the line looks; true when it ends in padding, which is
    /// the end of the data.
    private func takeDigits(of line: ArraySlice<UInt8>) -> Bool {
        var padded = false
        var stray = 0
        sextets.reserveCapacity(sextets.count + line.count)
        Self.base64Values.withUnsafeBufferPointer { table in
            for character in line {
                let value = table[Int(character)]
                if value != 255 {
                    sextets.append(value)
                } else if character == UInt8(ascii: "=") {
                    padded = true
                    break
                } else if character != 32, character != 9 {
                    stray += 1
                }
            }
        }
        strayCharacters += stray
        if !line.isEmpty {
            if bodyLines == 0 {
                firstLineLength = line.count
            }
            bodyLines += 1
            lastLineLength = line.count
        }
        return padded
    }

    /// Decodes the whole groups of four digits collected, and with `final` the rest as well.
    internal func flushBase64(final: Bool) throws {
        let groups = sextets.count / 4
        var bytes = [UInt8](repeating: 0, count: groups * 3 + 3)
        var length = 0
        sextets.withUnsafeBufferPointer { digits in
            bytes.withUnsafeMutableBufferPointer { out in
                for group in 0..<groups {
                    let (first, second, third, fourth) = (
                        digits[group * 4], digits[group * 4 + 1], digits[group * 4 + 2], digits[group * 4 + 3]
                    )
                    out[group * 3] = first << 2 | second >> 4
                    out[group * 3 + 1] = second << 4 | third >> 2
                    out[group * 3 + 2] = third << 6 | fourth
                }
                length = groups * 3
                if final {
                    let rest = digits.count - groups * 4
                    if rest >= 2 {
                        out[length] = digits[groups * 4] << 2 | digits[groups * 4 + 1] >> 4
                        length += 1
                    }
                    if rest == 3 {
                        out[length] = digits[groups * 4 + 1] << 4 | digits[groups * 4 + 2] >> 2
                        length += 1
                    }
                }
            }
        }
        sextets.removeFirst(groups * 4)
        if final {
            // One digit left over cannot stand for a byte: the text was cut off or damaged.
            if sextets.count == 1 {
                report("the Base64 text ends in the middle of a group")
            }
            if strayCharacters > 0 {
                report("\(strayCharacters) characters that are not Base64 were skipped")
            }
            sextets = []
        }
        if length > 0 {
            try sink.write(Array(bytes[0..<length]))
        }
    }
}
