import AFMKernel
import Foundation

/// yEnc: the escaped bytes of its lines, and the `=ypart` and `=yend` lines that check them.
extension DecodeMachine {
    /// Reads a line of yEnc.
    internal func readYEnc(_ line: ArraySlice<UInt8>) throws {
        if line.starts(with: Array("=yend".utf8)) {
            checkYEnd(text(line))
            try close()
            return
        }
        if line.starts(with: Array("=ypart".utf8)) {
            readYPart(text(line))
            return
        }
        if line.starts(with: Array("=ybegin".utf8)) {
            return
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(line.count)
        var escaped = false
        for character in line {
            if escaped {
                bytes.append(character &- 64 &- 42)
                escaped = false
            } else if character == UInt8(ascii: "=") {
                escaped = true
            } else {
                bytes.append(character &- 42)
            }
        }
        if !bytes.isEmpty {
            yBytes += Int64(bytes.count)
            yCRC.update(Data(bytes))
            try sink.write(bytes)
        }
    }

    /// `=ypart begin=B end=E`: the file is one part, of `E - B + 1` bytes.
    private func readYPart(_ header: String) {
        yHasPart = true
        // The two numbers are whatever the text says. A part begins at byte 1 or later
        // and ends at or after its beginning; only then is its length a number that can
        // be worked out (`end - begin` of numbers from anywhere overflows). Anything
        // else is a damaged header, and is said to be one.
        let (beginText, endText) = (yParameter("begin", in: header), yParameter("end", in: header))
        if let begin = beginText.flatMap({ text in Int64(text) }), let end = endText.flatMap({ text in Int64(text) }),
            begin >= 1, end >= begin
        {
            yPartLength = (end - begin).addingSaturated(1)
        } else if beginText != nil || endText != nil {
            yPartLength = nil
            report("the range of the part (=ypart begin= end=) is not valid: the text is damaged")
        }
    }

    /// The value of ` key=` in a yEnc line (up to the next space).
    internal func yParameter(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: " " + key + "=") else {
            return nil
        }
        return line[range.upperBound...].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init)
    }

    /// `=yend size=N [part=P] [pcrc32=X] [crc32=X]`: compares the size and the CRC32 with what was decoded.
    private func checkYEnd(_ line: String) {
        if let size = yParameter("size", in: line).flatMap({ text in Int64(text) }), size != yBytes {
            report("\(yBytes) bytes were decoded, but =yend says \(size): the text is incomplete or damaged")
        } else if yHasPart, let length = yPartLength, length != yBytes {
            report("\(yBytes) bytes were decoded, but the part holds \(length): the text is incomplete or damaged")
        } else if !yHasPart, let total = yHeaderSize, total != yBytes {
            report("\(yBytes) bytes were decoded, but =ybegin says \(total): the text is incomplete or damaged")
        }
        // A part carries the CRC32 of the part; a single file has only crc32.
        let crcText =
            yHasPart
            ? yParameter("pcrc32", in: line) : (yParameter("crc32", in: line) ?? yParameter("pcrc32", in: line))
        if let crcText, let expected = UInt32(crcText.trimmingCharacters(in: .whitespaces), radix: 16),
            expected != yCRC.checksum
        {
            report("the CRC32 does not match: the data is damaged")
        }
    }
}
