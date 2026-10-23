import AFMContracts
import AFMKernel
import Foundation

/// What the System Information dialog shows (spec 12 › System Information), adapted to the
/// Mac: hardware, software and the mounted volumes instead of BIOS, ports and Windows
/// networks.
///
/// A plain value; `gather` asks the system and the volumes and may block, so it runs on a job's
/// thread.
internal struct SystemInformation: Equatable {
    /// A titled part of the dialog: Hardware, Software, Volumes.
    internal struct Section: Equatable {
        /// The heading of the part.
        internal let title: String
        /// The values of the part, in the order they are shown.
        internal var rows: [Row]
    }

    /// One value of the dialog with its label.
    internal struct Row: Equatable {
        /// What the value is: `Model`, `Installed RAM`, a volume's name.
        internal let label: String
        /// The value as shown.
        internal let value: String
    }

    /// What a volume tells about itself; nil where it does not say.
    private struct VolumeValues: Sendable {
        let name: String?
        let format: String?
        let available: Int?
        let total: Int?
    }

    /// What `gather` asks the system: its named values and its volumes.
    ///
    /// Tests answer in its place.
    internal struct Questions: Sendable {
        /// The system's own.
        internal static let system = Self(
            text: SystemInformation.systemText,
            number: SystemInformation.systemNumber
        ) {
            Array(
                [
                    FileManager.default.mountedVolumeURLs(
                        includingResourceValuesForKeys: nil,
                        options: [.skipHiddenVolumes]
                    )
                ]
                .compactMap(\.self)
                .joined()
            )
        }

        /// A named value as text.
        internal var text: @Sendable (String) -> String?
        /// A named value as a number.
        internal var number: @Sendable (String) -> Int?
        /// The volumes to list; none when the system does not tell.
        internal var volumes: @Sendable () -> [URL]
    }

    /// Stands for the volumes in `BlockingCalls`.
    private static let volumeCalls = CallOwner()

    /// The parts of the dialog, in the order they are shown.
    internal var sections: [Section]

    /// The sections as lines of text with the values in one column.
    internal var text: String {
        let width = sections.flatMap(\.rows).map(\.label.count).max() ?? 0
        return
            sections.map { section in
                ([section.title]
                    + section.rows.map { row in
                        "  " + (row.label + ":").padding(toLength: width + 2, withPad: " ", startingAt: 0) + row.value
                    })
                    .joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    // MARK: Formats

    /// Memory as the dialog writes it: `131,072 M (128 G)`.
    internal static func memory(_ bytes: UInt64) -> String {
        let megabytes = Int64(bytes / (1_024 * 1_024))
        let gigabytes = Double(bytes) / Double(1 << 30)
        let rounded = gigabytes.rounded() == gigabytes ? String(Int(gigabytes)) : String(format: "%.1f", gigabytes)
        return megabytes >= 1_024 ? "\(Format.bytes(megabytes)) M (\(rounded) G)" : "\(Format.bytes(megabytes)) M"
    }

    /// Time since start: `130h 19m 21s`.
    internal static func uptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return "\(total / 3_600)h \(total / 60 % 60)m \(total % 60)s"
    }

    /// Free space of a volume as on the drive line: `1,439,946,852 k of 7,811,085,600 k free`.
    internal static func space(free: Int64?, total: Int64?) -> String {
        guard let free, let total else {
            return "size unknown"
        }
        return "\(Format.bytes(free / 1_024)) k of \(Format.bytes(total / 1_024)) k free"
    }

    // MARK: Asking the system

    /// One named value of the system (`sysctl`), as text.
    internal static func systemText(_ name: String) -> String? {
        var size = 0
        // The first call tells the size, the second fills a buffer of that size.
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0,
            case var bytes = [CChar](repeating: 0, count: size), sysctlbyname(name, &bytes, &size, nil, 0) == 0
        else {
            return nil
        }
        return SystemText.string(bytes)
    }

    /// One named value of the system (`sysctl`), as a number.
    internal static func systemNumber(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(value)
    }

    /// Memory nobody uses and the share that is in use: `75,067 M (58 %)`. `pageSize` is the size of a page of
    /// memory, when the system tells it.
    internal static func freeMemory(of total: UInt64, pageSize: Int?) -> String? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integers in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, integers, &count)
            }
        }
        guard result == KERN_SUCCESS, total > 0 else {
            return nil
        }
        let free =
            (UInt64(statistics.free_count) + UInt64(statistics.inactive_count) + UInt64(statistics.speculative_count))
            * UInt64(pageSize ?? 4_096)
        let load = 100 - Int(Double(min(free, total)) / Double(total) * 100)
        return "\(Format.bytes(Int64(free / (1_024 * 1_024)))) M (\(load) %)"
    }

    /// `displays` are the screens as text; they belong to the main thread and are read there
    /// before the job starts.
    ///
    /// Nil when `cancellation` was set before every volume had answered.
    internal static func gather(displays: [String], cancellation: CancellationFlag, asking system: Questions) -> Self? {
        let process = ProcessInfo.processInfo
        var hardware = [Row(label: "Model", value: system.text("hw.model") ?? "unknown")]
        hardware.append(Row(label: "Processor", value: system.text("machdep.cpu.brand_string") ?? "unknown"))
        var cores = "\(process.processorCount)"
        if let performance = system.number("hw.perflevel0.physicalcpu"),
            let efficiency = system.number("hw.perflevel1.physicalcpu")
        {
            cores += " (\(performance) performance, \(efficiency) efficiency)"
        } else if let physical = system.number("hw.physicalcpu"), physical != process.processorCount {
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
                value: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            )
        ]
        if let build = system.text("kern.osversion") {
            software.append(Row(label: "Build", value: build))
        }
        if let kernel = system.text("kern.osrelease") {
            software.append(Row(label: "Kernel", value: "Darwin \(kernel)"))
        }
        if let free = freeMemory(of: process.physicalMemory, pageSize: system.number("hw.pagesize")) {
            software.append(Row(label: "Free memory", value: free))
        }
        software.append(Row(label: "Time since start", value: uptime(process.systemUptime)))
        software.append(Row(label: "Temporary folder", value: NSTemporaryDirectory()))
        software.append(Row(label: "User name", value: NSUserName()))
        if let computer = system.text("kern.hostname") {
            software.append(Row(label: "Computer name", value: computer))
        }

        let mounted = volumes(system.volumes(), cancellation: cancellation)
        guard !cancellation.isCancelled else {
            return nil
        }
        return Self(sections: [
            Section(title: "Hardware", rows: hardware), Section(title: "Software", rows: software),
            Section(title: "Volumes", rows: mounted)
        ])
    }

    /// The mounted volumes with their free space.
    ///
    /// Each volume is asked on its own core, because a network share may take its time to answer.
    ///
    /// A volume that has stopped answering never returns from the question. The question is
    /// therefore asked through `BlockingCalls`: it goes on alone, and this function comes back
    /// as soon as `cancellation` is set, so the job that called it can end.
    internal static func volumes(_ mounted: [URL], cancellation: CancellationFlag) -> [Row] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        return Parallel.map(mounted) { url in
            let answer = BlockingCalls.answer(
                from: volumeCalls,
                to: "space " + url.path,
                cancellation: cancellation
            ) { _ -> VolumeValues? in
                // The values are taken out here: the set of them cannot be handed to another thread.
                (try? url.resourceValues(forKeys: keys))
                    .map { values in
                        VolumeValues(
                            name: values.volumeName,
                            format: values.volumeLocalizedFormatDescription,
                            available: values.volumeAvailableCapacity,
                            total: values.volumeTotalCapacity
                        )
                    }
            }
            guard let values = answer else {
                return Row(label: url.lastPathComponent, value: "\(url.path): not answering")
            }
            let name = values?.name ?? url.lastPathComponent
            let format = values?.format.map { ", \($0)" } ?? ""
            let free = space(
                free: values?.available.map(Int64.init),
                total: values?.total.map(Int64.init)
            )
            return Row(label: name, value: "\(url.path): \(free)\(format)")
        }
    }
}
