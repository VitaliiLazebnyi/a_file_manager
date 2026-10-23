import Foundation

/// Replaces the placeholders of a Parameters field (spec 18 › Button and command parameters).
///
/// Pure: it reads nothing but its context and writes nothing.
///
/// Adapted to the Mac: there are no 8.3 names, so the lower-case codes insert the same as the
/// upper-case ones; paths end in `/`; the `%L`/`%F`/`%D` lists are UTF-8 without a mark, with
/// one name per line; `%Z` (archives) is accepted and changes nothing.
///
/// What a placeholder stands for is data and stays apart from the text around it
/// (`ExpandedPiece.value`): no name, however it is written, can become part of the command.
internal struct ParameterExpander {
    /// What the placeholders refer to.
    internal let context: ExpansionContext

    /// Whether a text has a code that needs the marked names of a panel.
    ///
    /// Making that list costs a pass over the whole panel, so it is made only for a text that asks
    /// for it.
    internal static func usesSelection(_ pieces: [ExpandedPiece]) -> Bool {
        let codes = Set("SsRrCcLlDFfdUW".unicodeScalars)
        var found = false
        ExpansionRun.codes(of: ExpansionRun.tokens(of: pieces)) { if codes.contains($0) { found = true } }
        return found
    }

    /// Joins neighbouring texts and takes the blanks off both ends of the line.
    ///
    /// Only blanks the user wrote go: a value keeps every character, a no-break space at its end
    /// included.
    internal static func trimmed(_ pieces: [ExpandedPiece]) -> [ExpandedPiece] {
        var result: [ExpandedPiece] = []
        for piece in pieces {
            if case .text(let text) = piece {
                if text.isEmpty { continue }
                if case .text(let before)? = result.last {
                    result[result.count - 1] = .text(before + text)
                    continue
                }
            }
            result.append(piece)
        }
        func isBlank(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" }
        if case .text(let text)? = result.first {
            let kept = String(String.UnicodeScalarView(text.unicodeScalars.drop(while: isBlank)))
            if kept.isEmpty { result.removeFirst() } else { result[0] = .text(kept) }
        }
        if case .text(let text)? = result.last {
            var scalars = text.unicodeScalars
            while let last = scalars.last, isBlank(last) { scalars.removeLast() }
            if scalars.isEmpty { result.removeLast() } else { result[result.count - 1] = .text(String(scalars)) }
        }
        return result
    }

    /// The pieces without the empty texts.
    ///
    /// (The pieces of a run never hold two texts in a row: a text is written out only in front of a
    /// value or a quote.).
    internal static func withoutEmptyTexts(_ pieces: [ExpandedPiece]) -> [ExpandedPiece] {
        pieces.filter { piece in
            guard case .text(let text) = piece else {
                return true
            }
            return !text.isEmpty
        }
    }

    /// What stands before and after the first `marker` in the text of the pieces; nil without one.
    internal static func split(_ pieces: [ExpandedPiece], at marker: String) -> (
        before: [ExpandedPiece], after: [ExpandedPiece]
    )? {
        for (index, piece) in pieces.enumerated() {
            guard case .text(let text) = piece, let found = text.range(of: marker, options: .literal) else { continue }
            let before = Array(pieces[..<index]) + [.text(String(text[..<found.lowerBound]))]
            let after = [.text(String(text[found.upperBound...]))] + Array(pieces[(index + 1)...])
            return (withoutEmptyTexts(before), withoutEmptyTexts(after))
        }
        return nil
    }

    /// Expands a Parameters field as the user wrote it.
    internal func expand(_ parameters: String) -> ExpandedParameters {
        expand([.text(parameters)])
    }

    /// Expands a text that came out of an expansion before (the parameters one user command
    /// hands to another): its text is read for placeholders, its values pass through.
    internal func expand(_ parameters: [ExpandedPiece]) -> ExpandedParameters {
        var tokens = ExpansionRun.tokens(of: parameters)
        var asksFirst = false
        if case .scalar("?")? = tokens.first {
            asksFirst = true
            tokens.removeFirst()
        }
        var run = ExpansionRun(context: context, tokens: tokens)
        run.expand()
        return ExpandedParameters(
            pieces: Self.trimmed(run.pieces),
            asksFirst: asksFirst,
            listFile: run.listFile,
            usedArguments: run.usedArguments,
            missingName: run.missingName,
            problem: run.problem
        )
    }
}
