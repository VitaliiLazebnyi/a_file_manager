import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import SystemToolsPlugin

/// The system information from answers of the test's own: values the system does not tell, the kinds of cores,
/// several displays, volumes that cannot be read.
@Suite
internal struct CovSysToolsInformation {
    /// What the system does not tell is unknown or left out; the kinds of cores are counted.
    @Test
    internal func whatTheSystemDoesNotTellIsUnknownOrLeftOut() {
        let numbers = ["hw.perflevel0.physicalcpu": 4, "hw.perflevel1.physicalcpu": 2]
        let questions = SystemInformation.Questions(text: { _ in nil }, number: { numbers[$0] }, volumes: { [] })
        let information = SystemInformation.gather(
            displays: ["1x1", "2x2"],
            cancellation: CancellationFlag(),
            asking: questions
        )
        let hardware = rows(of: information, "Hardware")
        #expect(hardware.first { $0.label == "Model" }?.value == "unknown")
        #expect(hardware.first { $0.label == "Processor" }?.value == "unknown")
        #expect(hardware.first { $0.label == "CPU cores" }?.value.hasSuffix(" (4 performance, 2 efficiency)") == true)
        #expect(hardware.map(\.label).suffix(2) == ["Display 1", "Display 2"])
        let software = rows(of: information, "Software").map(\.label)
        #expect(!software.contains("Build") && !software.contains("Kernel") && !software.contains("Computer name"))
        #expect(software.contains("Free memory") && rows(of: information, "Volumes").isEmpty)
    }

    /// Physical cores are named when they differ from the logical ones.
    @Test
    internal func physicalCoresAreNamedWhenTheyDiffer() {
        let physical = ProcessInfo.processInfo.processorCount + 1
        let questions = SystemInformation.Questions(
            text: { _ in nil },
            number: { $0 == "hw.physicalcpu" ? physical : nil },
            volumes: { [] }
        )
        let information = SystemInformation.gather(displays: [], cancellation: CancellationFlag(), asking: questions)
        let cores = rows(of: information, "Hardware").first { $0.label == "CPU cores" }?.value
        #expect(cores?.hasSuffix(" (\(physical) physical)") == true)
    }

    /// A volume that cannot be read is listed by its name in the path, of unknown size.
    @Test
    internal func aVolumeThatCannotBeReadIsOfUnknownSize() {
        let gone = URL(fileURLWithPath: "/Volumes/afm-no-such-volume")
        let rows = SystemInformation.volumes([gone], cancellation: CancellationFlag())
        #expect(rows == [SystemInformation.Row(label: "afm-no-such-volume", value: "\(gone.path): size unknown")])
    }

    /// Free memory needs the total; without a page size the usual one is taken.
    @Test
    internal func freeMemoryNeedsTheTotal() {
        #expect(SystemInformation.freeMemory(of: 0, pageSize: nil) == nil)
        #expect(SystemInformation.freeMemory(of: 1 << 40, pageSize: nil)?.hasSuffix(" %)") == true)
        #expect(SystemInformation(sections: []).text.isEmpty)
    }

    /// The rows of the section `title`.
    private func rows(of information: SystemInformation?, _ title: String) -> [SystemInformation.Row] {
        information?.sections.first { $0.title == title }?.rows ?? []
    }
}
