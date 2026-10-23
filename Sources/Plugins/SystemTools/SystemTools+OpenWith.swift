import AFMKernel
import Foundation

/// Open With (TC's "Associate With").
extension SystemTools {
    /// "Associate With" as the Mac has it: the applications able to open the item under the
    /// cursor, the usual one first.
    ///
    /// Choosing a lasting association is left to Finder.
    internal func openWith(_ item: FileItem) {
        let shownName = DisplayText.oneLine(item.name, limit: 200)
        let applicationsToOpen = desktop.applicationsToOpen
        kernel.jobs.run(
            title: "Applications:",
            // Nil: cancelled while the volume did not answer.
            work: { monitor in
                // Launch Services looks at the file to know its type: on a volume that does not answer, that waits.
                Self.ask("applications", of: item.url, monitor) { () -> [(name: String, url: URL)] in
                    let found = applicationsToOpen(item.url)
                    let usual = found.usual
                    var applications = found.all
                    if let usual {
                        applications.removeAll { $0 == usual }
                        applications.insert(usual, at: 0)
                    }
                    return applications.map { url in
                        let name = FileManager.default.displayName(atPath: url.path)
                        return (url == usual ? name + " (default)" : name, url)
                    }
                }
            },
            completion: { [self] found in
                guard let applications = found else {
                    return
                }
                guard !applications.isEmpty else {
                    return interaction.inform("No application is known to open \(shownName).")
                }
                guard
                    let row = interaction.pickRow(
                        "Open \(shownName) with:",
                        rows: applications.map(\.name),
                        button: "Open"
                    )
                else { return }
                let application = applications[row].url
                note("open-with: \(application.lastPathComponent) \(shownName)")
                desktop.open([item.url], application)
            }
        )
    }
}
