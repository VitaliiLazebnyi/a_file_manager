import AFMKernel
import Foundation

/// Edit Comment (spec 07 › File comments).
extension PropertyActions {
    /// Edits the comment of the item under the cursor; on `[..]`, of the folder the panel
    /// shows, whose comment is kept in the folder above (spec 07 › File comments).
    internal func editComment() {
        let model = source.model
        // Offered on an item, or on `[..]` of a folder that has a parent to keep its comment.
        let subject = model.cursorItem?.url ?? model.directory
        let (name, folder) = (subject.lastPathComponent, subject.deletingLastPathComponent())
        let store = comments
        let directory = model.directory
        kernel.jobs.run(
            title: "Reading comment:",
            work: { monitor -> String? in
                let text = store.load(folder, cancellation: monitor.cancellation).comment(for: name) ?? ""
                // A reading that was stopped says nothing; the dialog must not show "no comment".
                return monitor.cancellation.isCancelled ? nil : text
            },
            completion: { [self] read in
                guard let existing = read else {
                    return
                }
                // Asked for in a folder the panel no longer shows: the dialog would come out of nowhere.
                guard model.directory.isSameLocation(as: directory) else {
                    return
                }
                guard let text = askComment(for: name, startingWith: existing), text != existing else {
                    return
                }
                save(text, for: name, in: folder)
            }
        )
    }

    /// Asks for the new comment until it fits the comment file; nil when the dialog is cancelled.
    private func askComment(for name: String, startingWith existing: String) -> String? {
        var text = existing
        while let answer = interaction.form(
            "File comment",
            detail: "Edit comment for:\n\(PropertyText.shown(name))",
            fields: [.lines("comment", "", text)],
            buttons: ["OK"]
        ) {
            text = DescriptIon.normalized(answer.text("comment"))
            // A line break counts two characters, as it does in the file.
            let length = text.count + text.filter { $0 == "\n" }.count
            if length <= DescriptIon.commentLimit {
                return text
            }
            interaction.inform(
                "The comment is too long!",
                detail: "It has \(length) characters; \(DescriptIon.commentLimit) can be stored.",
                style: .warning
            )
        }
        return nil
    }

    /// Writes the comment in a job and reads both panels again; a failure is reported.
    private func save(_ comment: String, for name: String, in folder: URL) {
        let store = comments
        let hidden = kernel.settings.flag(FilePropertiesPlugin.Settings.hideCommentFile, default: true)
        kernel.jobs.run(
            title: "Saving comment:",
            work: { monitor -> (any Error)? in
                do {
                    try store.setComment(
                        comment,
                        for: name,
                        in: folder,
                        hidden: hidden,
                        cancellation: monitor.cancellation
                    )
                    return nil
                } catch {
                    return error
                }
            },
            completion: { [kernel] error in
                // Stopped by the user: the old comments are as they were, and there is nothing to tell.
                if (error as? CocoaError)?.code == .userCancelled {
                    return
                }
                if let error {
                    return kernel.interaction.report(
                        error,
                        title: "The comment of \(PropertyText.shown(name)) cannot be saved!"
                    )
                }
                // Saving a comment re-reads both panels.
                kernel.panels.contentsChanged(in: [folder])
                for panel in kernel.panels.all {
                    panel.reload()
                }
            }
        )
    }
}
