import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// Which folders are packages: the answers that are remembered, forgotten and not asked for.
@Suite
internal struct CoverageLocalPackages {
    /// A folder on a volume that is not a disk of this Mac is never a package.
    @Test
    internal func aFolderOnAVolumeThatIsNotADiskOfThisMacIsNeverAPackage() {
        // Automounted home folders: a share, as far as the program is concerned.
        #expect(!LocalFileSystem().isPackage(URL(fileURLWithPath: "/System/Volumes/Data/home/afm-coverage.app")))
    }

    /// What is not there is no package and teaches nothing.
    @Test
    internal func whatIsNotThereIsNoPackageAndTeachesNothing() throws {
        let box = try Sandbox()
        let local = LocalFileSystem()
        #expect(!local.isPackage(box.url("missing.afmcoverage")))
        #expect(local.packageExtensions["afmcoverage"] == nil)
        // Once the extension is known not to make packages, a folder that is not there is asked about too.
        try box.folder("plain.afmcoverage")
        #expect(!local.isPackage(box.url("plain.afmcoverage")))
        #expect(local.packageExtensions["afmcoverage"]?.isPackage == false)
        #expect(!local.isPackage(box.url("missing.afmcoverage")))
    }

    /// An answer that is old is asked for again.
    @Test
    internal func anAnswerThatIsOldIsAskedForAgain() throws {
        let box = try Sandbox()
        try box.folder("Tool.app")
        let local = LocalFileSystem()
        let minuteAndMore: UInt64 = 61_000_000_000
        local.packageExtensions["app"] = (false, DispatchTime.now().uptimeNanoseconds &- minuteAndMore)
        #expect(local.isPackage(box.url("Tool.app")))
        #expect(local.packageExtensions["app"]?.isPackage == true)
    }

    /// Too many remembered extensions are forgotten together.
    @Test
    internal func tooManyRememberedExtensionsAreForgottenTogether() throws {
        let box = try Sandbox()
        try box.folder("plain.afmfull")
        let local = LocalFileSystem()
        let now = DispatchTime.now().uptimeNanoseconds
        for index in 0...4_096 { local.packageExtensions["x\(index)"] = (false, now) }
        #expect(!local.isPackage(box.url("plain.afmfull")))
        #expect(local.packageExtensions.count == 1 && local.packageExtensions["afmfull"]?.isPackage == false)
    }
}
