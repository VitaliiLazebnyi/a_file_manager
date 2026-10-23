import Foundation

/// What became of changes that could not be written into their archive.
internal enum RescueOutcome {
    /// They could not be written anywhere; their compressed data stays in this folder, with a
    /// list (`index.txt`) of which file is which member.
    case kept(URL)
    /// Nothing was waiting that exists nowhere else (renames, deletions).
    case nothingToSave
    /// The new members were written into this archive of their own.
    case saved(URL)
}
