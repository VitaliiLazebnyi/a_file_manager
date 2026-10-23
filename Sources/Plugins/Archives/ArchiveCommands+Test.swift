import AFMKernel
import Foundation

/// Test Archive(s) (spec 08 › Test).
extension ArchiveCommands {
    /// Tests one archive; the problems found, each led by the archive's name.
    ///
    /// Its pending changes are written first. On the job's thread.
    ///
    /// `progress` names the archive and its place among those tested; the bytes are filled in
    /// here as the cores read.
    nonisolated private static func test(
        _ url: URL,
        in store: ArchiveStore,
        monitor: any JobMonitor,
        progress: JobProgress
    ) throws -> [String] {
        try store.flush(url, cancellation: monitor.cancellation)
        let archive = try store.archive(at: url, cancellation: monitor.cancellation)
        let members = archive.entries.filter { !$0.isDirectory }
        let total = members.reduce(Int64(0)) { sum, member in sum.addingSaturated(max(0, member.size)) }
        let counter = SharedCounter()
        // The password is asked for here, on the job's thread, before the cores share the work;
        // one that is declined is not asked for again by the test.
        let found: [String] = try archive.withPasswordScope {
            try ArchiveTester.unlock(archive, members: .all)
            return Background.run(
                { ArchiveTester.test(archive, cancellation: monitor.cancellation, counter: counter, members: .all) },
                tick: {
                    var now = progress
                    (now.bytesDone, now.bytesTotal) = (counter.value, total)
                    monitor.report(now)
                }
            )
        }
        return found.map { "\(url.lastPathComponent): \($0)" }
    }

    /// Tests the marked archives, or the archive the panel is in, in a job, and says what it found.
    internal func test() {
        refreshOptions()
        let model = source.model
        var archives = model.operands().filter { !$0.isDirectory }.map(\.url)
        // Inside an archive the archive itself is tested.
        if let inside = ArchiveURL.location(of: model.directory) { archives = [inside.archive] }
        guard !archives.isEmpty else {
            interaction.inform("No files selected!", detail: "", style: .warning)
            return
        }
        kernel.jobs.run(
            title: "Testing:",
            work: { [fileSystems, store, archives] monitor -> (problems: [String], tested: Int) in
                var problems: [String] = []
                var tested = 0
                for (index, url) in archives.enumerated() where !monitor.cancellation.isCancelled {
                    do {
                        let progress = JobProgress(
                            lines: ["Testing: \(fileSystems.displayPath(url))"],
                            itemsDone: index,
                            itemsTotal: archives.count,
                            bytesDone: 0,
                            bytesTotal: 0
                        )
                        problems += try Self.test(url, in: store, monitor: monitor, progress: progress)
                        tested += 1
                    } catch {
                        problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                return (problems, tested)
            },
            completion: { [interaction] result in
                if result.problems.isEmpty {
                    interaction.inform(
                        "Archive test",
                        detail: "No errors found in \(result.tested) archive(s).",
                        style: .information
                    )
                } else {
                    interaction.inform(
                        "Errors found in archive!",
                        detail: Self.summary(of: result.problems),
                        style: .critical
                    )
                }
            }
        )
    }
}
