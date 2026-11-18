import AppKit
import ApparateCore
import Darwin

@MainActor struct TestProfile {
    let mode: String
    let directory: URL
    let seconds: Double
    let query: String
    let show: String?
    let performAction: Bool
    static func read(_ env: [String: String]) throws -> TestProfile? {
        guard let mode = env["APPARATE_TEST_MODE"] else { return nil }
        guard ["fixtures", "live-readonly"].contains(mode), let home = env["APPARATE_HOME"], !home.isEmpty else {
            throw SourceError("An isolated APPARATE_HOME and a valid test mode are required.")
        }
        let directory = URL(fileURLWithPath: home, isDirectory: true)
        let config = try ConfigStore.decode(Data(contentsOf: directory.appendingPathComponent("config.json")))
        guard !(config.hotKey.keyCode == 49 && config.hotKey.modifiers == 256) else {
            throw SourceError("Seed the alternate test shortcut before launching the test app.")
        }
        let allowedProject = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects").path
        let temporary = FileFolderWatcher.canonical(FileManager.default.temporaryDirectory.path)
        for folder in config.folders {
            let path = AppConfig.normalizedFolder(folder.path, home: FileManager.default.homeDirectoryForCurrentUser.path)
            let canonical = FileFolderWatcher.canonical(path)
            guard (canonical.hasPrefix(temporary + "/") || canonical.hasPrefix("/private/tmp/")) ||
                  (mode == "live-readonly" && path == allowedProject) else {
                throw SourceError("Test folders must be owned temporary fixtures, or Projects in read-only mode.")
            }
        }
        let show = env["APPARATE_SHOW"]
        guard mode == "fixtures" || show == nil else { throw SourceError("Visible test windows require fixture sources.") }
        return TestProfile(mode: mode, directory: directory, seconds: min(90, max(1, Double(env["APPARATE_TEST_SECONDS"] ?? "3") ?? 3)),
                           query: env["APPARATE_TEST_QUERY"] ?? "term", show: show, performAction: env["APPARATE_TEST_ACTION"] == "open")
    }
    nonisolated static func fixtureCatalog() throws -> CatalogSnapshot {
        let terminal = CatalogEntry(item: SearchItem(id: "fixture:terminal", kind: .app, name: "Terminal", path: "/Fixture/Applications/Terminal.app"),
                                    target: .application(URL(fileURLWithPath: "/Fixture/Applications/Terminal.app")), location: "Applications", icon: .symbol("terminal"))
        let code = CatalogEntry(item: SearchItem(id: "fixture:code", kind: .app, name: "Visual Studio Code", alternateNames: ["Code"]),
                               target: .application(URL(fileURLWithPath: "/Fixture/Applications/Code.app")), location: "Applications", icon: .symbol("curlybraces"))
        let setting = CatalogEntry(item: SearchItem(id: "fixture:keyboard", kind: .setting, name: "Keyboard layouts", keywords: ["input", "languages"]),
                                  target: .settings(bundle: "com.apple.Keyboard-Settings.extension", anchor: "InputSources"), location: "Keyboard", icon: .symbol("keyboard"))
        let files = ["terminal-notes.md", "term.txt"].map { name in
            CatalogEntry(item: SearchItem(id: "fixture:" + name, kind: .file, name: name, path: "/Fixture/Notes/" + name),
                         target: .file(URL(fileURLWithPath: "/Fixture/Notes/" + name)), location: "Notes", icon: .symbol("doc.text"))
        }
        return try CatalogSnapshot(entries: [terminal, code, setting] + files + CatalogEntry.commands)
    }
}

enum ProcessMetrics {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
