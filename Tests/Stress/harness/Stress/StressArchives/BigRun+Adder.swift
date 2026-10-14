import AFMKernel
import Foundation
import StressKit

/// The adder thread of the concurrent stage: adds a batch of members, commits, checks the archive.
extension BigRun {
    /// The bytes of a new member: half of them random, half compressible.
    private static func contents(size: Int, batch: Int, file: Int) -> Data {
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            var state = UInt64(batch) &* 1_000_003 &+ UInt64(file)
            for position in 0..<size {
                let even = position.isMultiple(of: 2)
                if even {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                }
                buffer[position] = even ? UInt8(truncatingIfNeeded: state >> 33) : UInt8(65 + position % 7)
            }
        }
        return data
    }

    /// Adds and commits batches until `stop`; every committed batch becomes readable for the readers.
    internal func adderLoop(members: Members, stop: CancellationFlag, stageStart: Double) {
        var random = Random(seed: options.seed &* 4_242)
        var batch = 0
        while !stop.isCancelled {
            batch += 1
            var added: [Probe] = []
            let count = Int.random(in: 1...20, using: &random)
            for file in 0..<count {
                if let probe = addMember(batch: batch, file: file, random: &random) {
                    added.append(probe)
                }
            }
            guard commit(batch: batch, added: added, stageStart: stageStart) else {
                continue
            }
            let expectedFiles = members.commit(added.count)
            checkWithUnzip(batch: batch)
            checkWithZipinfo(batch: batch, added: added)
            checkWithFreshReader(batch: batch, added: added, expectedFiles: expectedFiles, random: &random)
            members.append(added)
        }
    }

    /// Writes member `file` of `batch` (mostly up to 200 KB, one in twenty 2 to 6 MB); nil when that failed.
    private func addMember(batch: Int, file: Int, random: inout Random) -> Probe? {
        let size =
            Int.random(in: 0..<20, using: &random) == 0
            ? Int.random(in: (2 << 20)...(6 << 20), using: &random)
            : Int.random(in: 0...(200 << 10), using: &random)
        let data = Self.contents(size: size, batch: batch, file: file)
        let path = String(format: "added/batch%04d/new%03d.bin", batch, file)
        do {
            let writer = try bench.zip.write(bench.inside(archive, path), cancellation: CancellationFlag())
            var position = 0
            while position < size {
                let end = min(size, position + (256 << 10))
                try writer.write(data.subdata(in: position..<end))
                position = end
            }
            try writer.close(
                attributes: FileAttributes(modified: Date(timeIntervalSince1970: 1_700_000_000), permissions: 0o644)
            )
            return Probe(path: path, data: data, crc: checksum(data))
        } catch {
            Findings.shared.violation("adding a member failed", "\(path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Commits the archive and counts what was added; false when the commit failed.
    private func commit(batch: Int, added: [Probe], stageStart: Double) -> Bool {
        let started = now()
        do {
            try bench.zip.commit(root, cancellation: CancellationFlag())
        } catch {
            Findings.shared.violation("commit failed", "batch \(batch): \(error.localizedDescription)")
            return false
        }
        let counter = Counter.shared
        counter.time("commit (\(options.expectedEntries / 1_000)k-member archive)", now() - started)
        counter.add("commits")
        if counter.get("commits").isMultiple(of: 5) {
            let format =
                "MEM after commit %d: footprint=%.0f MB (harness holds %.0f MB of added reference data) t=%.1fs"
            say(
                String(
                    format: format,
                    counter.get("commits"),
                    footprintMB(),
                    Double(counter.get("reference bytes held")) / 1_048_576,
                    now() - stageStart
                )
            )
        }
        counter.add("reference bytes held", added.reduce(0) { $0 + $1.data.count })
        counter.add("members added", added.count)
        return true
    }
}
