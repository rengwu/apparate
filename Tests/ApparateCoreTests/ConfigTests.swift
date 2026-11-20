import Foundation
import ApparateCore

@MainActor func configTests(_ h: Harness) async {
    await h.test("config: first launch, defaults, missing keys and deterministic save") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        try expect(store.current.folders.map(\.path) == ["~/Projects", "~/Desktop", "~/Documents", "~/Downloads", "~", "/"])
        try expect(store.current.folders.suffix(2).allSatisfy { $0.depth == 1 })
        for json in ["{\"folders\":[]}", "{\"folders\":[{\"path\":\"/Fixture/Only\",\"depth\":3}]}"] {
            let saved = try ConfigStore.decode(Data(json.utf8))
            try expect(saved.folders.count <= 1 && !saved.folders.contains { $0.path == "~" || $0.path == "/" })
        }
        try expect(store.current == AppConfig() && store.errors.isEmpty, "Initial defaults or errors: \(store.errors)")
        let bytes = try Data(contentsOf: store.file)
        try expect(try ConfigStore.decode(bytes) == AppConfig())
        try expect(try ConfigStore.decode(Data("{}".utf8)) == AppConfig())
        try expect(try ConfigStore.decode(Data("{\"hotKey\":{},\"futureField\":true}".utf8)) == AppConfig())
        try store.save(AppConfig())
        try expect(try Data(contentsOf: store.file) == bytes, "Save bytes changed")
        try expect(AppConfig.dataDirectory(environment: ["APPARATE_HOME": dir.path]).path == dir.path, "Data directory override ignored")
        try expect(AppConfig.dataDirectory(environment: ["APPARATE_HOME": ""]).lastPathComponent == "Apparate")
    }
    await h.test("config: result location defaults, round trips and rejects unknown values") {
        try expect(try ConfigStore.decode(Data("{}".utf8)).resultLocation == .inline)
        for location in ResultLocation.allCases {
            var config = AppConfig(); config.resultLocation = location
            try expect(try ConfigStore.decode(JSONEncoder().encode(config)) == config)
        }
        for value in ["\"unknown\"", "null", "7"] {
            do { _ = try ConfigStore.decode(Data("{\"resultLocation\":\(value)}".utf8)); throw TestFailure(description: "Accepted invalid resultLocation") }
            catch is ConfigError { }
        }
    }
    await h.test("config: semantic validation collects all errors; wrong types reject") {
        let examples = [
            "{\"prefixes\":{\"files\":\"\"}}", "{\"prefixes\":{\"files\":\"!!\"}}",
            "{\"prefixes\":{\"files\":\"a\"}}", "{\"prefixes\":{\"files\":\"1\"}}",
            "{\"prefixes\":{\"files\":\" \"}}", "{\"prefixes\":{\"files\":\"\\n\"}}",
            "{\"prefixes\":{\"files\":\"/\"}}", "{\"prefixes\":{\"files\":\"~\"}}",
            "{\"prefixes\":{\"files\":\"!\",\"settings\":\"!\"}}", "{\"prefixes\":{\"unknown\":\"!\"}}",
            "{\"folders\":[{\"path\":\"relative\"}]}", "{\"folders\":[{\"path\":\"/Fixture\",\"depth\":0}]}",
            "{\"folders\":[{\"path\":\"/Fixture\",\"depth\":31}]}",
            "{\"folders\":[{\"path\":\"/Fixture/One/../Two/\"},{\"path\":\"/Fixture//Two\"}]}",
            "{\"searchURL\":\"https://example.com/\"}", "{\"searchURL\":\"https://example.com/{query}/{query}\"}",
            "{\"searchURL\":\"file:///fixture/{query}\"}", "{\"searchURL\":\"https:///{query}\"}",
            "{\"searchURL\":\"https://exa mple.com/{query}\"}", "{\"version\":2}", "{\"version\":0}",
            "{\"showMenuBarIcon\":\"yes\"}", "{\"folders\":false}", "{\"showMenuBarIcon\":null}", "{\"hotKey\":{\"keyCode\":-1}}", "{", "[]"
        ]
        for (i, json) in examples.enumerated() {
            do { _ = try ConfigStore.decode(Data(json.utf8)); throw TestFailure(description: "Accepted invalid config case \(i)") }
            catch let error as ConfigError { try expect(!error.messages.isEmpty) }
        }
        var config = AppConfig(); config.version = 5; config.prefixes = ["wrong": "a"]; config.folders = [.init(path: "relative", depth: 32)]; config.searchURL = "bad"
        try expect(config.validationErrors().count == 6)
        var lexical = AppConfig(); lexical.folders = [.init(path: "~/A/../B"), .init(path: "/Fixture/B/")]
        try expect(lexical.validationErrors(home: "/Fixture").count == 1)
        lexical.folders = [.init(path: "/DoesNotExist/Fixture", depth: 30)]
        try expect(lexical.validationErrors().isEmpty, "Nonexistent folder should be valid")
    }
    await h.test("config: invalid file and newer version preserved; last valid survives") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        var desired = AppConfig(); desired.showMenuBarIcon = false
        try store.save(desired)
        for broken in ["{broken", "{\"version\":100}"] {
            let data = Data(broken.utf8); try data.write(to: store.file, options: .atomic); store.reload()
            try expect(store.current == desired && !store.errors.isEmpty)
            do { try store.save(AppConfig()); throw TestFailure(description: "Overwrote invalid config") } catch is ConfigError { }
            try expect(try Data(contentsOf: store.file) == data)
        }
        let other = try ConfigStore(directory: dir); defer { other.stopWatching() }
        try expect(other.current == AppConfig() && !other.errors.isEmpty)
    }
    await h.test("config watches: in-place write, atomic replacement, rearm and error recovery") {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ConfigStore(directory: dir); defer { store.stopWatching() }
        var notifications = 0
        store.onChange = { _, _ in notifications += 1 }
        var desired = AppConfig(); desired.showMenuBarIcon = false
        let encoder = JSONEncoder()
        let handle = try FileHandle(forWritingTo: store.file)
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: encoder.encode(desired)); try handle.close()
        try await eventually { store.current == desired }
        desired.respectGitignore = false
        try encoder.encode(desired).write(to: store.file, options: .atomic)
        try await eventually { store.current == desired }
        // Confirm the file source was rearmed after the atomic rename.
        desired.showMenuBarIcon = true
        let replacement = try FileHandle(forWritingTo: store.file)
        try replacement.truncate(atOffset: 0); try replacement.write(contentsOf: encoder.encode(desired)); try replacement.close()
        try await eventually { store.current == desired }
        try Data("{".utf8).write(to: store.file, options: .atomic)
        try await eventually { !store.errors.isEmpty }
        try expect(store.current == desired)
        try encoder.encode(desired).write(to: store.file, options: .atomic)
        try await eventually { store.errors.isEmpty }
        let before = notifications
        try store.save(desired)
        try await Task.sleep(for: .milliseconds(150))
        try expect(notifications == before, "Own save or unchanged config caused a notification loop")
        try FileManager.default.removeItem(at: store.file)
        try await eventually { store.current == AppConfig() && FileManager.default.fileExists(atPath: store.file.path) }
        desired.showMenuBarIcon = false
        try encoder.encode(desired).write(to: store.file, options: .atomic)
        try await eventually { store.current == desired }
        try expect(notifications >= 7 && notifications < 14, "Unexpected watch notification count: \(notifications)")
    }
}
