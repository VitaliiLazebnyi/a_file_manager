import Foundation
import Testing

@testable import NetworkPlugin

/// Text-mode conversion in blocks, against the plain byte-by-byte rule.
@Suite
internal struct NetworkFixLineEnds {
    private struct Reference {
        var pendingCR = false

        mutating func toLocal(_ data: Data) -> Data {
            var result = Data()
            for byte in data {
                if pendingCR {
                    pendingCR = false
                    if byte != 0x0A { result.append(0x0D) }
                }
                if byte == 0x0D { pendingCR = true } else { result.append(byte) }
            }
            return result
        }
        mutating func finish() -> Data {
            defer { pendingCR = false }
            return pendingCR ? Data([0x0D]) : Data()
        }
        mutating func toNetwork(_ data: Data) -> Data {
            var result = Data()
            for byte in data {
                if byte == 0x0A, !pendingCR { result.append(0x0D) }
                pendingCR = byte == 0x0D
                result.append(byte)
            }
            return result
        }
    }

    /// Random data cut into random blocks converts as the byte-by-byte rule does, in both directions.
    @Test
    internal func agreesWithTheByteByByteRule() {
        var generator = SystemRandomNumberGenerator()
        let alphabet: [UInt8] = [0x0D, 0x0A, 0x41, 0x0D, 0x0A, 0x20]
        for _ in 0..<300 {
            // Random data cut into random blocks, rich in CR and LF.
            let data = Data(
                (0..<Int.random(in: 0...120, using: &generator))
                    .map { _ in
                        alphabet[Int.random(in: alphabet.indices, using: &generator)]
                    }
            )
            var cuts = [0]
            var end = 0
            while end < data.count {
                end = min(data.count, end + Int.random(in: 0...9, using: &generator))
                cuts.append(end)
            }
            var (local, reference) = (LineEndConverter(), Reference())
            var (got, expected) = (Data(), Data())
            for index in 1..<cuts.count {
                let block = data.subdata(in: cuts[index - 1]..<cuts[index])
                got.append(local.toLocal(block))
                expected.append(reference.toLocal(block))
            }
            got.append(local.finishLocal())
            expected.append(reference.finish())
            #expect(got == expected)

            var (outgoing, outgoingReference) = (LineEndConverter(), Reference())
            var (sent, sentExpected) = (Data(), Data())
            for index in 1..<cuts.count {
                let block = data.subdata(in: cuts[index - 1]..<cuts[index])
                sent.append(outgoing.toNetwork(block))
                sentExpected.append(outgoingReference.toNetwork(block))
            }
            #expect(sent == sentExpected)
        }
        var converter = LineEndConverter()
        #expect(converter.toLocal(Data("a\r\nb\r\n".utf8)) == Data("a\nb\n".utf8))
        #expect(converter.toNetwork(Data("a\nb\r\nc\n".utf8)) == Data("a\r\nb\r\nc\r\n".utf8))
        #expect(converter.toLocal(Data()).isEmpty && converter.toNetwork(Data()).isEmpty)
    }
}
