/// The basic generators property tests build theirs from.
///
/// Each makes its simplest value from the smallest choices: zero, `false`, the first element,
/// the empty text.
public enum Generate {
    /// The numbers near the ends of the range of a number, where arithmetic overflows.
    private static let edges: [Int64] = [0, 1, -1, 2, -2, .max, .min, .max - 1, .min + 1, 1 << 32, -(1 << 32)]

    /// `true` or `false`.
    public static var bool: Generator<Bool> {
        Generator { choices in choices.next(below: 2) == 1 }
    }

    /// Any number of 64 bits: small ones, the ends of the range and their neighbours, and any
    /// other, about a third each.
    public static var int64: Generator<Int64> {
        Generator { choices in
            switch choices.next(below: 3) {
            case 0:
                let small = Int64(choices.next(below: 512))
                return small.isMultiple(of: 2) ? small / 2 : -(small + 1) / 2

            case 1:
                return edges[Int(choices.next(below: UInt64(edges.count)))]

            default:
                return Int64(bitPattern: choices.nextWord())
            }
        }
    }

    /// A number in `range`, shrinking towards its lower end.
    public static func int(in range: ClosedRange<Int>) -> Generator<Int> {
        Generator { choices in
            let width = UInt64(range.upperBound - range.lowerBound) + 1
            return range.lowerBound + Int(choices.next(below: width))
        }
    }

    /// One of the values, shrinking towards the first.
    public static func element<Value: Sendable>(of values: [Value]) -> Generator<Value> {
        precondition(!values.isEmpty)
        return Generator { choices in values[Int(choices.next(below: UInt64(values.count)))] }
    }

    /// A value of one of the generators, shrinking towards the first.
    public static func oneOf<Value>(_ generators: [Generator<Value>]) -> Generator<Value> {
        element(of: generators).flatMap(\.self)
    }

    /// Text made of pieces of `alphabet` (each a character, or several to be put side by side).
    public static func text(from alphabet: [String], lengths: ClosedRange<Int> = 0...12) -> Generator<String> {
        element(of: alphabet).array(lengths).map { $0.joined() }
    }
}
