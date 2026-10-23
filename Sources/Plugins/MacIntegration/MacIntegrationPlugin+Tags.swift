import AFMKernel
import Foundation

/// Finder tags: reading, writing and editing them.
extension MacIntegrationPlugin {
    /// The Finder tags of a file.
    ///
    /// Reads the disk: not for the main thread. A new URL each time, so no value read earlier is
    /// given again.
    nonisolated internal static func tags(of url: URL) -> [String] {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey])
        return values?.tagNames ?? []
    }

    /// Replaces the Finder tags of a file.
    ///
    /// Writes to the disk: not for the main thread. Throws what the file system answers, for
    /// example when the file has gone. (`URLResourceValues` can only read tags.)
    nonisolated internal static func setTags(_ tags: [String], of url: URL) throws {
        var failure: Unmanaged<CFError>?
        if !CFURLSetResourcePropertyForKey(url as CFURL, kCFURLTagNamesKey, tags as CFArray, &failure), let failure {
            throw failure.takeRetainedValue()
        }
    }

    /// The tags as the user types them: separated by commas, no empty ones, none twice.
    internal static func tags(from text: String) -> [String] {
        var tags: [String] = []
        for tag in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
        where !tag.isEmpty && !tags.contains(tag) {
            tags.append(tag)
        }
        return tags
    }

    /// Shows the tags of the first file and gives all files what the user makes of them.
    ///
    /// The disk is read and written as jobs, off the main thread.
    internal func editTags(of urls: [URL], in kernel: Kernel) {
        guard let first = urls.first else {
            return
        }
        kernel.jobs.run(
            title: "Reading tags",
            work: { _ in Self.tags(of: first) },
            completion: { [self] current in
                let subject =
                    urls.count == 1 ? "“\(DisplayText.oneLine(first.lastPathComponent))”" : "\(urls.count) items"
                guard
                    let text = kernel.interaction.prompt(
                        "Finder tags of \(subject):",
                        value: current.joined(separator: ", "),
                        detail: "Separate tags with commas. An empty line removes all tags."
                    )
                else { return }
                setTags(Self.tags(from: text), of: urls, in: kernel)
            }
        )
    }

    /// Gives every file of `urls` these tags, in a job; the first failure stops it and is said.
    private func setTags(_ tags: [String], of urls: [URL], in kernel: Kernel) {
        kernel.jobs.run(
            title: "Setting tags",
            work: { monitor -> (error: (any Error)?, folders: [URL]) in
                var failure: (any Error)?
                for url in urls where !monitor.cancellation.isCancelled {
                    do {
                        try Self.setTags(tags, of: url)
                    } catch {
                        failure = error
                        break
                    }
                }
                // The folders to show again are worked out here, not on the main thread.
                return (failure, Array(Set(urls.map { $0.deletingLastPathComponent() })))
            },
            completion: { [self] result in
                if let error = result.error {
                    kernel.interaction.report(error, title: "The tags could not be set")
                }
                remember("tags " + Self.described(urls) + ": " + tags.joined(separator: ", "))
                kernel.panels.refresh(result.folders)
            }
        )
    }
}
