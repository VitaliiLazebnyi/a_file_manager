public import AFMKernel
public import Foundation

/// Answers the program's questions from a script and records what was asked.
///
/// Not tied to the main thread, unlike a real interaction: a test's job may ask from a thread of
/// its own while the main thread waits for the job (`ImmediateJobService`). Unchecked: the
/// script and the records are guarded by `lock`.
public nonisolated final class ScriptedInteraction: UserInteraction, @unchecked Sendable {
    public enum PromptAnswer: Sendable {
        case accept  // OK with the proposed text
        case text(String)
        case cancel
    }

    public enum FormAnswer: Sendable {
        /// The first button, with the fields as proposed.
        case accept
        /// A button, with these values in place of the proposed ones.
        case values([String: FormValues.Value], button: Int = 0)
        case cancel
    }

    private let lock = NSLock()
    private var script = (prompts: [PromptAnswer](), choices: [Int](), forms: [FormAnswer]())
    private var records = (forms: [[FormField]](), log: [String]())

    public var promptAnswers: [PromptAnswer] {
        get { lock.withLock { script.prompts } }
        set { lock.withLock { script.prompts = newValue } }
    }
    public var choiceAnswers: [Int] {
        get { lock.withLock { script.choices } }
        set { lock.withLock { script.choices = newValue } }
    }
    /// Without an answer a form is cancelled.
    public var formAnswers: [FormAnswer] {
        get { lock.withLock { script.forms } }
        set { lock.withLock { script.forms = newValue } }
    }
    /// The fields of every form that was shown.
    public var forms: [[FormField]] { lock.withLock { records.forms } }
    public var log: [String] { lock.withLock { records.log } }

    public init() {}

    private func record(_ line: String) {
        lock.withLock { records.log.append(line) }
    }

    public func prompt(_ message: String, value: String, detail _: String) -> String? {
        record("prompt: \(message) [\(value)]")
        let answer = lock.withLock { script.prompts.isEmpty ? .cancel : script.prompts.removeFirst() }
        switch answer {
        case .accept: return value
        case .text(let text): return text
        case .cancel: return nil
        }
    }

    public func choose(_ message: String, detail: String, buttons: [String], style _: QuestionStyle) -> Int {
        record("choose: \(message) / \(detail)")
        return lock.withLock { script.choices.isEmpty ? buttons.count - 1 : script.choices.removeFirst() }
    }

    public func inform(_ message: String, detail _: String, style _: QuestionStyle) {
        record("inform: \(message)")
    }

    public func notice(_ message: String) {
        record("notice: \(message)")
    }

    public func form(_ title: String, detail _: String, fields: [FormField], buttons _: [String]) -> FormValues? {
        record("form: \(title)")
        let answer = lock.withLock {
            records.forms.append(fields)
            return script.forms.isEmpty ? .cancel : script.forms.removeFirst()
        }
        switch answer {
        case .accept: return FormValues(defaultsOf: fields)

        case .values(let values, let button):
            var answer = FormValues(defaultsOf: fields, button: button)
            answer.values.merge(values) { _, new in new }
            return answer

        case .cancel: return nil
        }
    }
}

/// A panel without a window. It reads directories at once, on the calling thread, so a test
/// can look at the result right after a command.
public final class FakePanel: PanelHandle {
    public let tabs: PanelTabs
    private let fileSystems: FileSystemRegistry
    fileprivate weak var owner: FakePanelSet?
    public let isLoading = false
    public var viewMode = PanelViewMode.full
    public var extraColumns: [String] = []
    public private(set) var failures: [String] = []

    public init(showing directory: URL, fileSystems: FileSystemRegistry) {
        self.fileSystems = fileSystems
        tabs = PanelTabs(PanelModel(directory: directory))
        tabs.onChange = { [weak self] in
            // A tab that was never shown is read when it becomes the active one.
            guard let self, !model.isListed else { return }
            show(model.directory, focus: nil, history: .keep, completion: nil)
        }
        show(directory, focus: nil, history: .keep, completion: nil)
    }

    public func show(
        _ location: URL, focus: String?, history: PanelModel.HistoryEffect, completion: (@MainActor (Bool) -> Void)?
    ) {
        do {
            let result = try PanelLoader.load(location, showHidden: model.showHidden, fileSystems: fileSystems)
            model.show(result.listing, focus: focus ?? result.focus, history: history)
            completion?(true)
        } catch {
            failures.append(error.localizedDescription)
            completion?(false)
        }
    }

    public func reload(focus: String?, quietly _: Bool, completion: (@MainActor () -> Void)?) {
        if let result = try? PanelLoader.load(
            model.directory, showHidden: model.showHidden, fileSystems: fileSystems, climbing: true)
        {
            model.update(with: result.listing, focus: focus)
        }
        completion?()
    }

    public func focus() {
        owner?.source = self
    }

    public var names: [String] { model.items.map(\.name) }

    public func moveCursor(toName name: String) {
        if let row = model.row(ofName: name) { model.moveCursor(to: row) }
    }
}

public final class FakePanelSet: PanelSet {
    public let leftPanel: FakePanel
    public let rightPanel: FakePanel
    public var source: any PanelHandle

    public init(left: FakePanel, right: FakePanel) {
        leftPanel = left
        rightPanel = right
        source = left
        left.owner = self
        right.owner = self
    }

    public var left: any PanelHandle { leftPanel }
    public var right: any PanelHandle { rightPanel }
    public var target: any PanelHandle { source === leftPanel ? rightPanel : leftPanel }
}

/// Runs each job at once on the calling thread; `run` returns when the job is done.
public final class ImmediateJobService: JobService {
    public private(set) var isBusy = false
    public private(set) var titles: [String] = []
    public private(set) var reports: [JobProgress] = []

    public init() {}

    private final class Handle: JobHandle {
        let title: String
        let isFinished = true
        init(title: String) { self.title = title }
        func cancel() {}
    }

    /// Unchecked: the reports are guarded by `lock`.
    private final class Monitor: JobMonitor, @unchecked Sendable {
        let cancellation = CancellationFlag()
        private let lock = NSLock()
        private var all: [JobProgress] = []
        var reports: [JobProgress] { lock.withLock { all } }
        func report(_ progress: JobProgress) { lock.withLock { all.append(progress) } }

        /// The job runs inside `run` on the main thread, which waits there until the job is done.
        /// A job may spread its work over threads of its own; a question from one of them is
        /// asked on that thread, as the waiting main thread would ask it (jobs ask one question
        /// at a time). Hopping to the main thread would wait for ever.
        func ask<Answer: Sendable>(_ question: @MainActor @Sendable () -> Answer) -> Answer {
            if Thread.isMainThread { return MainActor.assumeIsolated(question) }
            return withoutActuallyEscaping(question) { unsafeBitCast($0, to: (@Sendable () -> Answer).self)() }
        }
    }

    @discardableResult
    public func run<Result: Sendable>(
        title: String, work: @escaping @Sendable (any JobMonitor) -> Result,
        completion: @escaping @MainActor (Result) -> Void
    ) -> any JobHandle {
        titles.append(title)
        let monitor = Monitor()
        isBusy = true
        let result = work(monitor)
        isBusy = false
        reports += monitor.reports
        completion(result)
        return Handle(title: title)
    }

    public func cancelAll(then completion: @escaping () -> Void) {
        completion()
    }
}

/// A kernel with fake panels and an immediate job service: everything a plugin needs to be
/// tested through its commands, without a window.
public final class TestBench: ShellServices {
    public let kernel: Kernel
    public let ui = ScriptedInteraction()
    public let jobService = ImmediateJobService()
    public let panelSet: FakePanelSet

    public var panels: any PanelSet { panelSet }
    public var jobs: any JobService { jobService }
    public var left: FakePanel { panelSet.leftPanel }
    public var right: FakePanel { panelSet.rightPanel }
    public var commands: CommandRegistry { kernel.commands }

    /// `fileSystems` are registered before the plugins start, like a file-system plugin would.
    public init(
        plugins: [any Plugin], fileSystems: [any FileSystemProvider], left: URL, right: URL,
        settings: any SettingsStore = MemorySettings()
    ) {
        kernel = Kernel(productName: "Test", settings: settings, ui: ui)
        fileSystems.forEach(kernel.fileSystems.register)
        kernel.load(plugins)
        panelSet = FakePanelSet(
            left: FakePanel(showing: left, fileSystems: kernel.fileSystems),
            right: FakePanel(showing: right, fileSystems: kernel.fileSystems))
        kernel.attach(self)
    }
}
