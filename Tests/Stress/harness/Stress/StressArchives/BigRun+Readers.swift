import AFMKernel
import Foundation
import StressKit

/// The reader threads of the concurrent stage.
extension BigRun {
    /// Reads members (mostly the probes) until `stop`, with random cancels, seeks and block sizes.
    internal func readerLoop(_ reader: Int, members: Members, stop: CancellationFlag, cancelQueue: DispatchQueue) {
        var random = Random(seed: options.seed &* 1_000 &+ UInt64(reader))
        while !stop.isCancelled {
            let probe = members.pick(probeCount: probes.count, using: &random)
            let started = now()
            readOnce(probe, cancelQueue: cancelQueue, random: &random)
            Counter.shared.time(
                probe.data.count > (8 << 20)
                    ? "read of a 24 MB member (incl. cancelled)"
                    : "read of a small/medium member (incl. cancelled)",
                now() - started
            )
        }
    }

    /// One reading of `probe`, checked against the reference.
    private func readOnce(_ probe: Probe, cancelQueue: DispatchQueue, random: inout Random) {
        let url = bench.inside(archive, probe.path)
        let flag = CancellationFlag()
        let cancels = Int.random(in: 0..<10, using: &random) < 3
        let seeks = Int.random(in: 0..<10, using: &random) < 2 && probe.data.count > 2
        let blockSize = [4 << 10, 64 << 10, 1 << 20][Int.random(in: 0..<3, using: &random)]
        var offset = 0
        let cancelledAt = Locked(0.0)
        do {
            let reader = try bench.zip.read(url, cancellation: flag)
            defer { reader.close() }
            let tie = flag.interrupting(reader)
            defer {
                withExtendedLifetime(tie) {
                    // Keeps the interruption until the reading is over.
                }
            }
            if cancels {
                let delay = Int.random(in: 0...(probe.data.count > (1 << 20) ? 30_000 : 1_500), using: &random)
                cancelQueue.asyncAfter(deadline: .now() + .microseconds(delay)) {
                    cancelledAt.value = now()
                    flag.cancel()
                }
            }
            if seeks {
                offset = Int.random(in: 0..<probe.data.count, using: &random)
                try reader.seek(to: UInt64(offset))
            }
            var comparison = Comparison(offset: offset)
            while let block = try reader.read(upToCount: blockSize) {
                if block.isEmpty {
                    Findings.shared.violation("reader returned an empty block instead of nil", probe.path)
                    break
                }
                guard comparison.take(block, reference: probe.data) else {
                    break
                }
            }
            verify(comparison, of: probe, cancelled: flag.isCancelled)
        } catch {
            readFailed(probe, offset: offset, error: error, cancelled: flag.isCancelled, at: cancelledAt.value)
        }
    }

    /// A reading that ended without an error: the bytes must be right, cancelled or not.
    private func verify(_ comparison: Comparison, of probe: Probe, cancelled: Bool) {
        let offset = comparison.offset
        if !comparison.matches || offset + comparison.got != probe.data.count {
            Findings.shared.violation(
                "WRONG BYTES read from a member",
                "\(probe.path) offset \(offset): got \(comparison.got) bytes, expected \(probe.data.count - offset), "
                    + "content matches=\(comparison.matches); cancelled=\(cancelled)"
            )
        } else if offset == 0, UInt32(truncatingIfNeeded: comparison.crc) != probe.crc {
            Findings.shared.violation("CRC mismatch", probe.path)
        }
        Counter.shared.add(cancelled ? "reads completed although cancelled" : "reads completed and verified")
        Counter.shared.add("bytes read and verified", comparison.got)
    }

    /// A reading that ended with an error: only a cancel may cause that.
    private func readFailed(_ probe: Probe, offset: Int, error: any Error, cancelled: Bool, at cancelledAt: Double) {
        if cancelled {
            Counter.shared.add("reads ended by cancel")
            if cancelledAt > 0 {
                Counter.shared.time("cancel -> read ended", now() - cancelledAt)
            }
        } else {
            Findings.shared.violation(
                "read failed without a cancel",
                "\(probe.path) offset \(offset): \(error.localizedDescription)"
            )
        }
    }
}
