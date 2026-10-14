import AFMKernel
import Foundation
import StressKit

@testable import ArchivesPlugin

/// Adding a member at the bottom of the chain, committing, and checking the result three ways.
extension DeepRun {
    /// Adds a member at the bottom, commits, and checks with unzip, Python's zipfile and a fresh reader.
    @MainActor
    internal func addAtBottom() {
        step("deep: add at the bottom + commit + unzip -tq + fresh reader", limit: 600) {
            offMain { [self] in
                addAndCommit()
                checkWithUnzip()
                checkWithPython()
                checkWithFreshReader()
            }
        }
    }

    /// Writes `added.txt` at the bottom of the chain and commits.
    private func addAndCommit() {
        let bottom = bench.inside(archive, bottomPath + "/added.txt")
        do {
            let writer = try bench.zip.write(bottom)
            try writer.write(Data("added at the bottom\n".utf8))
            try writer.close(attributes: FileAttributes())
            let started = now()
            try bench.zip.commit(root, cancellation: CancellationFlag())
            say(String(format: "deep commit: %.3fs", now() - started))
        } catch {
            Findings.shared.violation("deep: adding at the bottom failed", error.localizedDescription)
        }
    }

    /// `unzip -tq` after the commit.
    private func checkWithUnzip() {
        let test = tool("/usr/bin/unzip", ["-tq", archive.path])
        say("deep unzip -tq: status \(test.status) \(trimmed(test.output).suffix(160))")
        // unzip warns "filename too long" for the pristine archive already (status 1): only a real error counts,
        // and Python's zipfile checks every CRC without that limit.
        if test.status > 1 {
            Findings.shared.violation(
                "deep archive invalid after the commit (unzip -tq)",
                String(test.output.suffix(300))
            )
        }
    }

    /// Python's zipfile checks every CRC after the commit.
    private func checkWithPython() {
        let script =
            "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); "
            + "print('testzip', z.testzip(), 'members', len(z.namelist()))"
        let python = tool("/usr/bin/env", ["python3", "-c", script, archive.path])
        say("deep python zipfile: \(trimmed(python.output).suffix(200))")
        if !python.output.contains("testzip None") {
            Findings.shared.violation(
                "deep archive invalid after the commit (python zipfile)",
                String(python.output.suffix(300))
            )
        }
    }

    /// A fresh reader of the program's own reads the added member and counts every member.
    private func checkWithFreshReader() {
        let fresh = Bench(flushDelay: nil)
        let added = fresh.readAll(fresh.inside(archive, bottomPath + "/added.txt"))
        if added.data != Data("added at the bottom\n".utf8) {
            Findings.shared.violation("deep: committed member reads back wrong (fresh reader)", "")
        }
        let count = (try? fresh.store.archive(at: archive).entries.filter { !$0.isDirectory }.count) ?? -1
        if count != 8_194 {
            Findings.shared.violation("deep: fresh reader counts wrong", "\(count) instead of 8194")
        }
        fresh.store.close()
    }
}
