import AFMContracts
import AFMKernel
import FileOperationsPlugin
import Foundation
import Testing

/// What the dialogs say: headings, proposed targets, delete questions and formatted values.
@Suite
internal struct Wording {
    /// An item of that name in /tmp; a folder when `folder` is set.
    private func item(_ name: String, folder: Bool = false) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, kind: .init(isDirectory: folder))
    }

    /// The dialog heading names a single file and counts anything else.
    @Test
    internal func headings() {
        #expect(OperationText.heading("Copy", [item("a.txt")]) == "Copy \"a.txt\" to")
        #expect(OperationText.heading("Copy", [item("docs", folder: true)]) == "Copy 1 file(s) to")
        #expect(OperationText.heading("Rename/Move", [item("a"), item("b")]) == "Rename/Move 2 file(s) to")
    }

    /// The proposed target is the file's name in the other folder, or a mask for several items.
    @Test
    internal func targetProposals() {
        #expect(
            OperationText.targetProposal(for: [item("a.txt")], targetPath: "/Volumes/Data/B") == "/Volumes/Data/B/a.txt"
        )
        #expect(
            OperationText.targetProposal(for: [item("docs", folder: true)], targetPath: "/Volumes/Data/B")
                == "/Volumes/Data/B/*.*"
        )
        #expect(OperationText.targetProposal(for: [item("a"), item("b")], targetPath: "/") == "/*.*")
        #expect(OperationText.targetProposal(for: [item("docs", folder: true)], targetPath: nil) == "docs")
    }

    /// The delete question names the file or folder, or counts the items, and says where they go.
    @Test
    internal func deleteQuestions() {
        #expect(
            OperationText.deleteQuestion([item("a.txt")], toTrash: true)
                == "Do you really want to move the selected file a.txt to the Trash?"
        )
        #expect(
            OperationText.deleteQuestion([item("q", folder: true)], toTrash: false)
                == "Do you really want to delete the selected directory q?"
        )
        #expect(
            OperationText.deleteQuestion([item("a"), item("b")], toTrash: false)
                == "Do you really want to delete the 2 selected files/directories?"
        )
    }

    /// Sizes, permissions, speeds, durations and dates read as the dialogs show them.
    @Test
    internal func formats() {
        #expect(Format.bytes(250_944) == "250,944")
        #expect(Format.kilobytes(0) == "0 k")
        #expect(Format.shortSize(15) == "15 b")
        #expect(Format.shortSize(6_840) == "6.68 k")
        #expect(Format.permissions(0o755) == "rwxr-xr-x")
        #expect(Format.permissions(0o600) == "rw-------")
        #expect(Format.speed(11_600_000) == "11.06 M/s")
        #expect(Format.duration(0.2) == "1 s")
        #expect(Format.duration(78) == "1 min 20 s")
        #expect(Format.duration(3_599) == "1 h 00 min")
        #expect(Format.duration(7_500) == "2 h 05 min")
        // The date follows the user's region; it always shows year and time.
        let date = Format.date(Date(timeIntervalSince1970: 1_700_000_000))
        #expect(date.contains("2023") && date.contains(":"))
    }
}
