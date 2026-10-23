import FileOperationsPlugin
import Testing

/// "Only files of this type" (spec 07 › Only files of this type).
@Suite
internal struct CopyFilters {
    /// The relative paths of a small tree that the filter lets through; folders end in `/`.
    internal func admitted(_ text: String) -> [String] {
        let filter = CopyFilter(text)
        let tree: [(String, [String])] = [
            ("", ["a.txt", "b.bak", "c.jpg"]), ("docs/", ["d.txt", "e.old"]), ("docs/build/", ["f.txt"]),
            ("src/", ["g.txt"]), ("src/docs/", ["h.txt"]), ("src/docs/deep/", ["i.txt"])
        ]
        var result: [String] = []
        var positions: [String: CopyFilter.Position] = ["": filter.base]
        for (folder, files) in tree {
            if !folder.isEmpty {
                let parts = folder.dropLast().split(separator: "/").map(String.init)
                let parent = parts.dropLast().map { $0 + "/" }.joined()
                guard let above = positions[parent], let inside = filter.entering(parts[parts.count - 1], from: above)
                else { continue }
                positions[folder] = inside
            }
            guard let position = positions[folder] else { continue }
            result += files.filter { filter.admitsFile($0, at: position) }.map { folder + $0 }
        }
        return result
    }

    /// An empty filter or one that takes every file counts as no filter and lets the whole tree through.
    @Test
    internal func emptyAndEverything() {
        #expect(CopyFilter("").isEmpty && CopyFilter("*.*").isEmpty && CopyFilter(" * ").isEmpty)
        #expect(!CopyFilter("*.txt").isEmpty && !CopyFilter("*.* | *.bak").isEmpty && !CopyFilter("| **/").isEmpty)
        #expect(admitted("").count == 9)
    }

    /// File masks before `|` take files in, masks after it leave them out; case does not matter.
    @Test
    internal func includeAndExcludeMasks() {
        #expect(
            admitted("*.txt *.JPG") == [
                "a.txt", "c.jpg", "docs/d.txt", "docs/build/f.txt", "src/g.txt", "src/docs/h.txt",
                "src/docs/deep/i.txt"
            ]
        )
        #expect(admitted("*.* | *.bak *.old") == admitted("*.txt *.jpg"))
        #expect(admitted("| *.txt") == ["b.bak", "c.jpg", "docs/e.old"])
        #expect(admitted("\"a.txt\" ?.bak") == ["a.txt", "b.bak"])
    }

    /// Folder patterns, anchored or at any depth, take folders in or leave them out with what is below them.
    @Test
    internal func folderPatterns() {
        #expect(admitted("*.txt | build/ src/") == ["a.txt", "docs/d.txt"])
        // Anchored to the base folder: only its direct subfolder docs is left out.
        #expect(admitted("*.txt | /docs/") == ["a.txt", "src/g.txt", "src/docs/h.txt", "src/docs/deep/i.txt"])
        // Included folders: the base folder's files plus the named folders, direct or at any depth, with or without
        // what is below.
        #expect(admitted("*.txt /docs/") == ["a.txt", "docs/d.txt"])
        #expect(admitted("*.txt /docs/**/") == ["a.txt", "docs/d.txt", "docs/build/f.txt"])
        #expect(admitted("*.txt docs/") == ["a.txt", "docs/d.txt", "src/docs/h.txt"])
        #expect(
            admitted("*.txt docs/**/") == [
                "a.txt", "docs/d.txt", "docs/build/f.txt", "src/docs/h.txt", "src/docs/deep/i.txt"
            ]
        )
        #expect(admitted("*.txt docs\\ | /") == ["docs/d.txt", "src/docs/h.txt"])
        #expect(CopyFilter("*.* | **/").skipsEmptyFolders && !CopyFilter("*.*").skipsEmptyFolders)
    }
}
