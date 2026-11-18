import AppKit
import Carbon
import IOKit.pwr_mgt
import ApparateCore

@MainActor final class NativeActionExecutor: ActionExecuting {
    func openApplication(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    func openURL(_ url: URL) async throws {
        guard NSWorkspace.shared.open(url) else { throw SourceError("macOS did not accept the open request.") }
    }
    func reveal(_ url: URL) async throws { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func copyPath(_ path: String) async throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(path, forType: .string) else { throw SourceError("The path could not be copied.") }
    }
    func command(_ command: SystemCommand) async throws {
        switch command {
        case .trash: try await openURL(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        case .lock:
            // Optional private system entry point. No fallback that sends keys or requests automation.
            guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY) else {
                throw SourceError("Lock Screen is unavailable on this system.")
            }
            defer { dlclose(library) }
            guard let symbol = dlsym(library, "SACLockScreenImmediate") else { throw SourceError("Lock Screen is unavailable on this system.") }
            unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)()
        case .sleep:
            try await Task.detached {
                let connection = IOPMFindPowerManagement(0)
                guard connection != 0 else { throw SourceError("The power-management service is unavailable.") }
                defer { IOServiceClose(connection) }
                let status = IOPMSleepSystem(connection)
                guard status == kIOReturnSuccess else { throw SourceError("The sleep request failed (\(status)).") }
            }.value
        case .restart: try await Task.detached { try Self.requestRestart() }.value
        }
    }
    nonisolated private static func requestRestart() throws {
        var process = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        var target = AEAddressDesc(), event = AppleEvent(), reply = AppleEvent()
        var status = AECreateDesc(DescType(typeProcessSerialNumber), &process, MemoryLayout<ProcessSerialNumber>.size, &target)
        guard status == noErr else { throw SourceError("The restart target could not be created (\(status)).") }
        defer { AEDisposeDesc(&target) }
        status = AECreateAppleEvent(AEEventClass(kCoreEventClass), AEEventID(kAERestart), &target, AEReturnID(kAutoGenerateReturnID), AETransactionID(kAnyTransactionID), &event)
        guard status == noErr else { throw SourceError("The restart request could not be created (\(status)).") }
        defer { AEDisposeDesc(&event); AEDisposeDesc(&reply) }
        let sendStatus = AESendMessage(&event, &reply, AESendMode(kAEWaitReply | kAECanInteract | kAECanSwitchLayer), kAEDefaultTimeout)
        guard sendStatus == noErr else { throw SourceError("The restart request failed (\(sendStatus)).") }
        var result: Int32 = 0
        let resultStatus = AEGetParamPtr(&reply, AEKeyword(keyErrorNumber), DescType(typeSInt32), nil, &result, MemoryLayout<Int32>.size, nil)
        if resultStatus == noErr && result != 0 { throw SourceError("The restart request was declined (\(result)).") }
    }
}

@MainActor final class NativeHotKeyRegistrar: HotKeyRegistering {
    var onPress: () -> Void = {}
    private var handler: EventHandlerRef?
    private var keys: [Int: EventHotKeyRef] = [:]
    private var next = 0
    init() {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr, key.signature == 0x41505052 else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<NativeHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                guard owner.keys[Int(key.id)] != nil else { return OSStatus(eventNotHandledErr) }
                owner.onPress(); return OSStatus(noErr)
            }
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    isolated deinit {
        for key in keys.values { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
    func register(_ key: AppConfig.HotKey) throws -> Int {
        guard handler != nil else { throw SourceError("The shortcut event handler could not be installed.") }
        next += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: 0x41505052, id: UInt32(next)),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { throw SourceError("The shortcut \(key.display) could not be registered (\(status)).") }
        keys[next] = reference; return next
    }
    func unregister(_ token: Int) { if let key = keys.removeValue(forKey: token) { UnregisterEventHotKey(key) } }
}

/// Used only by an explicit isolated test profile; none of these methods touch global state.
@MainActor final class TestEffects: ActionExecuting, HotKeyRegistering {
    private(set) var actionCount = 0, registrationCount = 0, applicationOpens = 0, urlOpens = 0
    func openApplication(_ url: URL) async throws { actionCount += 1; applicationOpens += 1 }
    func openURL(_ url: URL) async throws { actionCount += 1; urlOpens += 1 }
    func reveal(_ url: URL) async throws { actionCount += 1 }
    func copyPath(_ path: String) async throws { actionCount += 1 }
    func command(_ command: SystemCommand) async throws { actionCount += 1 }
    func register(_ key: AppConfig.HotKey) throws -> Int { registrationCount += 1; return registrationCount }
    func unregister(_ token: Int) {}
}
