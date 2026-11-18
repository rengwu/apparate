import Foundation
import ApparateCore

func rowsFixture(_ entries: [CatalogEntry], query: String) throws -> [PanelRow] {
    let catalog = try CatalogSnapshot(entries: entries)
    return catalog.index.search(ParsedQuery(query)).compactMap { result in
        catalog.entries[result.item.id].map { PanelRow(result: result, entry: $0) }
    }
}
actor UsageGate {
    var calls = 0
    var pending: [Int: CheckedContinuation<UsageSnapshot, Never>] = [:]
    func read() async -> UsageSnapshot {
        calls += 1; let call = calls
        return await withCheckedContinuation { pending[call] = $0 }
    }
    func finish(_ call: Int, counts: [String: Double] = [:]) { pending.removeValue(forKey: call)?.resume(returning: UsageSnapshot(counts: counts)) }
}
func waitUsage(_ gate: UsageGate, _ count: Int) async throws {
    for _ in 0..<300 {
        if await gate.calls >= count { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure(description: "Usage read \(count) did not arrive")
}
@MainActor func panelTests(_ h: Harness) async {
    await h.test("panel M4: 50-row viewport, numbered actions, clamping and reset") {
        let rows = try rowsFixture((0..<50).map { entryFixture(String(format: "Row %02d", $0)) }, query: "row")
        var model = PanelModel(); model.show(); let revision = model.begin(query: "row"); _ = model.accept(rows, revision: revision)
        try expect(model.visibleRange == 0..<9)
        model.move(49); try expect(model.firstVisibleRow == 41 && model.selectedID == rows[49].entry.item.id)
        try expect(model.activateVisible(9)?.entry.item.id == rows[49].entry.item.id)
        model.scroll(-2); try expect(model.firstVisibleRow == 39)
        try expect(model.activateVisible(1)?.entry.item.id == rows[39].entry.item.id)
        model.move(-100); try expect(model.firstVisibleRow == 0)
        model.move(100); let next = model.begin(query: "row")
        _ = model.accept(Array(rows.prefix(4)), revision: next)
        try expect(model.firstVisibleRow == 0 && model.visibleRange == 0..<4 && model.activateVisible(5) == nil)
        model.show(); try expect(model.firstVisibleRow == 0 && model.rows.isEmpty && !model.pending)
    }
    await h.test("panel M4: explicit pending actions follow ID and cancel if removed or superseded") {
        let rows = try rowsFixture([entryFixture("Row A"), entryFixture("Row B")], query: "row")
        var model = PanelModel(); model.show(); _ = model.begin(query: "row"); _ = model.accept(rows, revision: model.revision)
        var revision = model.begin(query: "r")
        try expect(model.activateVisible(2) == nil)
        try expect(model.accept(Array(rows.reversed()), revision: revision)?.entry.item.id == rows[1].entry.item.id)
        revision = model.begin(query: "ro"); _ = model.activate(id: rows[1].entry.item.id)
        try expect(model.accept([rows[0]], revision: revision) == nil)
        for cancel in 0..<5 {
            revision = model.begin(query: "row"); _ = model.accept(rows, revision: revision)
            revision = model.begin(query: "r"); _ = model.activate(id: rows[0].entry.item.id)
            switch cancel { case 0: model.move(1); case 1: model.scroll(1); case 2: model.setComposing(true); case 3: model.hide(); default: _ = model.begin(query: "ro") }
            try expect(model.accept(rows, revision: revision) == nil)
            model.show()
        }
    }
    await h.test("panel M4: explicit Restart arms but only Return confirms; Esc and empty state precedence") {
        let session = LauncherSession(config: AppConfig(), usage: { UsageSnapshot() })
        session.setCatalog(try CatalogSnapshot(entries: CatalogEntry.commands))
        var actions = 0; session.onAction = { _ in actions += 1 }
        session.show(); session.edit("restart"); try await eventually { !session.model.pending }
        session.activateVisible(1); try expect(session.model.restartArmed && actions == 0)
        session.activateVisible(1); try expect(session.model.restartArmed && actions == 0)
        session.act(.open, isRepeat: true); try expect(actions == 0)
        session.setComposing(true); try expect(!session.escape() && session.model.query == "restart")
        session.setComposing(false); session.activateVisible(1)
        try expect(session.escape() && !session.model.restartArmed && session.model.query == "restart")
        session.activateVisible(1); session.act(.open); try expect(actions == 1)
        try expect(session.escape() && session.model.query.isEmpty && session.model.rows.isEmpty && !session.model.pending && session.model.visible)
        try expect(session.escape() && !session.model.visible)
        let cold = LauncherSession(config: AppConfig(), usage: { UsageSnapshot() })
        cold.show(); cold.edit("waiting"); try expect(cold.model.pending)
        try expect(cold.escape() && cold.model.rows.isEmpty && !cold.model.pending)
        cold.hide(); session.hide()
    }
    await h.test("panel M4: title highlight graphemes and home-abbreviated full locations") {
        let name = "A👩🏽‍💻e\u{301}東京"
        let ranges = PanelText.highlightRanges(name, offsets: [1, 2, 4, 99])
        try expect(ranges.map { (name as NSString).substring(with: $0) } == ["👩🏽‍💻", "e\u{301}", "京"])
        let entry = entryFixture("File", target: .file(URL(fileURLWithPath: "/Fixture/Home/Projects/one/src/README.md")))
        try expect(PanelText.location(entry, home: "/Fixture/Home") == "~/Projects/one/src")
        try expect(PanelText.location(entry, home: "/Fixture/Hom") == "/Fixture/Home/Projects/one/src")
        let result = try search([fixture("Visual Studio Code", alternates: ["Code"])], "code")[0]
        try expect(result.source == .alternate(0) && result.tier == .exact && result.highlights == [14, 15, 16, 17])
        let aliasOnly = try search([fixture("Editor", alternates: ["Code"])], "code")[0]
        try expect(aliasOnly.highlights.isEmpty && aliasOnly.tier == .exact)
    }
    await h.test("panel: selection follows ID, falls back and rejects stale results") {
        let entries = [entryFixture("Terminal"), entryFixture("Terminus")]
        let rows = try rowsFixture(entries, query: "term")
        var model = PanelModel(); model.show()
        let first = model.begin(query: "term"); _ = model.accept(rows, revision: first)
        model.move(1); try expect(model.selectedID == rows[1].entry.item.id)
        let second = model.begin(query: "ter"); _ = model.accept(Array(rows.reversed()), revision: second)
        try expect(model.selectedID == rows[1].entry.item.id)
        let third = model.begin(query: "terminal"); _ = model.accept([rows[0]], revision: third)
        try expect(model.selectedID == rows[0].entry.item.id)
        _ = model.accept(rows, revision: first); try expect(model.rows.count == 1)
        model.move(-100); model.move(100); try expect(model.selectedID == rows[0].entry.item.id)
        model.hide(); _ = model.accept(rows, revision: third); try expect(!model.visible)
    }
    await h.test("panel: pending Return/reveal/copy acts only on current generation; typing and movement cancel") {
        let terminal = try rowsFixture([entryFixture("Terminal")], query: "term")
        let editor = try rowsFixture([entryFixture("Editor")], query: "edit")
        for operation in [ActionOperation.open, .reveal, .copyPath] {
            var model = PanelModel(); model.show(); _ = model.begin(query: "edit"); _ = model.accept(editor, revision: model.revision)
            let revision = model.begin(query: "term")
            try expect(model.action(operation) == nil)
            try expect(model.accept(terminal, revision: revision)?.entry.item.name == "Terminal")
            let cancelled = model.begin(query: "term"); _ = model.action(operation); model.move(1)
            try expect(model.accept(terminal, revision: cancelled) == nil)
            _ = model.begin(query: "term"); _ = model.action(operation)
            let next = model.begin(query: "edit")
            try expect(model.accept(editor, revision: next) == nil)
        }
    }
    await h.test("panel: Restart requires two fresh Returns, bound to selection and result generation") {
        let restart = try rowsFixture(CatalogEntry.commands, query: "restart")
        var model = PanelModel(); model.show(); _ = model.begin(query: "restart"); _ = model.accept(restart, revision: model.revision)
        try expect(model.action(.open, isRepeat: true) == nil && !model.restartArmed)
        try expect(model.action(.open) == nil && model.restartArmed)
        try expect(model.action(.open, isRepeat: true) == nil && model.restartArmed)
        try expect(model.action(.open)?.entry.target == .command(.restart) && !model.restartArmed)
        _ = model.action(.open); model.move(1); try expect(!model.restartArmed)
        _ = model.action(.open); let revision = model.begin(query: "restart"); try expect(!model.restartArmed)
        _ = model.action(.open) // queued first Return arms, never executes
        try expect(model.accept(restart, revision: revision) == nil && model.restartArmed)
        _ = model.accept(restart, revision: revision); try expect(!model.restartArmed)
        _ = model.action(.open); model.hide(); try expect(!model.restartArmed)
        model.show(); _ = model.begin(query: "restart"); _ = model.accept(restart, revision: model.revision)
        _ = model.action(.open); model.select(id: nil); try expect(!model.restartArmed)
    }
    await h.test("panel: marked text owns Return/arrows and clears queued actions and Restart arming") {
        let rows = try rowsFixture(CatalogEntry.commands, query: "restart")
        var model = PanelModel(); model.show(); _ = model.begin(query: "restart"); _ = model.accept(rows, revision: model.revision)
        _ = model.action(.open); model.setComposing(true)
        try expect(!model.restartArmed && model.action(.open) == nil)
        let selected = model.selectedID; model.move(1); try expect(model.selectedID == selected)
        model.setComposing(false); _ = model.begin(query: "restart"); _ = model.action(.open)
        model.setComposing(true); try expect(model.accept(rows, revision: model.revision) == nil && !model.restartArmed)
    }
    await h.test("session: initial catalog readiness holds immediate Return instead of opening web fallback") {
        let session = LauncherSession(config: AppConfig(), usage: { UsageSnapshot() })
        var actions: [ActionRequest] = []; session.onAction = { actions.append($0) }
        session.show(); session.edit("term"); session.act(.open)
        try await Task.sleep(for: .milliseconds(30))
        try expect(session.model.pending && session.model.rows.isEmpty && actions.isEmpty)
        session.setCatalog(try CatalogSnapshot(entries: [entryFixture("Terminal")]))
        try await eventually { actions.count == 1 }
        try expect(actions[0].entry.item.name == "Terminal")
        session.hide()
    }
    await h.test("session: one usage read per showing across keystrokes, refresh after accepted open") {
        let gate = UsageGate(), session = LauncherSession(config: AppConfig(), usage: { await gate.read() })
        let terminal = entryFixture("Terminal"), terminus = entryFixture("Terminus")
        session.setCatalog(try CatalogSnapshot(entries: [terminal, terminus]))
        session.show(); try await waitUsage(gate, 1)
        for text in ["t", "te", "ter", "term"] { session.edit(text) }
        let pendingReads = await gate.calls; try expect(pendingReads == 1)
        await gate.finish(1); try await eventually { !session.model.pending }
        for text in ["ter", "te", "t", "term"] {
            session.edit(text); try await eventually { !session.model.pending }
        }
        let reads = await gate.calls; try expect(reads == 1 && session.model.rows.first?.entry.item.id == terminal.item.id)
        session.hide(); session.successfulOpen()
        let hiddenReads = await gate.calls; try expect(hiddenReads == 1)
        session.show(); session.edit("term"); try await waitUsage(gate, 2)
        await gate.finish(2, counts: [terminus.item.id: 20]); try await eventually { !session.model.pending }
        try expect(session.model.rows.first?.entry.item.id == terminus.item.id)
        // An open may finish recording after the user has already reopened the panel.
        session.successfulOpen(); try await waitUsage(gate, 3)
        await gate.finish(3); try await eventually { !session.model.pending }
        try expect(session.model.rows.first?.entry.item.id == terminal.item.id)
        session.hide()
    }
    await h.test("session: a stale showing's usage read cannot overwrite a newer showing or queued Return") {
        let gate = UsageGate(), session = LauncherSession(config: AppConfig(), usage: { await gate.read() })
        var actions: [ActionRequest] = []; session.onAction = { actions.append($0) }
        session.setCatalog(try CatalogSnapshot(entries: [entryFixture("Terminal"), entryFixture("Editor")]))
        session.show(); session.edit("term"); session.act(.open); try await waitUsage(gate, 1)
        session.hide(); session.show(); try await waitUsage(gate, 2)
        session.edit("term"); session.edit("edit"); session.act(.open)
        await gate.finish(2); try await eventually { actions.count == 1 }
        await gate.finish(1); try await Task.sleep(for: .milliseconds(40))
        try expect(actions.count == 1 && actions[0].entry.item.name == "Editor" && session.model.rows.first?.entry.item.name == "Editor")
        session.hide(); session.show(); session.edit("term"); session.act(.open); try await waitUsage(gate, 3)
        session.hide(); await gate.finish(3); try await Task.sleep(for: .milliseconds(40)); try expect(actions.count == 1)
    }
    await h.test("session: source/config changes cancel queued actions while sharing the showing's usage read") {
        let gate = UsageGate(), session = LauncherSession(config: AppConfig(), usage: { await gate.read() })
        var actions: [ActionRequest] = []; session.onAction = { actions.append($0) }
        session.setCatalog(try CatalogSnapshot(entries: [entryFixture("Old")]))
        session.show(); try await waitUsage(gate, 1)
        session.edit("new"); session.act(.open)
        session.setCatalog(try CatalogSnapshot(entries: [entryFixture("New")]))
        await gate.finish(1); try await eventually { !session.model.pending }
        try expect(actions.isEmpty && session.model.rows.first?.entry.item.name == "New")
        session.edit("?a+b"); session.act(.open)
        var config = AppConfig(); config.searchURL = "https://example.test/find?q={query}"; session.setConfig(config)
        try await eventually { !session.model.pending }; try expect(actions.isEmpty)
        session.act(.open)
        try expect(actions.last?.entry.target == .web(template: config.searchURL, query: "a+b"))
        let reads = await gate.calls; try expect(reads == 1)
        session.hide()
    }
    await h.test("session: usage read failure reports once per showing and keeps typing usable") {
        let session = LauncherSession(config: AppConfig(), usage: { throw SourceError("Fixture unavailable") })
        var errors = 0; session.onError = { _ in errors += 1 }
        session.setCatalog(try CatalogSnapshot(entries: [entryFixture("Terminal")]))
        session.show(); try await eventually { !session.model.pending }
        for text in ["t", "te", "ter", "term"] { session.edit(text); try await eventually { !session.model.pending } }
        try expect(errors == 1 && session.model.rows.first?.entry.item.name == "Terminal")
        session.hide()
    }
}
