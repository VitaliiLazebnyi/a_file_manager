import AFMKernel
import Foundation

/// Going to a place: a position in percent (or the zoom of an image), an offset, a line.
extension ViewerPane {
    /// A number as the user types it: `50.5`, `20,7`, `50 %`.
    internal static func number(in text: String) -> Double? {
        Double(
            text
                .replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
        )
    }

    /// A byte offset as the user types it: decimal, or hexadecimal with `0x` or `$`.
    internal static func offset(in text: String) -> Int64? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "").lowercased()
        if cleaned.hasPrefix("0x") {
            return Int64(cleaned.dropFirst(2), radix: 16)
        }
        if cleaned.hasPrefix("$") {
            return Int64(cleaned.dropFirst(), radix: 16)
        }
        return Int64(cleaned)
    }

    /// "Go to position (in %)": decimals with `.` or `,` (spec 10 › Position and zoom item).
    ///
    /// In image mode the same item sets the zoom factor.
    internal func goToPercent() {
        let isImage = imageView != nil
        guard isImage || showsText,
            let answer = kernel.interaction.prompt(
                isImage ? "Zoom (in %)" : "Go to position (in %)",
                value: percentText.replacingOccurrences(of: " %", with: "")
            ),
            let value = Self.number(in: answer)
        else { return }
        if let imageView { imageView.setZoom(CGFloat(value / 100)) } else { pager.scroll(toPercent: value) }
    }

    /// "Go to offset": a byte offset, kept within the file.
    internal func goToOffset() {
        guard let document = pager.document,
            let answer = kernel.interaction.prompt(
                "Go to offset",
                value: "",
                detail: "Decimal, or hexadecimal as 0x1F40."
            ),
            let offset = Self.offset(in: answer)
        else { return }
        pager.reveal(offset: min(max(0, offset), max(0, document.length - 1)))
    }

    /// "Go to line": the user is told when there is no such line, or it has not been read yet.
    internal func goToLine() {
        guard showsText, let answer = kernel.interaction.prompt("Go to line", value: ""),
            let line = Int(answer.trimmingCharacters(in: .whitespaces))
        else { return }
        pager.scroll(toLine: line) { [weak self] found in
            guard let self, !found else {
                return
            }
            kernel.interaction.inform(
                pager.isIndexing
                    ? "Line \(line) has not been read yet; try again in a moment." : "There is no line \(line)."
            )
        }
    }
}
