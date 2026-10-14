import AFMKernel
import Foundation
import TestSupport

/// The folder and the list the panel-model suites of review 2 (K010-K020, K030, K033, K041-K046) work on.
internal enum ModelSample {
    /// Where the entries of the sample live.
    internal static let folder = URL(fileURLWithPath: "/review2/folder")

    /// Folders `dir0…` (every tenth) and files `file1.md…` (`.txt` for every third) with sizes that tell them apart.
    internal static func items(_ count: Int) -> [FileItem] {
        (0..<count)
            .map { index in
                guard !index.isMultiple(of: 10) else {
                    return Fixture.folder("dir\(index)", in: folder)
                }
                let suffix = index.isMultiple(of: 3) ? "txt" : "md"
                return Fixture.file("file\(index).\(suffix)", in: folder, size: Int64(index % 97 + 1))
            }
    }
}
