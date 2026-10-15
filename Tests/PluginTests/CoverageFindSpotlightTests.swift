import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Spotlight's side of Find Files at its edges: questions it cannot read, a question started
/// twice, and the check of its answer.
@MainActor @Suite struct CoverageFindSpotlight {
    @Test func aSearchWithoutTextNeedsNoCheckOfIt() {
        #expect(!SpotlightQuery.recheckingText(of: SearchQuery(directory: URL(fileURLWithPath: "/"))))
    }

    /// Started a second time, the question is answered at once with what there is; the answer
    /// of the first start then finds nobody waiting.
    @Test func aQuestionStartedTwiceAnswersOnce() async throws {
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

    @Test func theAnswerIsCheckedBelowTheTopOfTheDisk() throws {
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
