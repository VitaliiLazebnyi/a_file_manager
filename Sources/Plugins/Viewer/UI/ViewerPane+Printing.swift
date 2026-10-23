import AFMKernel
import AppKit

/// Printing (spec 10 › Printing from Lister) and Page Setup.
extension ViewerPane {
    /// The most pages of text that are printed; a longer text is cut there, and the user is told.
    nonisolated internal static let printPageLimit = 2_000

    /// The rows of `range` as the document's layout shows them, at most `maxRows` of them (`truncated`
    /// when there are more); none once `cancellation` is set.
    ///
    /// Blocks.
    nonisolated internal static func printableText(
        of document: TextDocument,
        in range: Range<Int64>,
        maxRows: Int,
        cancellation: CancellationFlag
    ) -> PrintableText {
        guard var row = try? document.row(containing: range.lowerBound, cancellation: cancellation) else {
            return PrintableText(lines: [], truncated: false)
        }
        var lines: [String] = []
        while !cancellation.isCancelled,
            let rows = try? document.rows(from: row, count: 512, cancellation: cancellation), !rows.isEmpty
        {
            for line in rows {
                if line.range.lowerBound >= range.upperBound {
                    return PrintableText(lines: lines, truncated: false)
                }
                if lines.count >= maxRows {
                    return PrintableText(lines: lines, truncated: true)
                }
                lines.append(line.text)
            }
            row += rows.count
        }
        return PrintableText(lines: lines, truncated: false)
    }

    /// File › Page Setup (the specification's Print setup): paper and margins.
    internal func pageSetup() {
        let info = printInfo()
        guard dialogs.pageLayout(info) else {
            return
        }
        NSPrintInfo.shared = info
        settings.printMargins = [info.leftMargin, info.rightMargin, info.topMargin, info.bottomMargin]
    }

    /// File › Print (spec 10 › Printing from Lister): text prints as the current mode shows
    /// it, the selection when there is one and the user wants it; images, PDF and pages print
    /// as themselves.
    ///
    /// The print panel is a sheet of the window the user printed from, taken now: a text is
    /// prepared first, and the pane may have left that window by the time it is ready. A pane in
    /// no window has nothing to print from.
    internal func printContent() {
        guard let window else {
            return
        }
        let info = printInfo()
        let paneDialogs = dialogs
        let run = { (operation: NSPrintOperation) in paneDialogs.run(operation, sheetOf: window) }
        if let frame = imageView?.currentFrame {
            run(NSPrintOperation(view: printableImage(frame, on: info), printInfo: info))
        } else if let pdfView {
            dialogs.print(pdfView, with: info)
        } else if let webView {
            run(webView.printOperation(with: info))
        } else if let richText {
            run(NSPrintOperation(view: richText, printInfo: info))
        } else if showsText, let document = pager.document {
            printText(of: document, with: info, sheetOf: window)
        }
    }

    /// The print settings: the shared ones, with the margins Page Setup stored.
    private func printInfo() -> NSPrintInfo {
        var attributes: [NSPrintInfo.AttributeKey: Any] = [:]
        for case (let key as String, let value) in NSPrintInfo.shared.dictionary() {
            attributes[NSPrintInfo.AttributeKey(key)] = value
        }
        let info = NSPrintInfo(dictionary: attributes)
        let margins = settings.printMargins
        if margins.count == 4 {
            (info.leftMargin, info.rightMargin, info.topMargin, info.bottomMargin) = (
                margins[0], margins[1], margins[2], margins[3]
            )
        }
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        return info
    }

    /// An image view of `frame` at the size it prints at on the page of `info`.
    private func printableImage(_ frame: CGImage, on info: NSPrintInfo) -> NSImageView {
        let area = info.imageablePageBounds.size
        let size = NSSize(width: frame.width, height: frame.height)
        let fitting = min(area.width / size.width, area.height / size.height)
        // Fit to window enlarges small images to the page too; otherwise an image is only
        // ever shrunk to fit (spec 10 › File › Print).
        let scale = settings.imageFit == .window ? fitting : min(1, fitting)
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        view.image = NSImage(cgImage: frame, size: size)
        view.imageScaling = .scaleAxesIndependently
        return view
    }

    /// Prints the text (or its selection, when the user wants it) as the current mode shows it; its rows are
    /// prepared in the background first.
    private func printText(of document: TextDocument, with info: NSPrintInfo, sheetOf window: NSWindow) {
        var range = document.content
        if let selection = pager.selection,
            kernel.interaction.choose(
                "Print",
                detail: "Print the selected text or the whole file?",
                buttons: ["Selection", "Whole file"],
                style: .information
            ) == 0
        {
            range = selection
        }
        let font = currentFont
        let generation = loadGeneration
        let page = TextPrintView.pageSize(for: info)
        let linesPerPage = TextPrintView.linesPerPage(font: font, pageHeight: page.height)
        let cancel = CancellationFlag()
        activity = Activity(text: "Preparing to print…", progress: nil, cancel: cancel)
        // Made on the main thread and used there only, by the block that comes back.
        let held = Handover((font: font, info: info))
        // Weakly: the block must not be the last owner of the window or the pane on its thread
        // (a view goes away on the main thread).
        workQueue.async { [weak self, weak window, range] in
            let text = Self.printableText(
                of: document,
                in: range,
                maxRows: Self.printPageLimit * linesPerPage,
                cancellation: cancel
            )
            DispatchQueue.main.async {
                self?
                    .textPrepared(text, generation: generation, cancel: cancel, sheetOf: window) {
                        NSPrintOperation(
                            view: TextPrintView(lines: text.lines, font: held.value.font, pageSize: page),
                            printInfo: held.value.info
                        )
                    }
            }
        }
    }

    /// Prints the text that was prepared (`operation` makes the print operation) with its panel
    /// as a sheet of `window`, telling the user when it was cut short; nothing when the file
    /// changed, printing was stopped or the window has gone.
    private func textPrepared(
        _ text: PrintableText,
        generation: Int,
        cancel: CancellationFlag,
        sheetOf window: NSWindow?,
        operation: () -> NSPrintOperation
    ) {
        if activity?.cancel === cancel { activity = nil }
        guard loadGeneration == generation, !cancel.isCancelled, let window else {
            return
        }
        if text.truncated {
            kernel.interaction.inform(
                "The text is longer than the \(Self.printPageLimit) pages that are printed at most: only its first "
                    + "\(Self.printPageLimit) pages (\(text.lines.count) lines) are printed."
            )
        }
        dialogs.run(operation(), sheetOf: window)
    }
}
