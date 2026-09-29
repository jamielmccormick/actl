// FSEvents watcher, user notifications, login item.

import ActlCore
import AppKit
import CoreServices
import ServiceManagement
import UserNotifications

/// Watches directories with FSEvents and calls back on the main thread when anything changes.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let onChange: @MainActor () -> Void

    init(paths: [String], onChange: @escaping @MainActor () -> Void) {
        self.paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        self.onChange = onChange
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in watcher.onChange() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Posts only actionable notifications, deduplicated by the store. Permission is requested during first run.
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()
    private var timer: Timer?
    private weak var store: AppStore?
    private(set) var available = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"

    func attach(store: AppStore) {
        self.store = store
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in NotificationBridge.shared.drain() }
        }
    }

    func requestPermission() async -> Bool {
        guard available else { return false }
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        store?.preferences.notificationsRequested = true
        return ok
    }

    private func drain() {
        guard let store, !store.pendingNotifications.isEmpty, store.preferences.notificationsRequested else { return }
        let items = store.pendingNotifications
        store.pendingNotifications.removeAll()
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = nil
            let req = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { WindowOpener.open(WindowID.main) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

/// Open at login through SMAppService (no hand-written LaunchAgent).
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum External {
    static func revealInFinder(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: (p as NSString).deletingLastPathComponent)
    }

    static func openInTerminal(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        var dir = p
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue { dir = (p as NSString).deletingLastPathComponent }
        let url = URL(fileURLWithPath: dir)
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func open(_ urlString: String) {
        if let u = URL(string: urlString) { NSWorkspace.shared.open(u) }
    }
}
