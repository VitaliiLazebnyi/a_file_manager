import AFMKernel
import Foundation

/// Split, combine, encode and decode: the dialogs, the jobs and what they report.
extension FileTools {
    // MARK: Split and combine

    /// Split File: asks for the folder and the size of the parts, and splits the file.
    internal func split(_ file: FileItem) {
        let directory = source.directory
        let presets = ["(the size typed above)"] + Splitter.presets.map(\.title)
        let fields: [FormField] = [
            .note("Split the file '\(file.name)' to directory:"), .text("target", "", targetProposal),
            .text("size", "Bytes per file:", settings.text(Keys.splitSize, default: "")),
            .choice("preset", "or a standard size:", presets),
            .note("A size is a number of bytes, or a number with k, M or G (1 k = 1024 bytes).")
        ]
        guard let answer = interaction.form("Split", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        let preset = answer.index("preset")
        guard let size = preset > 0 ? Splitter.presets[preset - 1].bytes : Splitter.size(from: answer.text("size"))
        else {
            interaction.inform("Split", detail: "Please enter the number of bytes per file!", style: .warning)
            return
        }
        if preset <= 0 {
            settings.set(answer.text("size").trimmingCharacters(in: .whitespaces), forKey: Keys.splitSize)
        }
        let target = folder(from: answer.text("target"), relativeTo: directory)
        run(
            "Split",
            job: "Split:",
            refreshing: { _ in [target] },
            { run -> [URL] in
                try Self.prepare(target, run)
                return try Splitter.split(file, into: target, partSize: size, run: run)
            },
            then: { [interaction, fileSystems] _ in
                interaction.inform(
                    "Split",
                    detail: "Split of \(fileSystems.displayPath(file.url)) succeeded!",
                    style: .information
                )
            }
        )
    }

    /// Combine Files: asks for the folder, combines the file and the ones after it, and says whether the CRC
    /// matched.
    internal func combine(_ file: FileItem) {
        let directory = source.directory
        let fields: [FormField] = [
            .note("Combine \(file.name) and all files with ascending names to the following directory:"),
            .text("target", "", targetProposal)
        ]
        guard let answer = interaction.form("Combine", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        let target = folder(from: answer.text("target"), relativeTo: directory)
        run(
            "Combine",
            job: "Combine:",
            refreshing: { _ in [target] },
            { run -> Combiner.Outcome in
                try Self.prepare(target, run)
                let plan = try Combiner.plan(for: file, run: run)
                return try Combiner.combine(plan.parts, info: plan.info, into: target, run: run)
            },
            then: { [interaction] outcome in
                let name = outcome.output.lastPathComponent
                switch outcome.check {
                case .matches:
                    interaction.inform(
                        "Combine - \(outcome.parts)",
                        detail: "Combine of \(name) succeeded (CRC checksum OK)!",
                        style: .information
                    )

                case .damaged:
                    interaction.inform(
                        "Combine - \(outcome.parts)",
                        detail: "Combine of \(name): CRC checksum error! The file is damaged or incomplete.",
                        style: .critical
                    )

                case .unchecked:
                    interaction.inform(
                        "Combine - \(outcome.parts)",
                        detail: "Combine of \(name) succeeded!",
                        style: .information
                    )
                }
            }
        )
    }

    // MARK: Encode and decode

    /// Encode File: asks for the folder, the format and the limits of one file, and encodes the file.
    internal func encode(_ file: FileItem) {
        let directory = source.directory
        let lastLines = settings.index(Keys.encodeLines, default: 0)
        let fields: [FormField] = [
            .note("Encode the file \(file.name) to directory:"), .text("target", "", targetProposal),
            .choice(
                "method",
                "Encode as:",
                EncodeMethod.allCases.map(\.title),
                selected: settings.index(Keys.encodeMethod, default: 0)
            ),
            .text("lines", "Lines per file:", lastLines > 0 ? String(lastLines) : ""),
            .text("bytes", "Bytes per file:", ""),
            .note("(Note: header size is not counted)")
        ]
        guard let answer = interaction.form("Encode", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        let options = Encoder.Options(
            method: EncodeMethod(rawValue: answer.index("method")) ?? .mime,
            linesPerFile: max(0, Int(answer.text("lines").trimmingCharacters(in: .whitespaces)) ?? 0),
            bytesPerFile: Splitter.size(from: answer.text("bytes")) ?? 0
        )
        settings.set(options.method.rawValue, forKey: Keys.encodeMethod)
        settings.set(options.linesPerFile, forKey: Keys.encodeLines)
        let target = folder(from: answer.text("target"), relativeTo: directory)
        run(
            "Encode",
            job: "Encode:",
            refreshing: { _ in [target] },
            { run -> [URL] in
                try Self.prepare(target, run)
                return try Encoder.encode(file, into: target, options: options, run: run)
            },
            then: { _ in
                // Nothing to say: the panel shows the files.
            }
        )
    }

    /// Decode File: asks for the folder, decodes the file (and the parts after it), and says what of the text
    /// was incomplete or damaged.
    internal func decode(_ file: FileItem) {
        let directory = source.directory
        let fields: [FormField] = [
            .note("Decode the file \(file.name) to directory:"), .text("target", "", targetProposal),
            .checkbox("autoRename", "Auto-rename decoded files")
        ]
        guard let answer = interaction.form("Decode", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        let target = folder(from: answer.text("target"), relativeTo: directory)
        let autoRename = answer.flag("autoRename")
        run(
            "Decode",
            job: "Decode:",
            refreshing: { _ in [target] },
            { run -> Decoder.Outcome in
                // Unlike Copy, Decode does not create a missing target folder.
                guard run.fileSystems.item(at: target)?.isDirectory == true else {
                    throw ToolError.failed("The given target path\n\(run.fileSystems.displayPath(target))\nis invalid!")
                }
                return try Decoder.decodeChecked(file, into: target, autoRename: autoRename, run: run)
            },
            then: { [interaction, fileSystems] outcome in
                // The files are kept; what the encoded text itself shows to be wrong is said.
                guard !outcome.problems.isEmpty else {
                    return
                }
                let shown = outcome.problems.prefix(8).map { problem in "- " + problem }.joined(separator: "\n")
                let more = outcome.problems.count > 8 ? "\n... and \(outcome.problems.count - 8) more" : ""
                let folder = fileSystems.displayPath(target)
                interaction.inform(
                    "Decode",
                    detail: "\(file.name) is incomplete or damaged:\n\(shown)\(more)\n\n"
                        + "The decoded data was written to \(folder) as far as it could be read.",
                    style: .warning
                )
            }
        )
    }
}
