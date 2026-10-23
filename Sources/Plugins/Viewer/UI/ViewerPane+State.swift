import AFMContracts
import AFMKernel
import AppKit

/// What follows from the state of the pane: the encoding, the font and the layout of the text, and what the
/// percent item and the status line say.
extension ViewerPane {
    /// Whether the keyboard is somewhere inside the pane.
    internal var hasKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else {
            return false
        }
        return responder === self || responder.isDescendant(of: self)
    }

    /// Whether a text mode shows a text.
    internal var showsText: Bool { mode.isTextual && pager.document != nil }

    /// Whether a text is shown and part of it is selected.
    internal var hasSelection: Bool { showsText && pager.selection != nil }

    /// F4 opens the editor, for files that are files and are shown as text (spec 10 › F4
    /// inside Lister).
    internal var canEdit: Bool {
        guard let url = item?.url, mode.isTextual, !isEmbedded else {
            return false
        }
        return url.isFileURL && kernel.commands[.edit] != nil
    }

    /// The encoding the current mode shows text in.
    internal var encoding: ViewerEncoding {
        guard let loaded else {
            return .utf8
        }
        switch mode {
        case .utf8:
            return .utf8

        case .unicode:
            if let codePage, codePage.unitSize == 2 {
                return codePage
            }
            return loaded.guess.encoding.unitSize == 2 ? loaded.guess.encoding : .utf16LE

        case .html where strippedHTML != nil:
            return .utf8

        default:
            return codePage ?? fontSlot.encoding
        }
    }

    /// The font of the text modes: the slot's (fixed width in Binary and Hex), at its size changed by Num + and
    /// Num −.
    internal var currentFont: NSFont {
        let slot: FontSlot = fontSlot == .variable && mode != .binary && mode != .hex ? .variable : .ansi
        let chosen = settings.font(slot)
        let size = CGFloat(min(96, max(6, chosen.size + fontSizeChange)))
        if let name = chosen.name, let font = NSFont(name: name, size: size) {
            return font
        }
        return slot == .variable ? .systemFont(ofSize: size) : .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// How the current mode lays out its rows.
    internal var layout: ViewerLayout {
        switch mode {
        case .binary:
            return .binary(width: settings.binaryWidth)

        case .hex:
            return .hex

        default:
            guard settings.wrap else {
                return .text(
                    TextLayoutOptions(columns: settings.unwrapWidth, wordWrap: false, tabWidth: settings.tabWidth)
                )
            }
            let columns = settings.textWidth > 0 ? settings.textWidth : pager.columnsThatFit
            return .text(TextLayoutOptions(columns: columns, wordWrap: true, tabWidth: settings.tabWidth))
        }
    }

    /// The links of the HTML file that is shown as text.
    internal var htmlLinks: [String] { mode == .html ? strippedHTML?.links ?? [] : [] }

    /// What the percent item shows: the position in a text, the zoom of an image (spec 10 ›
    /// Position and zoom item).
    internal var percentText: String {
        if let imageView {
            return String(format: "%.1f %%", imageView.zoom * 100)
        }
        if contentView === pager, pager.document != nil {
            return String(format: "%.0f %%", pager.percent)
        }
        return ""
    }

    /// What the status line says: the running work, else the size of the image or the encoding and the place in
    /// the text, a read error, and the size of the file.
    internal var statusText: String {
        if let activity {
            return activity.text
        }
        guard let loaded else {
            return item == nil ? "" : failure ?? "Reading…"
        }
        var parts: [String] = []
        if let imageView {
            parts.append("\(Int(imageView.imageSize.width)) × \(Int(imageView.imageSize.height))")
            if imageView.isDownsampled { parts.append("shown downsampled") }
            if imageView.framesDropped > 0 { parts.append("\(imageView.framesDropped) frames left out") }
        } else if contentView === pager, let document = pager.document {
            parts += textStatus(of: document)
        } else if contentView === pager, pager.isIndexing {
            // Nothing to draw yet: the rows of the start of the file are not known.
            parts.append(String(format: "Reading… %.0f %%", pager.indexingProgress * 100))
        } else {
            parts.append(mode.title)
        }
        if let error = pager.document?.readError {
            parts.append("Read error: \(error.localizedDescription)")
        }
        parts.append("\(Format.bytes(loaded.source.length)) bytes")
        return parts.joined(separator: "  ·  ")
    }

    /// The parts of the status line for a text: the encoding, the line or offset, the selection, the indexing.
    private func textStatus(of document: TextDocument) -> [String] {
        let isBytes = mode == .hex || mode == .binary
        var parts = [isBytes ? "\(mode.title), \(document.encoding.name)" : document.encoding.name]
        if let position = pager.position {
            parts.append(
                isBytes ? "Offset \(Format.bytes(position.offset))" : "Line \(Format.bytes(Int64(position.line)))"
            )
        }
        if let selection = pager.selection {
            parts.append("\(Format.bytes(selection.upperBound - selection.lowerBound)) bytes selected")
        }
        if pager.isIndexing { parts.append(String(format: "Indexing %.0f %%", pager.indexingProgress * 100)) }
        return parts
    }
}
