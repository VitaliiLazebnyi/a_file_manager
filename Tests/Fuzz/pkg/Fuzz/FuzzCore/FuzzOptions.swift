/// The options of `fuzz` and of the workers it starts.
internal struct FuzzOptions {
    /// The output folder: corpus, findings, statistics.
    internal var out = ""
    /// A folder of extra seed inputs.
    internal var seedsDir = ""
    /// Seconds to fuzz.
    internal var time = 60.0
    /// Seconds one input may take.
    internal var timeout = 2.0
    /// Megabytes of memory a worker may use.
    internal var rssMB = 2_048
    /// The seed of the mutations; without one each worker starts from the time and its process number.
    internal var seed: UInt64?
    /// Inputs to run at most.
    internal var maxExecs = Int.max

    /// The options in `arguments`; unknown ones are ignored.
    internal init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let value = index + 1 < arguments.count ? arguments[index + 1] : ""
            if apply(arguments[index], value) {
                index += 1
            }
            index += 1
        }
    }

    /// Takes in one option and its value; false when the option is unknown and has no value.
    private mutating func apply(_ option: String, _ value: String) -> Bool {
        switch option {
        case "--out":
            out = value

        case "--seeds":
            seedsDir = value

        case "--time":
            time = Double(value) ?? 60

        case "--timeout":
            timeout = Double(value) ?? 2

        case "--rss":
            rssMB = Int(value) ?? 2_048

        case "--seed":
            seed = UInt64(value) ?? 1

        case "--execs":
            maxExecs = Int(value) ?? Int.max

        default:
            return false
        }
        return true
    }
}
