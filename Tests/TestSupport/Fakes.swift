import AFMKernel
import Foundation

/// Answers the program's questions from a script and records what was asked.
public final class ScriptedInteraction: UserInteraction {
    public enum PromptAnswer {
        case accept  // OK with the proposed text
        case text(String)
        case cancel
    }

    public var promptAnswers: [PromptAnswer] = []
    public var choiceAnswers: [Int] = []

    public enum FormAnswer {
        /// The first button, with the fields as proposed.
        case accept
        /// A button, with these values in place of the proposed ones.
        case values([String: FormValues.Value], button: Int = 0)
        case cancel
    }

    /// Without an answer a form is cancelled.
    public var formAnswers: [FormAnswer] = []
    /// The fields of every form that was shown.
    public private(set) var forms: [[FormField]] = []
    public private(set) var log: [String] = []

    public init() {}

    public func prompt(_ message: String, value: String, detail: String) -> String? {
        log.append("prompt: \(message) [\(value)]")
        switch promptAnswers.isEmpty ? .cancel : promptAnswers.removeFirst() {
        case .accept: return value
        case .text(let text): return text
        case .cancel: return nil
        }
    }

    public func choose(_ message: String, detail: String, buttons: [String], style: QuestionStyle) -> Int {
        log.append("choose: \(message) / \(detail)")
        return choiceAnswers.isEmpty ? buttons.count - 1 : choiceAnswers.removeFirst()
    }

    public func inform(_ message: String, detail: String, style: QuestionStyle) {
        log.append("inform: \(message)")
    }

    public func notice(_ message: String) {
        log.append("notice: \(message)")
    }

    public func form(_ title: String, detail: String, fields: [FormField], buttons: [String]) -> FormValues? {
        log.append("form: \(title)")
        forms.append(fields)
        switch formAnswers.isEmpty ? .cancel : formAnswers.removeFirst() {
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
            guard let self, !self.model.isListed else { return }
            self.show(self.model.directory, focus: nil, history: .keep, completion: nil)
        }
        show(directory, focus: nil, history: .keep, completion: nil)
    }

    public func show(_ location: URL, focus: String?, history: PanelModel.HistoryEffect, completion: ((Bool) -> Void)?)
    {
        do {
            let result = try PanelLoader.load(location, showHidden: model.showHidden, fileSystems: fileSystems)
            model.show(result.listing, focus: focus ?? result.focus, history: history)
            completion?(true)
        } catch {
            failures.append(error.localizedDescription)
            completion?(false)
        }
    }

    public func reload(focus: String?, quietly: Bool, completion: (() -> Void)?) {
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
    public var source: PanelHandle

    public init(left: FakePanel, right: FakePanel) {
        leftPanel = left
        rightPanel = right
        source = left
        left.owner = self
        right.owner = self
    }

    public var left: PanelHandle { leftPanel }
    public var right: PanelHandle { rightPanel }
    public var target: PanelHandle { source === leftPanel ? rightPanel : leftPanel }
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

    private final class Monitor: JobMonitor {
        let cancellation = CancellationFlag()
        var reports: [JobProgress] = []
        func report(_ progress: JobProgress) { reports.append(progress) }
        func ask<Answer>(_ question: () -> Answer) -> Answer { question() }
    }

    @discardableResult
    public func run<Result>(
        title: String, work: @escaping (JobMonitor) -> Result, completion: @escaping (Result) -> Void
    ) -> JobHandle {
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

    public var panels: PanelSet { panelSet }
    public var jobs: JobService { jobService }
    public var left: FakePanel { panelSet.leftPanel }
    public var right: FakePanel { panelSet.rightPanel }
    public var commands: CommandRegistry { kernel.commands }

    /// `fileSystems` are registered before the plugins start, like a file-system plugin would.
    public init(
        plugins: [Plugin], fileSystems: [FileSystemProvider], left: URL, right: URL,
        settings: SettingsStore = MemorySettings()
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
