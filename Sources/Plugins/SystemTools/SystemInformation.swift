import AFMContracts
import AFMKernel
import Foundation

/// What the System Information dialog shows (spec 12 › System Information), adapted to the
/// Mac: hardware, software and the mounted volumes instead of BIOS, ports and Windows
/// networks. A plain value; `gather` asks the system and the volumes and may block, so it runs
/// on a job's thread.
struct SystemInformation: Equatable {
    struct Section: Equatable {
        let title: String
        var rows: [Row]
    }

    struct Row: Equatable {
        let label: String
        let value: String
    }

    var sections: [Section]

    /// The sections as lines of text with the values in one column.
    var text: String {
        let width = sections.flatMap(\.rows).map(\.label.count).max() ?? 0
        return sections.map { section in
            ([section.title]
                + section.rows.map {
                    "  " + ($0.label + ":").padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.value
                })
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Formats

    /// Memory as the dialog writes it: `131,072 M (128 G)`.
    static func memory(_ bytes: UInt64) -> String {
        let megabytes = Int64(bytes / (1_024 * 1_024))
        let gigabytes = Double(bytes) / Double(1 << 30)
        let rounded = gigabytes.rounded() == gigabytes ? String(Int(gigabytes)) : String(format: "%.1f", gigabytes)
        return megabytes >= 1_024 ? "\(Format.bytes(megabytes)) M (\(rounded) G)" : "\(Format.bytes(megabytes)) M"
    }

    /// Time since start: `130h 19m 21s`.
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return "\(total / 3_600)h \(total / 60 % 60)m \(total % 60)s"
    }

    /// Free space of a volume as on the drive line: `1,439,946,852 k of 7,811,085,600 k free`.
    static func space(free: Int64?, total: Int64?) -> String {
        guard let free, let total else { return "size unknown" }
        return "\(Format.bytes(free / 1_024)) k of \(Format.bytes(total / 1_024)) k free"
    }

    // MARK: Asking the system

    /// One named value of the system (`sysctl`), as text or as a number.
    static func systemText(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func systemNumber(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// Memory nobody uses and the share that is in use: `75,067 M (58 %)`.
    private static func freeMemory(of total: UInt64) -> String? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, total > 0 else { return nil }
        let pageSize = UInt64(systemNumber("hw.pagesize") ?? 4_096)
        let free =
            (UInt64(statistics.free_count) + UInt64(statistics.inactive_count) + UInt64(statistics.speculative_count))
            * pageSize
        let load = 100 - Int(Double(min(free, total)) / Double(total) * 100)
        return "\(Format.bytes(Int64(free / (1_024 * 1_024)))) M (\(load) %)"
    }

    /// `displays` are the screens as text; they belong to the main thread and are read there
    /// before the job starts.
    static func gather(displays: [String] = []) -> Self {
        // Without a flag nothing can cancel, so there is always an answer.
        gather(displays: displays, cancellation: CancellationFlag()) ?? Self(sections: [])
    }

    /// Nil when `cancellation` was set before every volume had answered.
    static func gather(displays: [String], cancellation: CancellationFlag) -> Self? {
        let process = ProcessInfo.processInfo
        var hardware = [Row(label: "Model", value: systemText("hw.model") ?? "unknown")]
        hardware.append(Row(label: "Processor", value: systemText("machdep.cpu.brand_string") ?? "unknown"))
        var cores = "\(process.processorCount)"
        if let performance = systemNumber("hw.perflevel0.physicalcpu"),
            let efficiency = systemNumber("hw.perflevel1.physicalcpu")
        {
            cores += " (\(performance) performance, \(efficiency) efficiency)"
        } else if let physical = systemNumber("hw.physicalcpu"), physical != process.processorCount {
            cores += " (\(physical) physical)"
        }
        hardware.append(Row(label: "CPU cores", value: cores))
        hardware.append(Row(label: "Installed RAM", value: memory(process.physicalMemory)))
        for (index, display) in displays.enumerated() {
            hardware.append(Row(label: displays.count > 1 ? "Display \(index + 1)" : "Display", value: display))
        }

        let version = process.operatingSystemVersion
        var software = [
            Row(
                label: "macOS version",
                value: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        ]
        if let build = systemText("kern.osversion") { software.append(Row(label: "Build", value: build)) }
        if let kernel = systemText("kern.osrelease") {
            software.append(Row(label: "Kernel", value: "Darwin \(kernel)"))
        }
        if let free = freeMemory(of: process.physicalMemory) {
            software.append(Row(label: "Free memory", value: free))
        }
        software.append(Row(label: "Time since start", value: uptime(process.systemUptime)))
        software.append(Row(label: "Temporary folder", value: NSTemporaryDirectory()))
        software.append(Row(label: "User name", value: NSUserName()))
        if let computer = systemText("kern.hostname") { software.append(Row(label: "Computer name", value: computer)) }

        let mounted = volumes(cancellation: cancellation)
        guard !cancellation.isCancelled else { return nil }
        return Self(sections: [
            Section(title: "Hardware", rows: hardware), Section(title: "Software", rows: software),
            Section(title: "Volumes", rows: mounted)
        ])
    }

    /// Stands for the volumes in `BlockingCalls`.
    private static let volumeCalls = CallOwner()

    /// The mounted volumes with their free space. Each volume is asked on its own core,
    /// because a network share may take its time to answer.
    ///
    /// A volume that has stopped answering never returns from the question. The question is
    /// therefore asked through `BlockingCalls`: it goes on alone, and this function comes back
    /// as soon as `cancellation` is set, so the job that called it can end.
    static func volumes(cancellation: CancellationFlag = CancellationFlag()) -> [Row] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        let urls =
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])
            ?? []
        return Parallel.map(urls) { url in
            let answer = BlockingCalls.answer(from: volumeCalls, to: "space " + url.path, cancellation: cancellation) {
                _ -> (
                    volumeName: String?, volumeLocalizedFormatDescription: String?, volumeAvailableCapacity: Int?,
                    volumeTotalCapacity: Int?
                )? in
                // The values are taken out here: the set of them cannot be handed to another thread.
                (try? url.resourceValues(forKeys: keys)).map {
                    (
                        $0.volumeName, $0.volumeLocalizedFormatDescription, $0.volumeAvailableCapacity,
                        $0.volumeTotalCapacity
                    )
                }
            }
            guard let values = answer else {
                return Row(label: url.lastPathComponent, value: "\(url.path): not answering")
            }
            let name = values?.volumeName ?? url.lastPathComponent
            let format = values?.volumeLocalizedFormatDescription.map { ", \($0)" } ?? ""
            let free = space(
                free: values?.volumeAvailableCapacity.map(Int64.init),
                total: values?.volumeTotalCapacity.map(Int64.init))
            return Row(label: name, value: "\(url.path): \(free)\(format)")
        }
    }
}

/// The rules for a volume's name (spec 12 › Volume label, adapted: the Mac allows long names
/// and most characters, but neither `/` nor `:` nor a leading dot).
enum VolumeName {
    static let maximumLength = 255

    /// Nil when the name is fine, else what is wrong with it.
    static func problem(with name: String) -> String? {
        if name.isEmpty { return "The name must not be empty." }
        if name.utf8.count > maximumLength { return "The name is too long." }
        if name.contains("/") || name.contains(":") { return "The name must not contain / or :." }
        if name.hasPrefix(".") { return "The name must not start with a dot." }
        return nil
    }
}
