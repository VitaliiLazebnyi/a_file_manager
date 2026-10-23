import AFMKernel
import AppKit

/// Printing file lists (spec 12 › Printing, Print directory dialog).
extension SystemTools {
    /// Where the user wants a file list to go, as offered in the dialog (stored by raw value).
    private enum PrintOutput: Int, CaseIterable {
        case printer = 0
        case textFile = 1
        case viewer = 2

        var title: String {
            switch self {
            case .printer:
                return "Printer…"

            case .textFile:
                return "Text file…"

            case .viewer:
                return "Show as text"
            }
        }
    }

    /// Where a printed file list goes.
    private enum Destination {
        case printer
        case file(URL)
        case viewer
    }

    /// A file list made in a job: its pages for the printer or its text for a file or the viewer.
    private struct PrintedList {
        var pages: [[String]]
        /// The length of the longest line of the pages, so the view that prints need not count.
        var longest: Int
        var text: String
        /// Why the list could not be saved; `CocoaError.userCancelled` when the user kept the old file.
        var error: (any Error)?
        /// The job was cancelled: the list is partial.
        var cancelled: Bool
    }

    /// What a file list job is to make, and where it goes.
    private struct ListJob: Sendable {
        let fileSystems: FileSystemRegistry
        let showHidden: Bool
        let withSubfolders: Bool
        let depth: Int
        let mask: String
        let formatter: DirectoryListFormatter
        let output: PrintOutput
        /// The base folder as shown to the user.
        let base: String
        let destination: Destination

        /// Reads the rows of `items` (and of their subfolders, when asked for) and lays them out
        /// for the output; a list for a file is saved to it.
        ///
        /// On the job's thread.
        func read(_ items: [FileItem], monitor: any JobMonitor, interaction: any UserInteraction) -> PrintedList {
            let rows =
                withSubfolders
                ? ListCollector(
                    fileSystems: fileSystems,
                    showHidden: showHidden,
                    mask: ListMask(mask),
                    depth: depth,
                    cancellation: monitor.cancellation
                )
                .rows(of: items)
                : Parallel.map(items, serialBelow: 4_096) { item in ListRow(item, path: item.name) }
            // Only the form the chosen output needs is made.
            let pages = output == .printer ? formatter.pages(directory: base, rows: rows, now: Date()) : []
            let text = output == .printer ? "" : formatter.text(directory: base, rows: rows, now: Date())
            // Measured here: the view that prints would otherwise count every line on the main thread.
            let longest = pages.reduce(0) { longest, page in page.reduce(longest) { max($0, $1.count) } }
            var list = PrintedList(pages: pages, longest: longest, text: text, error: nil, cancelled: false)
            if monitor.cancellation.isCancelled {
                list.cancelled = true
                return list
            }
            guard case .file(let file) = destination else {
                return list
            }
            list.error = save(text, to: file, monitor: monitor, interaction: interaction)
            return list
        }

        /// Writes `text` to `file`, asking first whether an existing one is to be replaced; what
        /// went wrong, if anything.
        ///
        /// Written beside the file and moved over it, so a failure leaves the old file whole.
        func save(_ text: String, to file: URL, monitor: any JobMonitor, interaction: any UserInteraction)
            -> (any Error)?
        {
            do {
                let provider = try fileSystems.provider(for: file)
                let exists = provider.item(at: file) != nil
                if exists {
                    let replace = monitor.ask { @MainActor @Sendable in
                        interaction.choose(
                            "Overwrite:",
                            detail: fileSystems.displayPath(file),
                            buttons: ["Overwrite", "Cancel"],
                            style: .warning
                        ) == 0
                    }
                    guard replace else {
                        return CocoaError(.userCancelled)
                    }
                }
                let temporary = file.deletingLastPathComponent()
                    .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
                do {
                    let writer = try provider.write(temporary)
                    try writer.write(Data(text.utf8))
                    try writer.close(attributes: FileAttributes())
                    try provider.move(temporary, to: file, replacing: exists)
                } catch {
                    try? provider.remove(temporary)
                    throw error
                }
                return nil
            } catch {
                return error
            }
        }
    }

    /// Files › Print › File list (spec 12 › Printing): the selected items, or the whole list
    /// when the cursor is on `[..]` and nothing is selected; Brief prints names only.
    ///
    /// With subfolders, the depth and the files to include are asked first.
    internal func printList(withSubfolders: Bool) {
        let panel = kernel.panels.source
        let tab = panel.model
        let directory = tab.directory
        // The marked items of a long list are picked out in the job, not here: taking the
        // snapshot costs nothing, whatever the length of the list.
        let operands = tab.operandsSnapshot()
        let marked = operands.markedCount
        let count = marked > 0 ? marked : (operands.cursorItem != nil ? 1 : operands.shownItems.count)
        let gather: @Sendable (any JobMonitor) -> [FileItem] = { _ in
            marked > 0 || operands.cursorItem != nil ? operands.items() : operands.shownItems
        }
        var scope = (depth: 0, mask: "*.*")
        if withSubfolders {
            guard let asked = askSubfolderScope() else {
                return
            }
            scope = asked
        }
        guard let layout = askLayout(count: count, of: directory, isDetailed: panel.viewMode != .brief),
            let destination = askDestination(for: layout.output, in: directory)
        else { return }
        let job = ListJob(
            fileSystems: kernel.fileSystems,
            showHidden: tab.showHidden,
            withSubfolders: withSubfolders,
            depth: scope.depth,
            mask: scope.mask,
            formatter: layout.formatter,
            output: layout.output,
            base: kernel.fileSystems.displayPath(directory),
            destination: destination
        )
        let asking = interaction
        kernel.jobs.run(
            title: "Reading file list:",
            work: { monitor in job.read(gather(monitor), monitor: monitor, interaction: asking) },
            completion: { [self] list in deliver(list, of: job) }
        )
    }

    /// Asks how deep to go into the subfolders and which files to include; nil when the user
    /// cancels or the depth is not a number.
    private func askSubfolderScope() -> (depth: Int, mask: String)? {
        guard
            let depthText = interaction.prompt(
                "Print file list with subfolders",
                value: "-1",
                detail: "Depth of subfolders to include (-1 = unlimited):"
            )
        else { return nil }
        guard let depth = Int(depthText.trimmingCharacters(in: .whitespaces)) else {
            interaction.inform("\(depthText) is not a number.")
            return nil
        }
        guard
            let mask = interaction.prompt(
                "Print file list with subfolders",
                value: "*.*",
                detail: "Files to include, e.g. *.doc *.txt, or *.* | *.bak to leave some out:"
            )
        else { return nil }
        return (depth, mask)
    }

    /// The Print directory dialog for `count` items of `directory`: the header, the lines per page,
    /// the details and the output, which are kept for the next time; nil when the user cancels.
    private func askLayout(count: Int, of directory: URL, isDetailed: Bool)
        -> (formatter: DirectoryListFormatter, output: PrintOutput)?
    {
        let lines = settings.index(Self.printLinesKey, default: 60)
        let savedOutput = settings.index(Self.printOutputKey, default: 0)
        let shownDirectory = DisplayText.oneLine(kernel.fileSystems.displayPath(directory), limit: 200)
        guard
            let answer = interaction.form(
                "Print directory",
                detail: "\(count) item(s) of \(shownDirectory)",
                fields: [
                    .text(
                        "header",
                        "Header text:",
                        settings.text(Self.printHeaderKey, default: DirectoryListFormatter.defaultHeader)
                    ),
                    .note("%d folder, %p page, %t pages, %D date, %T time, %% percent sign; empty for no header"),
                    .text("lines", "Lines per page:", String(lines)),
                    .checkbox("details", "Print size, date and attributes", isDetailed),
                    .choice(
                        "output",
                        "Output:",
                        PrintOutput.allCases.map(\.title),
                        selected: PrintOutput(rawValue: savedOutput) == nil ? 0 : savedOutput
                    )
                ],
                buttons: ["Print"]
            )
        else { return nil }
        let output = PrintOutput(rawValue: answer.index("output")) ?? .printer
        var formatter = DirectoryListFormatter()
        formatter.header = answer.text("header")
        formatter.linesPerPage = min(
            max(Int(answer.text("lines").trimmingCharacters(in: .whitespaces)) ?? lines, 5),
            500
        )
        formatter.isDetailed = answer.flag("details")
        settings.set(formatter.header, forKey: Self.printHeaderKey)
        settings.set(formatter.linesPerPage, forKey: Self.printLinesKey)
        settings.set(output.rawValue, forKey: Self.printOutputKey)
        return (formatter, output)
    }

    /// Where the list for `output` goes; nil when the user cancels.
    ///
    /// For a text file its name is asked, relative to `directory`.
    private func askDestination(for output: PrintOutput, in directory: URL) -> Destination? {
        switch output {
        case .printer:
            return .printer

        case .viewer:
            return .viewer

        case .textFile:
            guard
                let name = interaction.prompt("Save file list as:", value: "filelist.txt")?
                    .trimmingCharacters(in: .whitespaces),
                !name.isEmpty
            else { return nil }
            return .file(kernel.fileSystems.location(from: name, relativeTo: directory))
        }
    }

    /// Sends a finished list where it was meant to go; a cancelled read leaves a partial list,
    /// which is neither printed nor shown.
    private func deliver(_ list: PrintedList, of job: ListJob) {
        guard !list.cancelled else {
            return
        }
        switch job.destination {
        case .printer:
            print(list.pages, longestLine: list.longest, linesPerPage: job.formatter.linesPerPage, title: job.base)

        case .file(let file):
            if let error = list.error {
                if (error as? CocoaError)?.code != .userCancelled {
                    interaction.report(error, title: "The file list cannot be saved!")
                }
                return
            }
            note("list-file: \(kernel.fileSystems.displayPath(file))")
            kernel.panels.refresh([file.deletingLastPathComponent()], focus: file)

        case .viewer:
            show(text: list.text, title: "File list - \(job.base)")
        }
    }

    /// Hands the pages to the system's print dialog, which previews them and prints.
    private func print(_ pages: [[String]], longestLine: Int, linesPerPage: Int, title: String) {
        note("print: \(pages.count) pages")
        // The operation prints with a copy of the shared settings, which stay as they are.
        let shared = NSPrintInfo.shared
        let operation = NSPrintOperation(
            view: PagePrintView(pages: pages, longestLine: longestLine, linesPerPage: linesPerPage, printInfo: shared),
            printInfo: shared
        )
        operation.printInfo.isHorizontallyCentered = false
        operation.printInfo.isVerticallyCentered = false
        operation.jobTitle = DisplayText.oneLine(title, limit: 200)
        desktop.print(operation)
    }
}
