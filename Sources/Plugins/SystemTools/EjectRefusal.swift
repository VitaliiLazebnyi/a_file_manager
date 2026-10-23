/// Why a volume was not ejected: who keeps it in use, if the system says.
public struct EjectRefusal: Error, Equatable {
    /// The program that has something open on the volume, by name; nil when not known.
    public var program: String?
    /// True when that program is this one.
    public var isThisProgram = false
    /// What the system said.
    public var reason: String

    /// A refusal for `reason`; `program` is the one that keeps the volume in use, when known.
    public init(reason: String, program: String? = nil, isThisProgram: Bool = false) {
        (self.reason, self.program, self.isThisProgram) = (reason, program, isThisProgram)
    }
}
