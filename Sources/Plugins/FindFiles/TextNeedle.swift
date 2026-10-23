import AFMKernel
import Foundation

/// One way the text of a `TextPattern` can appear as bytes.
///
/// Every element is one character (or one byte of a hex string) with the byte sequences that
/// stand for it: one, or two where upper and lower case both count.
internal struct TextNeedle {
    /// Per character, the byte sequences that stand for it.
    internal let elements: [[[UInt8]]]
    /// Bytes per code unit: 2 for UTF-16.
    internal let unit: Int
    /// The code units of UTF-16 come high byte first.
    internal let bigEndian: Bool
    /// The text is found only where no letter, digit or `_` is next to it.
    internal let wholeWords: Bool
    /// The fewest bytes the text can take.
    internal let minLength: Int
    /// The most bytes the text can take.
    internal let maxLength: Int
    /// Whether a byte can start the text; most positions of a file are ruled out by this.
    internal let firstBytes: [Bool]
    /// The bytes of the text when there is only one way to write it, found with `memmem`; empty otherwise.
    internal let literal: [UInt8]

    /// The needle of `elements` in code units of `unit` bytes, high byte first with `bigEndian`.
    internal init(elements: [[[UInt8]]], unit: Int, bigEndian: Bool, wholeWords: Bool) {
        self.elements = elements
        self.unit = unit
        self.bigEndian = bigEndian
        self.wholeWords = wholeWords
        // Every element has at least one way to be written.
        minLength = elements.reduce(0) { sum, element in sum + element.reduce(Int.max) { min($0, $1.count) } }
        maxLength = elements.reduce(0) { sum, element in sum + element.reduce(0) { max($0, $1.count) } }
        var first = [Bool](repeating: false, count: 256)
        for alternative in elements.prefix(1).joined() {
            if let byte = alternative.first {
                first[Int(byte)] = true
            }
        }
        firstBytes = first
        literal = !wholeWords && elements.allSatisfy { $0.count == 1 } ? elements.flatMap { $0[0] } : []
    }

    /// Looks for any of `needles` in what `reader` delivers, block by block.
    ///
    /// The end of each block is looked at again together with the next one, so a hit across a block
    /// border is found, with the characters around it.
    internal static func search(
        _ needles: [Self],
        _ reader: any FileReader,
        _ cancellation: CancellationFlag?,
        _ blockSize: Int
    ) -> TextSearchOutcome {
        let overlap = needles.reduce(0) { max($0, $1.maxLength) } + 2
        var carry = Data()
        var carryStartsFile = true
        do {
            var current = try reader.read(upToCount: blockSize)
            while let block = current {
                if cancellation?.isCancelled == true {
                    return .undecided
                }
                // The blocks are big and short-lived: a search thread frees them as it goes.
                let found: Bool = try autoreleasepool {
                    let next = try reader.read(upToCount: blockSize)
                    let isLast = next?.isEmpty ?? true
                    let buffer = carry + block
                    let isStart = carry.isEmpty || carryStartsFile
                    let hit = buffer.withUnsafeBytes { hay in
                        needles.contains { $0.occurs(in: hay, skip: isStart ? 0 : $0.unit, isLast: isLast) }
                    }
                    carryStartsFile = carryStartsFile && buffer.count <= overlap
                    carry = Data(buffer.suffix(overlap))
                    // After the last block the loop ends, as it does at once for an empty file.
                    current = isLast ? nil : next
                    return hit
                }
                if found {
                    return .found
                }
            }
        } catch {
            return .undecided
        }
        return .missing
    }

    /// Looks for the text in a piece of a file. `skip` start positions at the front were
    /// judged with the piece before; with `isLast` false, a hit that touches the end of
    /// the piece is left to the next one when the character after it matters.
    internal func occurs(in hay: UnsafeRawBufferPointer, skip: Int, isLast: Bool) -> Bool {
        guard minLength > 0, hay.count >= minLength, let base = hay.baseAddress else {
            return false
        }
        if !literal.isEmpty {
            return literal.withUnsafeBytes { memmem(base, hay.count, $0.baseAddress, $0.count) != nil }
        }
        let bytes = hay.bindMemory(to: UInt8.self)
        // The state of `match`, made once for all the start positions of the piece.
        var positions = [Int](repeating: 0, count: elements.count + 1)
        var tried = [Int](repeating: 0, count: elements.count)
        for start in skip...(hay.count - minLength) where firstBytes[Int(bytes[start])] {
            if match(
                bytes,
                at: start,
                positions: &positions,
                tried: &tried,
                accept: { end in
                    !wholeWords
                        || (isBoundary(bytes, before: start) && isBoundary(bytes, after: end, isLast: isLast))
                }
            ) {
                return true
            }
        }
        return false
    }

    /// Tries the alternatives of the elements one after the other, going back to the
    /// element before when one has none left.
    ///
    /// Iterative, with the state in two arrays: a text of any length is matched on the small
    /// stack of a search thread.
    private func match(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at start: Int,
        positions: inout [Int],
        tried: inout [Int],
        accept: (Int) -> Bool
    ) -> Bool {
        let count = elements.count
        positions[0] = start
        tried[0] = 0
        var element = 0
        // Back before the first element, every way to write the text was tried.
        while element >= 0 {
            if element == count {
                if accept(positions[count]) {
                    return true
                }
                // Not accepted (a word continues): look for another way to write the text.
                // (There is at least one element, so there is one to go back to.)
                element -= 1
                continue
            }
            if advance(bytes, element: element, positions: &positions, tried: &tried) {
                element += 1
                if element < count {
                    tried[element] = 0
                }
            } else {
                element -= 1
            }
        }
        return false
    }

    /// Tries the alternatives of `element` that are left at its position; true when one is there, and
    /// the position after it is noted for the next element.
    private func advance(
        _ bytes: UnsafeBufferPointer<UInt8>,
        element: Int,
        positions: inout [Int],
        tried: inout [Int]
    ) -> Bool {
        let alternatives = elements[element]
        let position = positions[element]
        while tried[element] < alternatives.count {
            let alternative = alternatives[tried[element]]
            tried[element] += 1
            guard position + alternative.count <= bytes.count else {
                continue
            }
            var same = true
            for index in alternative.indices where bytes[position + index] != alternative[index] {
                same = false
                break
            }
            if same {
                positions[element + 1] = position + alternative.count
                return true
            }
        }
        return false
    }

    private func isWordUnit(_ bytes: UnsafeBufferPointer<UInt8>, at position: Int) -> Bool {
        var value = UInt16(bytes[position])
        if unit == 2 {
            let other = UInt16(bytes[position + 1])
            value = bigEndian ? value << 8 | other : other << 8 | value
        }
        // Letters outside ASCII count as parts of words without being looked at closely.
        return value >= 0x80 || value == 0x5F || (0x30...0x39).contains(value) || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
    }

    private func isBoundary(_ bytes: UnsafeBufferPointer<UInt8>, before start: Int) -> Bool {
        start < unit || !isWordUnit(bytes, at: start - unit)
    }

    private func isBoundary(_ bytes: UnsafeBufferPointer<UInt8>, after end: Int, isLast: Bool) -> Bool {
        guard end + unit <= bytes.count else {
            return isLast
        }
        return !isWordUnit(bytes, at: end)
    }
}
