import AFMKernel
import Darwin
import Foundation
import StressKit

/// Another "program" that creates, deletes and renames files in a folder as fast as asked.
internal struct Flooder {
    /// The folder it changes.
    internal let folder: URL
    /// Chooses each change.
    internal var random = Random(seed: 8)
    /// The files it made that are still there.
    internal var live: [String] = []
    /// Numbers the names it makes.
    internal var serial = 0

    /// A thread that, until `stop` is set, makes `rate` changes a second in `folder`, a batch every
    /// 10 ms, and counts them in `counter`.
    internal static func thread(in folder: URL, rate: Int, stop: CancellationFlag, counter: Counter) -> Thread {
        Thread {
            var flooder = Self(folder: folder)
            let perBatch = max(1, rate / 100)
            let started = now()
            var batch = 0
            while !stop.isCancelled {
                for _ in 0..<perBatch {
                    flooder.change()
                }
                counter.add(perBatch)
                batch += 1
                // Keeps the pace: one batch per 10 ms.
                let ahead = started + Double(batch) * 0.01 - now()
                if ahead > 0 {
                    usleep(useconds_t(ahead * 1e6))
                }
            }
        }
    }

    /// One change: a new file (always while fewer than 200 live), a deletion or a rename.
    internal mutating func change() {
        let kind = Int.random(in: 0..<3, using: &random)
        if kind == 0 || live.count < 200 {
            serial += 1
            let name = folder.appendingPathComponent("flood-\(serial).tmp").path
            close(open(name, O_CREAT | O_WRONLY, 0o644))
            live.append(name)
        } else if kind == 1 {
            unlink(live.remove(at: Int.random(in: 0..<live.count, using: &random)))
        } else {
            let index = Int.random(in: 0..<live.count, using: &random)
            serial += 1
            let name = folder.appendingPathComponent("flood-\(serial)-renamed.tmp").path
            rename(live[index], name)
            live[index] = name
        }
    }
}
