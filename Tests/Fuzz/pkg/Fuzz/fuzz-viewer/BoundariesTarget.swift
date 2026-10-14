import Foundation
import FuzzCore

@testable import ViewerPlugin

/// The `boundaries` target: where a character of a double-byte encoding starts, found far into the file
/// against decoding from the start.
internal enum BoundariesTarget {
    /// The target.
    @MainActor
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "boundaries",
            maxLen: 4_096,
            rawDict: [
                [0x81, 0x40], [0x82, 0xA0], [0x81], [0xFE, 0xFE], [0x0A], [0x20], [0x81, 0x3F], [0xE0, 0x40], [0x80],
                [0xFF], [0xA1, 0xA1], [0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81]
            ],
            seeds: seeds,
            run: run
        )
    }

    /// The inputs the fuzzer starts from: an encoding, the spacing, the content's start, the probes, then the bytes.
    internal static func seeds() -> [[UInt8]] {
        [
            [0, 0, 0, 30] + [UInt8](repeating: 0x82, count: 70) + [0xA0, 0x0A, 0x41]
                + [UInt8](repeating: 0x81, count: 41),
            [1, 3, 2, 20] + (0..<120).map { UInt8(0x81 + ($0 * 7) % 0x7E) }, [2, 9, 1, 10, 0x41, 0x81],
            [3, 1, 0, 9, 0x81, 0x40, 0x81, 0x30, 0x81]
        ]
    }

    /// Runs one input.
    @MainActor
    internal static func run(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        guard !kDoubleByte.isEmpty else {
            return
        }
        let encoding = kDoubleByte[choices.int(kDoubleByte.count)]
        let spacing = 16 + Int(choices.byte())
        let lower = Int(choices.byte()) % 8
        let probes = Int(choices.byte())
        let data = choices.rest()
        let content = Int64(min(lower, data.count))..<Int64(data.count)
        let source = DataByteSource(Data(data))
        let expected = expectedStarts(data, content: content, encoding: encoding)
        let boundaries = CharacterBoundaries(source: source, content: content, encoding: encoding, spacing: spacing)
        var probe = Choices(bytes.reversed())
        let what = "cp \(encoding.codePage) spacing \(spacing) content \(content)"
        for turn in 0..<min(40, probes + 1) where !content.isEmpty {
            // First far in, where the block's boundary has to be found without the ones before.
            let offset =
                turn == 0 ? content.upperBound - 1 : content.lowerBound + Int64(Int(probe.u16()) % Int(content.count))
            guard let got = try? boundaries.characterStart(atOrBefore: offset) else {
                fzFail("boundaries-threw", what)
            }
            fzCheck(
                got == expected[Int(offset)],
                "boundaries-differ-from-decoder",
                "\(what): offset \(offset) gives \(got), decoding from the start gives \(expected[Int(offset)])\n"
                    + describe(data)
            )
        }
        _ = try? boundaries.characterStart(atOrBefore: -3)
        _ = try? boundaries.characterStart(atOrBefore: Int64.max)
        _ = boundaries.blockCount
    }

    /// For every offset, the start of the character it is in, as decoding from the content's start counts them.
    private static func expectedStarts(
        _ data: [UInt8],
        content: Range<Int64>,
        encoding: ViewerEncoding
    ) -> [Int64] {
        var text = DecodedText()
        encoding.decode(Array(data[Int(content.lowerBound)...]), final: true, into: &text)
        var isStart = [Bool](repeating: false, count: data.count + 1)
        for offset in text.offsets {
            isStart[Int(content.lowerBound) + Int(offset)] = true
        }
        var expected = [Int64](repeating: content.lowerBound, count: data.count + 1)
        var last = content.lowerBound
        for index in Int(content.lowerBound)..<data.count {
            if isStart[index] {
                last = Int64(index)
            }
            expected[index] = last
        }
        return expected
    }
}
