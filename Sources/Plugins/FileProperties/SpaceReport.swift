import AFMContracts
import AFMKernel

/// The wording of the result box of Calculate Occupied Space.
internal enum SpaceReport {
    /// The lines of the box: the sums, the space on both volumes where it is known, the free space of
    /// the source volume, and notes on unreadable folders and on a calculation that was stopped.
    internal static func text(
        _ totals: SpaceTotals,
        sourceIsLocal: Bool,
        targetCluster: Int64?,
        volume: VolumeInfo?,
        cancelled: Bool
    ) -> String {
        var lines = ["\(Format.bytes(totals.bytes)) bytes in \(Format.bytes(Int64(totals.files))) file(s)"]
        if totals.folders > 0 { lines[0] += ",\nin \(Format.bytes(Int64(totals.folders))) directories" }
        if totals.bytes >= 1_024 {
            lines.append("(= \(Format.kilobytes(totals.bytes)), \(Format.shortSize(totals.bytes)))")
        }
        if sourceIsLocal || targetCluster != nil { lines.append("") }
        if sourceIsLocal { lines.append("Actual space used on source volume: \(Format.bytes(totals.allocated)) bytes") }
        if targetCluster != nil { lines.append("Required on target volume: \(Format.bytes(totals.rounded)) bytes") }
        if let volume, let free = volume.freeBytes, let total = volume.totalBytes {
            lines += ["", "\(volume.name): \(Format.kilobytes(free)) of \(Format.kilobytes(total)) free"]
        }
        if totals.unreadable > 0 {
            lines += ["", "\(totals.unreadable) folder(s) could not be read and are not counted."]
        }
        if cancelled { lines += ["", "The calculation was stopped; the figures are incomplete."] }
        return lines.joined(separator: "\n")
    }
}
