import Foundation

/// UUEncode and XXEncode: their lines, the `end` line, and the `sum -r/size` line that may follow it.
extension DecodeMachine {
    /// The alphabet a first line is in; unknown when the line is of neither.
    ///
    /// A line that fits UUEncode exactly is UUEncode; XXEncode has no character below `+`.
    private static func alphabet(of line: ArraySlice<UInt8>) -> SixBitAlphabet {
        let asUU = try? SixBitText.decode(line, xxEncode: false)
        let asXX = try? SixBitText.decode(line, xxEncode: true)
        if let asUU, line.count - 1 == (asUU.count + 2) / 3 * 4 {
            return .uuEncode
        }
        if asXX != nil {
            return .xxEncode
        }
        return asUU != nil ? .uuEncode : .unknown
    }

    /// Reads a line of six-bit text, in `alphabet`, or finds the alphabet on the first line.
    internal func readSixBit(_ line: ArraySlice<UInt8>, alphabet: SixBitAlphabet) throws {
        if line.elementsEqual(Array("end".utf8)) {
            let finished = tally
            try close()
            awaitingTrailer = finished
            return
        }
        guard !line.isEmpty else {
            return
        }
        var found = alphabet
        if found == .unknown {
            found = Self.alphabet(of: line)
            state = .sixBit(found)
        }
        // What is not a line of the format (a mail's own lines between parts) is passed over,
        // and counted: it is harmless when the size at the end agrees, damage when not.
        guard found != .unknown, let bytes = try? SixBitText.decode(line, xxEncode: found == .xxEncode) else {
            tally.skippedLines += 1
            return
        }
        guard !bytes.isEmpty else {
            return
        }
        // Only the last line of a file is shorter than the others.
        if let last = tally.lastCount, let full = tally.fullCount, last < full {
            tally.shortLinesInside += 1
        }
        tally.lastCount = bytes.count
        tally.fullCount = tally.fullCount ?? bytes.count
        tally.size += Int64(bytes.count)
        // The checksum of Unix `sum -r`: a 16-bit sum that is rotated before every byte.
        var sum = tally.sum
        for byte in bytes {
            sum = ((sum >> 1) + ((sum & 1) << 15) + UInt32(byte)) & 0xFFFF
        }
        tally.sum = sum
        try sink.write(bytes)
    }

    /// `sum -r/size 12345/450`.
    private func trailer(_ line: ArraySlice<UInt8>) -> (sum: UInt32, size: Int64)? {
        let prefix = Array("sum -r/size ".utf8)
        guard line.starts(with: prefix) else {
            return nil
        }
        let numbers = text(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard numbers.count == 2, let sum = UInt32(numbers[0]), let size = Int64(numbers[1]) else {
            return nil
        }
        return (sum, size)
    }

    /// Checks a finished file against its `sum -r/size` line, or, without one, says what nothing confirms.
    internal func check(_ pending: SixBitTally, against trailer: (sum: UInt32, size: Int64)?) {
        awaitingTrailer = nil
        let name = pending.name ?? "(no name)"
        if let trailer {
            if trailer.size != pending.size {
                reportNamed(
                    "\(name): \(pending.size) bytes were decoded, but the text says \(trailer.size): lines are missing "
                        + "or damaged"
                )
            } else if trailer.sum != pending.sum {
                reportNamed("\(name): the checksum (sum -r) does not match: the data is damaged")
            }
        } else if pending.skippedLines > 0 || pending.shortLinesInside > 0 {
            reportNamed(
                "\(name): \(pending.skippedLines + pending.shortLinesInside) lines could not be read or are out of "
                    + "place and nothing confirms the size"
            )
        }
    }

    /// Looks at the line after `end`: the `sum -r/size` line that checks the file, if there is one.
    ///
    /// Returns true when the line was that one.
    internal func resolveTrailer(with line: ArraySlice<UInt8>) -> Bool {
        guard let pending = awaitingTrailer, !line.isEmpty else {
            return false
        }
        if let found = trailer(line) {
            check(pending, against: found)
            return true
        }
        check(pending, against: nil)
        return false
    }
}
