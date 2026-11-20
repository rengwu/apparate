import Foundation
import ApparateCore
import Synchronization

@MainActor final class ExecutorFake: ActionExecuting {
    var calls: [String] = [], failure = false
    private func accept(_ value: String) throws { calls.append(value); if failure { throw SourceError("Fixture refused") } }
    func openApplication(_ url: URL) async throws { try accept("app:" + url.path) }
    func openFile(_ url: URL, with application: URL) async throws { try accept("with:" + application.path + ":" + url.path) }
    func openURL(_ url: URL) async throws { try accept("url:" + url.absoluteString) }
    func reveal(_ url: URL) async throws { try accept("reveal:" + url.path) }
    func copyPath(_ path: String) async throws { try accept("copy:" + path) }
    func command(_ command: SystemCommand) async throws { try accept("command:" + command.rawValue) }
}
@MainActor final class RegistrarFake: HotKeyRegistering {
    var operations: [String] = [], reject = false, sequence = 0
    func register(_ key: AppConfig.HotKey) throws -> Int {
        sequence += 1; operations.append("register:\(sequence)")
        if reject { throw SourceError("Fixture conflict") }; return sequence
    }
    func unregister(_ token: Int) { operations.append("unregister:\(token)") }
}
@MainActor func actionTests(_ h: Harness) async {
    await h.test("URLs: exact query-value encoding and settings links") {
        let pairs = [("a b", "a%20b"), ("a&b", "a%26b"), ("a+b", "a%2Bb"), ("a#b", "a%23b"), ("50%", "50%25"), ("a/b", "a%2Fb"), ("😀", "%F0%9F%98%80"), ("中文", "%E4%B8%AD%E6%96%87"), ("-._~", "-._~")]
        for (raw, encoded) in pairs {
            try expect(ActionURL.web(template: "https://example.test/?q={query}&src=app", query: raw).absoluteString == "https://example.test/?q=\(encoded)&src=app")
        }
        try expect(ActionURL.settings(bundle: "com.apple.Keyboard-Settings.extension", anchor: "keyboardShortcuts").absoluteString == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?keyboardShortcuts")
        try expect(ActionURL.settings(bundle: "fixture.pane", anchor: nil).absoluteString == "x-apple.systempreferences:fixture.pane")
        do { _ = try ActionURL.web(template: "file:///tmp/{query}", query: "x"); throw TestFailure(description: "Accepted unsafe template") } catch is SourceError {}
        do { _ = try ActionURL.settings(bundle: "bad?pane", anchor: nil); throw TestFailure(description: "Accepted malformed bundle") } catch is SourceError {}
    }
    await h.test("actions: typed dispatch for every kind, primary-open usage only") {
        let executor = ExecutorFake(), history = Mutex<[String]>([])
        let dispatcher = ActionDispatcher(executor: executor, presence: { _ in .present }, record: { id in history.withLock { $0.append(id) } })
        let entries = [entryFixture("Misleading", id: "not:an:encoded:target", target: .application(URL(fileURLWithPath: "/fixture/Actual.app"))),
                       entryFixture("File", target: .file(URL(fileURLWithPath: "/fixture/file.txt"))),
                       entryFixture("Folder", target: .file(URL(fileURLWithPath: "/fixture/folder"))),
                       entryFixture("Setting", target: .settings(bundle: "fixture.pane", anchor: "option")),
                       entryFixture("Web", target: .web(template: "https://example.test/?q={query}", query: "a+b"))] + CatalogEntry.commands
        for entry in entries { let error = await dispatcher.perform(ActionRequest(entry: entry, operation: .open)); try expect(error == nil) }
        try expect(executor.calls == ["app:/fixture/Actual.app", "url:file:///fixture/file.txt", "url:file:///fixture/folder", "url:x-apple.systempreferences:fixture.pane?option", "url:https://example.test/?q=a%2Bb", "command:lock", "command:sleep", "command:restart", "command:trash"])
        for op in [ActionOperation.reveal, .copyPath] {
            let error = await dispatcher.perform(ActionRequest(entry: entries[0], operation: op)); try expect(error == nil)
        }
        try expect(executor.calls.suffix(2) == ["reveal:/fixture/Actual.app", "copy:/fixture/Actual.app"])
        try expect(history.withLock { $0 } == entries.map(\.item.id))
    }
    await h.test("actions: failure vs missing, no failed usage, history write errors do not undo success") {
        let executor = ExecutorFake(), history = Mutex(0), presence = Mutex(FilePresence.present)
        let dispatcher = ActionDispatcher(executor: executor, presence: { _ in presence.withLock { $0 } }, record: { _ in history.withLock { $0 += 1 } })
        let entry = entryFixture("Tool")
        executor.failure = true
        let failed = await dispatcher.perform(ActionRequest(entry: entry, operation: .open))
        try expect(failed?.title == "Tool" && failed?.reason == "Fixture refused" && failed?.missingID == nil)
        presence.withLock { $0 = .unknown }
        let unknown = await dispatcher.perform(ActionRequest(entry: entry, operation: .open))
        try expect(unknown?.missingID == nil)
        presence.withLock { $0 = .missing }
        let missing = await dispatcher.perform(ActionRequest(entry: entry, operation: .open))
        try expect(missing?.missingID == entry.item.id && executor.calls.count == 2 && history.withLock { $0 } == 0)
        executor.failure = false
        var historyErrors = 0
        let badHistory = ActionDispatcher(executor: executor, presence: { _ in .present }, record: { _ in throw SourceError("Disk full") })
        badHistory.onHistoryError = { _ in historyErrors += 1 }
        let accepted = await badHistory.perform(ActionRequest(entry: entry, operation: .open))
        try expect(accepted == nil && historyErrors == 1)
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try expect(filePresence(dir) == .present && filePresence(dir.appendingPathComponent("missing")) == .missing)
    }
    await h.test("hotkey: unchanged no-op, failed replacement retains old key, successful replacement before removal") {
        let registrar = RegistrarFake(), registration = HotKeyRegistration(registrar: RegistrarFake())
        registration.stop() // safe before any registration
        let current = HotKeyRegistration(registrar: registrar)
        var first = AppConfig.HotKey(); first.keyCode = 111; first.modifiers = 6400
        try current.replace(with: first); first.display = "Test key"; try current.replace(with: first)
        try expect(registrar.operations == ["register:1"] && current.active == first)
        var second = first; second.keyCode = 109
        registrar.reject = true
        do { try current.replace(with: second); throw TestFailure(description: "Expected conflict") } catch is SourceError {}
        try expect(current.active == first && registrar.operations == ["register:1", "register:2"])
        registrar.reject = false; try current.replace(with: second)
        try expect(registrar.operations.suffix(2) == ["register:3", "unregister:1"])
        current.stop(); current.stop()
        try expect(registrar.operations.last == "unregister:3" && registrar.operations.count == 5)
    }
}

actor ProbeLog {
    var calls: [AccessFolder] = [], inFlight = 0, maximum = 0
    func probe(_ folder: AccessFolder) async -> AccessStatus {
        calls.append(folder); inFlight += 1; maximum = max(maximum, inFlight)
        try? await Task.sleep(for: .milliseconds(25)); inFlight -= 1
        switch folder { case .desktop: return .allowed; case .documents: return .denied; case .downloads: return .notFound }
    }
}
@MainActor func accessTests(_ h: Harness) async {
    await h.test("access: no launch probes, explicit sequential check, saved hints and duplicate click guard") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ProbeLog(), controller = FolderAccessController(directory: dir, probe: { await log.probe($0) })
        let initial = await log.calls; try expect(initial.isEmpty && controller.observations.isEmpty)
        let task = Task { await controller.check() }
        try await eventually { controller.busy }
        await controller.check(); await task.value
        let calls = await log.calls, maxConcurrent = await log.maximum
        try expect(calls == AccessFolder.allCases && maxConcurrent == 1 && !controller.busy && controller.checking == nil)
        try expect(controller.observations.map(\.status) == [.allowed, .denied, .notFound])
        let reopened = FolderAccessController(directory: dir, probe: { await log.probe($0) })
        try expect(reopened.observations == controller.observations)
        let unchanged = await log.calls; try expect(unchanged == calls)
        // Only temporary fixtures are read by the real probe; no protected user folders.
        try expect(FolderAccessProbe.check(dir) == .allowed)
        try expect(FolderAccessProbe.check(dir.appendingPathComponent("absent")) == .notFound)
        let file = dir.appendingPathComponent("file"); try Data().write(to: file)
        try expect(FolderAccessProbe.check(file) == .error)
    }
    await h.test("access: other errors stay distinct and persistence failure is reported") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let controller = FolderAccessController(directory: dir.appendingPathComponent("missing-parent"), probe: { _ in .error })
        var errors = 0; controller.onError = { _ in errors += 1 }
        await controller.check()
        try expect(errors == 1 && controller.observations.allSatisfy { $0.status == .error } && !controller.busy)
    }
}
