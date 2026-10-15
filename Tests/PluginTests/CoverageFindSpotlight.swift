import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Spotlight's side of Find Files at its edges: questions it cannot read, a question started
/// twice, and the check of its answer.
@MainActor
@Suite
internal struct CoverageFindSpotlight {
    /// A search without text needs no check of it.
    @Test
    internal func aSearchWithoutTextNeedsNoCheckOfIt() {
        #expect(!SpotlightQuery.recheckingText(of: SearchQuery(directory: URL(fileURLWithPath: "/"))))
    }

    /// Started a second time, the question is answered at once with what there is; the answer
    /// of the first start then finds nobody waiting.
    @Test
    internal func aQuestionStartedTwiceAnswersOnce() async {
        let search = SpotlightSearch(
            "kMDItemFSName == \"Calculator.app\"",
            scopes: [URL(fileURLWithPath: "/System/Applications")]
        )
        var answers = 0
        search.start { _, _ in answers += 1 }
        search.start { _, _ in answers += 1 }
        #expect(await RunLoopWait.until { answers >= 1 })
        search.stop()
        #expect(answers == 1)
    }

    /// The answer is checked below the top of the disk.
    @Test
    internal func theAnswerIsCheckedBelowTheTopOfTheDisk() {
        let registry = FileSystemRegistry()
        registry.register(LocalFileSystem())
        let query = SearchQuery(directory: URL(fileURLWithPath: "/"), names: "Calculator.app")
        let search = FileSearch(query, fileSystems: registry)
        let found = SpotlightQuery.verify(["/System/Applications/Calculator.app"], with: search, fileSystems: registry)
        #expect(found.map(\.name) == ["Calculator.app"])
        search.cancel()
        #expect(
            SpotlightQuery.verify(["/System/Applications/Calculator.app"], with: search, fileSystems: registry).isEmpty
        )
    }
}
