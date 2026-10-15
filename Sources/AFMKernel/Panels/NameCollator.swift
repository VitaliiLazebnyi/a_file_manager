import Foundation
import os

/// The system's collator for the user's language, which makes the collation keys that define the
/// order of names.
///
/// It is reached directly, because Foundation offers a comparison of two strings but not the keys,
/// and that comparison is not an order (see `Sorter`). Should the collator be missing, names are
/// ordered by their lowercase forms: still an order in the strict sense, only not the language's.
///
/// Unchecked: immutable after `init`, and the collator may make keys on several threads at
/// once, as long as nobody changes its settings, which nothing does after `init`.
internal final class NameCollator: @unchecked Sendable {
    /// ICU's `UCOL_ALTERNATE_HANDLING`: whether punctuation counts.
    private static let alternateHandling: Int32 = 1
    /// ICU's `UCOL_NORMALIZATION_MODE`.
    private static let normalization: Int32 = 4
    /// ICU's `UCOL_STRENGTH`.
    private static let strength: Int32 = 5
    /// ICU's `UCOL_NUMERIC_COLLATION`: runs of digits by their value.
    private static let numericCollation: Int32 = 7
    /// ICU's `UCOL_SECONDARY`: letters and accents count, case does not.
    private static let secondary: Int32 = 1
    /// ICU's `UCOL_ON`.
    private static let switchedOn: Int32 = 17
    /// ICU's `UCOL_NON_IGNORABLE`: punctuation counts like any character.
    private static let nonIgnorable: Int32 = 21

    /// The collators made so far, by language and kind (`key(_:numeric:)`).
    private static let cache = OSAllocatedUnfairLock(initialState: [String: NameCollator]())

    /// The collator of the user's language as it is now.
    internal static var current: NameCollator { shared(Locale.current.collatorIdentifier, numeric: false) }

    /// The same collator with runs of digits ordered by their value (`file2` before
    /// `file10`): the order of `Sorter.compare(_:_:numeric:)`, not of the panels' lists.
    internal static var currentNumeric: NameCollator {
        shared(Locale.current.collatorIdentifier, numeric: true)
    }

    /// The library's collator and the library; nil when there is none, and names are ordered
    /// by their lowercase forms.
    private let collator: (handle: OpaquePointer, library: CollationLibrary)?

    /// The collator of a language (an ICU identifier such as `ru`; nil for ICU's default), with runs
    /// of digits ordered by their value or not, from `library`.
    ///
    /// Without the library, or when it cannot make the collator, names are ordered by their
    /// lowercase forms.
    internal init(identifier: String?, numeric: Bool, library: CollationLibrary?) {
        var status: Int32 = 0
        guard let library, let handle = library.open(identifier, &status) else {
            collator = nil
            return
        }
        library.setAttribute(handle, Self.alternateHandling, Self.nonIgnorable, &status)
        library.setAttribute(handle, Self.normalization, Self.switchedOn, &status)
        library.setAttribute(handle, Self.strength, Self.secondary, &status)
        if numeric { library.setAttribute(handle, Self.numericCollation, Self.switchedOn, &status) }
        guard status <= 0 else {
            library.close(handle)
            collator = nil
            return
        }
        collator = (handle, library)
    }

    /// The collator of a language, made once and then shared.
    private static func shared(_ identifier: String?, numeric: Bool) -> NameCollator {
        let key = "\(numeric) \(String(describing: identifier))"
        return cache.withLock { known in
            if let found = known[key] {
                return found
            }
            let made = NameCollator(identifier: identifier, numeric: numeric, library: .system)
            known[key] = made
            return made
        }
    }

    /// Writes the key of a text given in UTF-16 into `key` and returns the key's length.
    ///
    /// A length above the buffer's means the key did not fit and nothing usable was written; the
    /// caller comes again with more room.
    internal func writeKey(of text: UnsafeBufferPointer<UInt16>, into key: UnsafeMutableBufferPointer<UInt8>) -> Int {
        if let (handle, library) = collator {
            let room = Int32(min(key.count, Int(Int32.max)))
            return Int(library.sortKey(handle, text.baseAddress, Int32(clamping: text.count), key.baseAddress, room))
        }
        // Without the system's collator: the lowercase form, which at least ignores case.
        let lowercase = Array(String(decoding: text, as: UTF16.self).lowercased().utf8)
        if lowercase.count <= key.count {
            _ = UnsafeMutableBufferPointer(rebasing: key[..<lowercase.count]).initialize(fromContentsOf: lowercase)
        }
        return lowercase.count
    }

    /// Hands `body` the key of a name or of a part of one; an empty key for the empty text.
    ///
    /// The key lives in memory of the call's own, on the stack for names of ordinary length.
    internal func withKey<Result>(of text: String, _ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        // As the records of a list take it: in UTF-8, where a broken half of a character
        // (a name can come from the system with one) has become the replacement character.
        var text = text
        text.makeContiguousUTF8()
        let unitCount = text.utf16.count
        guard unitCount > 0 else {
            return body(UnsafeBufferPointer(start: nil, count: 0))
        }
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: unitCount) { units in
            _ = units.initialize(from: text.utf16)
            return withKey(of: UnsafeBufferPointer(units), room: unitCount * 6 + 32, body)
        }
    }

    /// Hands `body` the key of UTF-16 text, made in `room` bytes, or in as many as it needs.
    private func withKey<Result>(
        of units: UnsafeBufferPointer<UInt16>,
        room: Int,
        _ body: (UnsafeBufferPointer<UInt8>) -> Result
    ) -> Result {
        var needed = room
        let result: Result? = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: room) { key in
            let length = writeKey(of: units, into: key)
            guard length <= room else {
                // Too short: again, with room for the whole key.
                needed = length
                return nil
            }
            return body(UnsafeBufferPointer(rebasing: key[..<length]))
        }
        return result ?? withKey(of: units, room: needed, body)
    }

    deinit {
        if let (handle, library) = collator { library.close(handle) }
    }
}
