import AFMContracts
import AFMKernel
import Foundation

/// Synchronizing: the plan of the shown rows, the Synchronize dialog, the job that carries it out, and what it did.
extension SyncSession {
    /// The executor of a plan in a job: it reports to the job's monitor and asks the user through it.
    nonisolated private static func executor(
        of plan: SyncPlan,
        _ run: SyncRunOptions,
        through fileSystems: FileSystemRegistry,
        monitor: any JobMonitor,
        asking interaction: any UserInteraction
    ) -> SyncExecutor {
        let executor = SyncExecutor(
            plan: plan,
            options: run,
            fileSystems: fileSystems,
            cancellation: monitor.cancellation
        )
        executor.onProgress = monitor.report
        executor.onOverwrite = { target, copy in
            monitor.ask { @MainActor @Sendable in
                interaction.pick(
                    "Overwrite \(fileSystems.displayPath(target.url))?",
                    detail: "\(Format.bytes(target.size)) bytes, \(Format.date(target.modified))\n\n"
                        + "with \(fileSystems.displayPath(copy.source))\n"
                        + "\(Format.bytes(copy.size)) bytes, \(Format.date(copy.modified))",
                    [
                        ("Overwrite", SyncOverwriteAnswer.overwrite), ("Overwrite All", .overwriteAll),
                        ("Skip", .skip),
                        ("Skip All", .skipAll), ("Cancel", .cancel)
                    ],
                    fallback: .cancel
                )
            }
        }
        executor.onError = { url, error in
            monitor.ask { @MainActor @Sendable in
                interaction.pick(
                    "Error with \(fileSystems.displayPath(url))",
                    detail: error.localizedDescription,
                    [
                        ("Skip", SyncErrorAnswer.skip), ("Skip All", .skipAll), ("Retry", .retry),
                        ("Cancel", .cancel)
                    ],
                    fallback: .cancel
                )
            }
        }
        return executor
    }

    /// What Synchronize would do now: only the rows that are shown take part.
    internal func plan() -> SyncPlan {
        SyncPlan(rows: visibleRows.map { index in rows[index] }, timeOffsetHours: compared.offsetHours)
    }

    /// Shows the Synchronize dialog and runs what the user confirmed
    /// (spec 09 › The "Synchronize" dialog and the run).
    internal func synchronize() {
        guard phase == .compared, !isPlanning else {
            return
        }
        if runsInline || rows.count < worksInBackgroundFrom {
            present(plan())
            return
        }
        // Planning copies every shown row; with a million rows that is not for the main thread. Nothing is
        // changed in the list meanwhile (`isPlanning`).
        isPlanning = true
        let offset = compared.offsetHours
        status = "Preparing the plan…"
        changed()
        // The list as it is now, which may change while the plan is made.
        let listed = rows
        let shownEntries = entries
        startWorker("Synchronize directories: plan") { [weak self] in
            var visible: [SyncRow] = []
            visible.reserveCapacity(shownEntries.count)
            for case .row(let index) in shownEntries where listed.indices.contains(index) {
                visible.append(listed[index])
            }
            let plan = SyncPlan(rows: visible, timeOffsetHours: offset)
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                isPlanning = false
                apply(currentLayout, recount: false)
                guard phase == .compared else {
                    return
                }
                present(plan)
            }
        }
    }

    /// Asks about the plan of the last comparison and runs it.
    ///
    /// Only while the comparison's rows are shown (`phase` is `.compared`).
    private func present(_ plan: SyncPlan) {
        guard !plan.isEmpty else {
            return
        }
        let fields = dialogFields(for: plan) + optionFields(for: plan)
        guard let answer = kernel.interaction.form("Synchronize", detail: "", fields: fields, buttons: ["OK"]) else {
            return
        }
        var chosen = plan
        // Another target folder may be named for each direction.
        let targets = [
            (toRight: true, key: "rightTarget", original: fileSystems.displayPath(roots.right)),
            (toRight: false, key: "leftTarget", original: fileSystems.displayPath(roots.left))
        ]
        for target in targets {
            let text = answer.text(target.key).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, text != target.original {
                kernel.userTyped(location: text, relativeTo: base)
                chosen.retarget(toRight: target.toRight, root: fileSystems.location(from: text, relativeTo: base))
            }
        }
        start(chosen, runOptions(from: answer))
    }

    /// The copies and the deletions of the plan, each to be ticked, with the targets of the copies.
    private func dialogFields(for plan: SyncPlan) -> [FormField] {
        let (leftText, rightText) = (fileSystems.displayPath(roots.left), fileSystems.displayPath(roots.right))
        var fields: [FormField] = []
        if !plan.toRight.isEmpty {
            fields += [
                .checkbox("toRight", "Left to right: " + SyncPlan.describe(plan.toRight), true),
                .text("rightTarget", "Target:", rightText)
            ]
        }
        if !plan.toLeft.isEmpty {
            fields += [
                .checkbox("toLeft", "Right to left: " + SyncPlan.describe(plan.toLeft), true),
                .text("leftTarget", "Target:", leftText)
            ]
        }
        // Deletions say where they are done. Against a source that looks empty they are not ticked: they
        // happen only if the user asks for them here.
        if sourceLooksEmpty, !plan.deleteRight.isEmpty {
            fields.append(
                .note(
                    "The left directory is empty or not available. Tick the deletion only if everything on the "
                        + "right is to go."
                )
            )
        }
        if !plan.deleteRight.isEmpty {
            fields.append(
                .checkbox(
                    "deleteRight",
                    "Right: Delete \(plan.deleteRight.count) file(s) in \(rightText)",
                    !sourceLooksEmpty
                )
            )
        }
        if !plan.deleteLeft.isEmpty {
            fields.append(
                .checkbox("deleteLeft", "Left: Delete \(plan.deleteLeft.count) file(s) in \(leftText)", true)
            )
        }
        if options.asymmetric {
            fields.append(.checkbox("emptyDirectories", "Right: Delete all empty directories in \(rightText)", false))
        }
        return fields
    }

    /// The boxes of how the run goes: overwrites confirmed, and, with deletions, the Trash.
    private func optionFields(for plan: SyncPlan) -> [FormField] {
        var fields: [FormField] = [
            .checkbox(
                "confirm",
                "Confirm overwrites",
                settings.flag(SyncSettingsKey.confirmOverwrites, default: true)
            )
        ]
        if !plan.deleteLeft.isEmpty || !plan.deleteRight.isEmpty || options.asymmetric {
            fields.append(
                .checkbox(
                    "direct",
                    "Delete directly instead of moving to the Trash",
                    !settings.flag(SyncSettingsKey.useTrash, default: true)
                )
            )
        }
        return fields
    }

    /// How the run goes, as the user ticked it in the dialog.
    private func runOptions(from answer: FormValues) -> SyncRunOptions {
        var run = SyncRunOptions()
        run.copyToRight = answer.flag("toRight")
        run.copyToLeft = answer.flag("toLeft")
        run.deleteRight = answer.flag("deleteRight")
        run.deleteLeft = answer.flag("deleteLeft")
        run.confirmOverwrites = answer.flag("confirm")
        run.useTrash = !answer.flag("direct")
        run.removeEmptyDirectoriesBelow = answer.flag("emptyDirectories") ? roots.right : nil
        run.mayChangeSourceDates =
            !options.ignoreDate && settings.flag(SyncSettingsKey.changeSourceDates, default: true)
        // The time tolerance the run uses: the one the comparison found necessary.
        run.toleranceSeconds = compared.toleranceSeconds
        return run
    }

    /// Runs the plan as a job; until it is over neither Synchronize nor Compare may start.
    private func start(_ plan: SyncPlan, _ run: SyncRunOptions) {
        let (interaction, registry) = (kernel.interaction, fileSystems)
        // The progress window is another window: until the job is over neither Synchronize nor Compare may start.
        phase = .synchronizing
        changed()
        kernel.jobs.run(
            title: "Synchronize",
            work: { monitor -> SyncOutcome in
                Self.executor(of: plan, run, through: registry, monitor: monitor, asking: interaction).run()
            },
            completion: { [weak self] outcome in
                self?.finished(outcome)
            }
        )
    }

    /// The job is over: the panels show what changed, the user hears what went wrong, and the list is compared
    /// again (or emptied).
    private func finished(_ outcome: SyncOutcome) {
        phase = .compared
        kernel.panels.refresh(outcome.changedDirectories)
        report(outcome)
        // The comparison runs again by itself, so the list shows what is left to do
        // (`SyncRecompareAfterCopy`).
        if settings.flag(SyncSettingsKey.recompare, default: true) {
            compare()
        } else {
            clear()
        }
    }

    /// Says what did not go well: failures (also those after "Skip All", which asked no more), a
    /// write that could not be made durable (the deletions were then not done), a run that was stopped.
    internal func report(_ outcome: SyncOutcome) {
        guard !outcome.errors.isEmpty || outcome.commitFailed || outcome.wasCancelled else {
            return
        }
        var lines = ["Copied: \(outcome.copied), deleted: \(outcome.deleted), left alone: \(outcome.skipped)."]
        if outcome.commitFailed {
            lines.append("What was written could not be made permanent, so nothing was deleted.")
        }
        if outcome.wasCancelled {
            lines.append("The run was stopped before it was finished.")
        }
        if !outcome.errors.isEmpty {
            lines.append("")
            lines += outcome.errors.prefix(12)
            if outcome.errors.count > 12 {
                lines.append("… and \(outcome.errors.count - 12) more")
            }
        }
        kernel.interaction.inform(
            outcome.errors.isEmpty && !outcome.commitFailed
                ? "Synchronize was stopped." : "Synchronize did not finish without errors.",
            detail: lines.joined(separator: "\n"),
            style: .warning
        )
    }
}
