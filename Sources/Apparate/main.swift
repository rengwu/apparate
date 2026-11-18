import AppKit
import ApparateCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: ConfigStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            config = try ConfigStore(directory: AppConfig.dataDirectory())
            config?.onChange = { _, errors in
                for error in errors { NSLog("Config: %@", error) }
            }
            for error in config?.errors ?? [] { NSLog("Config: %@", error) }
        } catch {
            NSLog("Could not load config: %@", String(describing: error))
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
