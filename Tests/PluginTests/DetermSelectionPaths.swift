import AFMKernel
import Foundation
import Testing

@testable import SelectionPlugin

/// Masks with folders over a list gathered from elsewhere (a search result): the entries that are
/// not under the list's folder.
@Suite
internal struct DetermSelectionPaths {
    private func item(_ path: String, name: String) -> FileItem {
        FileItem(url: URL(string: "mem://" + path) ?? URL(fileURLWithPath: "/"), name: name)
    }

    /// An entry from outside the list's folder keeps its whole path for the folders of a mask.
    @Test
    internal func anEntryFromOutsideTheListsFolderKeepsItsWholePath() {
        let base = URL(string: "mem:///work") ?? URL(fileURLWithPath: "/")
        let items = [item("/work/a.txt", name: "a.txt"), item("/other/deep/b.txt", name: "other/deep/b.txt")]
        #expect(SelectionRule(mask: "/*.txt").names(among: items, base: base) == ["a.txt"])
        #expect(SelectionRule(mask: "/other/deep/*.txt").names(among: items, base: base) == ["other/deep/b.txt"])
        #expect(SelectionRule(mask: "/deep/*.txt").names(among: items, base: base).isEmpty)
    }
}
