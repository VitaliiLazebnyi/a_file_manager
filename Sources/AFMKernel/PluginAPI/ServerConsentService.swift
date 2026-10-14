public import Foundation

/// Telling the plugin that connects to servers which addresses the user chose in person.
/// Offered by the network plugin; called by whoever takes a location from the keyboard (the
/// command line, the path field), and by nobody for a location that was read from a file (a
/// tab file, a list, a link, a dropped item): for those the user is asked before the first
/// login to a server that is not a saved connection. Found through `Kernel.services`; the
/// protocol is the kernel's, because the kernel hands typed places to it (`userTyped`).
@MainActor
public protocol ServerConsentService {
    /// The user typed this location just now. Main thread.
    func userChose(_ location: URL)
}

extension Kernel {
    /// Says that the user typed `text` as a place just now, in the field of a dialog or of a
    /// window: if it names a server by its address, that server is the user's own choice and
    /// is not asked about ("Connect to X?") when it is first reached. Whoever reads a place
    /// from the keyboard calls this with what was typed, before the place is used.
    ///
    /// `proposal` is what the program had put into the field: text that was left as it was
    /// has not been typed (it may stand for a place that came out of a file), and nothing is
    /// said for it. Nothing is said either for text without an address in it (`scheme://`),
    /// which is every ordinary path: those cost one look at the text. Main thread.
    public func userTyped(location text: String, proposal: String? = nil, relativeTo base: URL) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text != proposal?.trimmingCharacters(in: .whitespaces), text.contains("://"),
            let consent = services.find((any ServerConsentService).self)
        else { return }
        consent.userChose(fileSystems.location(from: text, relativeTo: base))
    }
}
