import Foundation
import ApparateCore
import Synchronization

struct TestFailure: Error, CustomStringConvertible { let description: String }
func expect(_ value: @autoclosure () throws -> Bool, _ message: String = "Expectation failed") throws {
    if try !value() { throw TestFailure(description: message) }
}
func near(_ a: Double, _ b: Double, tolerance: Double = 0.000001) throws {
    try expect(abs(a - b) < tolerance, "Expected \(b), observed \(a)")
}
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("apparate-m1-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func fixture(_ name: String, _ kind: ItemKind = .app, id: String? = nil, alternates: [String] = [], keywords: [String] = [], path: String? = nil) -> SearchItem {
    SearchItem(id: id ?? "fixture:\(kind.rawValue):\(name)", kind: kind, name: name, alternateNames: alternates, keywords: keywords, path: path)
}
func search(_ items: [SearchItem], _ text: String, config: AppConfig = AppConfig(), usage: UsageSnapshot = UsageSnapshot()) throws -> [SearchResult] {
    try SearchIndex(items: items).search(ParsedQuery(text, config: config), usage: usage)
}
@MainActor func eventually(_ condition: () -> Bool, timeout: Double = 3) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try expect(condition(), "Timed out waiting for observable state")
}

@MainActor final class Harness {
    var passed = 0, failed = 0
    func test(_ name: String, _ body: () async throws -> Void) async {
        if let filter = ProcessInfo.processInfo.environment["APPARATE_TEST_FILTER"], !name.localizedCaseInsensitiveContains(filter) { return }
        do { try await body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }
}

@main struct Runner {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--file-comparison") {
            do { try await runFileComparisonBenchmark() } catch { print("File comparison failed: \(error)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--file-benchmark") || CommandLine.arguments.contains("--file-idle") {
            do {
                if CommandLine.arguments.contains("--file-idle") { try await runFileIdle() }
                else { try await runFileBenchmark() }
            } catch { print("File measurement failed: \(type(of: error))"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--benchmark") {
            do { try runBenchmark() } catch { print("Benchmark failed: \(error)"); exit(1) }
            return
        }
        let h = Harness()
        await rankingTests(h)
        await unicodeTests(h)
        await alignmentTests(h)
        await configTests(h)
        await settingsTests(h)
        await usageTests(h)
        await coordinatorTests(h)
        await sourceTests(h)
        await actionTests(h)
        await panelTests(h)
        await accessTests(h)
        await ignoreTests(h)
        await fileIndexTests(h)
        print("RESULT \(h.passed) passed; \(h.failed) failed")
        if h.failed > 0 { exit(1) }
    }
}
