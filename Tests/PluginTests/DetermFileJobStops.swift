import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FileOperationsPlugin

/// A delete that the workers share, ended by the question the job asks itself.
@Suite
internal struct DetermFileJobStops {
    private let box: Sandbox
    private let fileSystems = FileSystemRegistry()

    /// A sandbox and a registry with the disk.
    internal init() throws {
        box = try Sandbox()
        fileSystems.register(LocalFileSystem())
    }

    /// Cancel at the question about a protected file, while the workers delete the others: the job ends cancelled,
    /// the protected file stays, and nothing else is asked.
    @Test
    internal func aCancelAtTheQuestionWhileWorkersDeleteEndsTheJob() throws {
        for number in 0..<32 {
            try box.file("d/f\(number).txt", "\(number)")
        }
        let protected = try box.file("d/a-protected.txt", "kept")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: protected.path)
        let answers = CovFileOpsAnswers()
        answers.protections.value = [.cancel]
        let job = FileJob(kind: .delete(toTrash: false), sources: [box.url("d")], fileSystems: fileSystems)
        job.delegate = answers
        let outcome = job.run()
        #expect(outcome.cancelled && box.exists("d/a-protected.txt"))
        let protections = answers.asked.value.filter { $0.hasPrefix("protected") }
        #expect(protections.count == 1 && protections.first?.hasSuffix("a-protected.txt") == true)
    }
}
