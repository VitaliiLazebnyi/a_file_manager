import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// The free space when the system gives no figures but the plain one of the volume, and measurements that were lost.
@Suite
internal struct CoverageLocalFreeSpace {
    /// Without figures the volume's own count is the free space.
    @Test
    internal func withoutFiguresTheVolumesOwnCountIsTheFreeSpace() throws {
        let box = try Sandbox()
        var probes = LocalProbes()
        probes.freeSpace = { _ in (nil, nil) }
        var info = statfs()
        statfs(box.root.path, &info)
        let free = LocalFileSystem(probes: probes).volume(of: box.root)?.freeBytes
        // What the volume says now; it may have changed a little since.
        #expect(free.map { abs($0 - Int64(info.f_bavail) * Int64(info.f_bsize)) < 1 << 30 } == true)
    }

    /// A measurement that was lost is taken again.
    @Test
    internal func aMeasurementThatWasLostIsTakenAgain() throws {
        let box = try Sandbox()
        let (mount, volume) = CoverageLocalProbes.mount(of: box.root)
        let lost = DispatchTime.now().uptimeNanoseconds &- 31_000_000_000
        for local in [
            LocalFileSystem(),
            {
                var probes = LocalProbes()
                probes.freeSpace = { _ in (100, 300) }
                return LocalFileSystem(probes: probes)
            }()
        ] {
            local.spareLock.withLock { local.spareSpace[mount] = (0, lost, true, volume) }
            #expect(local.volume(of: box.root) != nil)
            #expect(
                Wait.until(seconds: 60) {
                    local.spareLock.withLock {
                        local.spareSpace[mount].map { !$0.isMeasuring && $0.measured != lost } ?? true
                    }
                }
            )
        }
    }
}
