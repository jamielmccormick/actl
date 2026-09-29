// actl for Mac: menu bar item (always on), main window, settings, first run, sign-in queue.

import ActlCore
import ActlFixtures
import AppKit
import SwiftUI

@main
struct ActlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var runtime = Runtime.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(runtime.store)
                .environment(runtime.nav)
                .frame(width: 380)
        } label: {
            // The label is always live, so it also services window-open requests from AppKit-side code.
            MenuBarLabel().hostsWindowOpener().environment(runtime.store).environment(runtime.nav)
        }
        .menuBarExtraStyle(.window)

        Window("actl", id: WindowID.main) {
            MainWindow()
                .environment(runtime.store)
                .environment(runtime.nav)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { AppCommands(nav: runtime.nav, store: runtime.store) }

        Window("Welcome to actl", id: WindowID.firstRun) {
            FirstRunView()
                .environment(runtime.store)
                .environment(runtime.nav)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Sign in", id: WindowID.signIn) {
            SignInQueueView()
                .environment(runtime.store)
                .frame(width: 420)
        }
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultPosition(.topTrailing)

        Settings {
            SettingsView()
                .environment(runtime.store)
                .environment(runtime.nav)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let firstRun = "first-run"
    static let signIn = "sign-in"
    static let settings = "settings"   // routed to openSettings, not a Window scene
}

/// Navigation state shared by the window, the popover and the command palette.
@MainActor
@Observable
final class Navigation {
    enum Screen: String, CaseIterable, Identifiable {
        case home, services, skills, instructions, contextBudget, proxy, review, activity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "Home"
            case .services: return "Services"
            case .skills: return "Skills"
            case .instructions: return "Instructions"
            case .contextBudget: return "Context budget"
            case .proxy: return "Proxy accounts"
            case .review: return "Review changes"
            case .activity: return "Activity"
            }
        }
        var icon: IconName {
            switch self {
            case .home: return .home
            case .services: return .services
            case .skills: return .skills
            case .instructions: return .instructions
            case .contextBudget: return .contextBudget
            case .proxy: return .proxy
            case .review: return .reviewChanges
            case .activity: return .activity
            }
        }
    }

    var screen: Screen = .home
    var selectedService: String?
    var paletteOpen = false
    var showCommands = false
    var pendingOpen: [String] = []   // window ids requested from outside SwiftUI views

    func go(_ s: Screen, service: String? = nil) {
        screen = s
        if let service { selectedService = service }
        paletteOpen = false
    }
}

/// Process-wide services: the store, the engine, the file watcher, the refresh schedule, notifications.
@MainActor
@Observable
final class Runtime {
    static let shared = Runtime()

    let store: AppStore
    let nav = Navigation()
    let usingFixtures: Bool
    private var watcher: FileWatcher?
    private var timers: [Timer] = []
    private var debounce: Task<Void, Never>?
    var popoverVisible = false
    var proxyVisible = false

    private init() {
        let env = ProcessInfo.processInfo.environment
        let fx = env["ACTL_FIXTURES"] ?? ""
        let wantFixtures = CommandLine.arguments.contains("--fixtures") || (!fx.isEmpty && fx != "0")
        var engine: Engine
        var fixtures = wantFixtures
        if !wantFixtures, case .success(let loc) = ProcessEngine.locate() {
            engine = ProcessEngine(location: loc)
        } else if wantFixtures {
            engine = FixtureEngine(variant: env["ACTL_FIXTURES"] == "healthy" ? "healthy" : nil)
        } else {
            // No engine anywhere: fall back to fixtures so the app still opens, and say so in the UI.
            engine = FixtureEngine()
            fixtures = true
            Runtime.engineMissingMessage = (ProcessEngine.locate().failureMessage ?? "engine not found")
        }
        usingFixtures = fixtures
        var prefs = Preferences.load()
        if env["ACTL_FIRST_RUN"] == "1" { prefs.firstRunCompleted = false }
        if env["ACTL_FIRST_RUN"] == "0" { prefs.firstRunCompleted = true }
        if env["ACTL_RESET_PREFS"] == "1" { prefs = Preferences() }
        store = AppStore(engine: engine, isFixtures: fixtures, preferences: prefs)
        if fixtures { store.preferences.firstRunCompleted = env["ACTL_FIRST_RUN"] == "1" ? false : true }
        if let e = Runtime.engineMissingMessage { store.engineError = e }
    }

    nonisolated(unsafe) static var engineMissingMessage: String?

    func start() {
        Task { await store.bootstrap() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cfg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let paths = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".codex"), home.appendingPathComponent(".agents"), cfg.appendingPathComponent("actl")]
        watcher = FileWatcher(paths: paths.map(\.path)) { [weak self] in self?.filesChanged() }
        watcher?.start()

        // Full inventory every 30 minutes.
        timers.append(Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in await Runtime.shared.store.refreshInventory(force: true) }
        })
        // Proxy: every 60 s while visible, every 10 min in the background.
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                let r = Runtime.shared
                if r.proxyVisible || r.popoverVisible { await r.store.refreshProxy() }
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { _ in
            Task { @MainActor in await Runtime.shared.store.refreshProxy() }
        })
    }

    private func filesChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.store.refreshCheap()
        }
    }

    /// Called when the popover opens: refresh the cheap set, and the inventory if older than 5 minutes.
    func popoverOpened() {
        popoverVisible = true
        Task {
            await store.refreshStatus()
            await store.refreshInventoryIfStale(maxAge: 5 * 60)
            if store.proxyConfigured { await store.refreshProxy() }
        }
    }
}

extension Result where Success == EngineLocation, Failure == EngineError {
    var failureMessage: String? {
        if case .failure(let e) = self { return e.errorDescription }
        return nil
    }
}

// MARK: - App delegate: activation policy, Dock icon state, notifications, launch options

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if let a = env["ACTL_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        }
        NSApp.setActivationPolicy(.accessory)
        Runtime.shared.start()
        NotificationBridge.shared.attach(store: Runtime.shared.store)

        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.windowsChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // Evaluate after the window is gone.
            DispatchQueue.main.async { AppDelegate.windowsChanged() }
        })

        let openMain = env["ACTL_OPEN"] == "main" || CommandLine.arguments.contains("--open")
        let needsFirstRun = !Runtime.shared.store.preferences.firstRunCompleted
        DispatchQueue.main.async {
            if needsFirstRun { WindowOpener.open(WindowID.firstRun) } else if openMain { WindowOpener.open(WindowID.main) }
            if let screen = env["ACTL_SCREEN"], let s = Navigation.Screen(rawValue: screen) { Runtime.shared.nav.screen = s }
            if env["ACTL_OPEN"] == "signin" {
                // Debug only: start the queue once services are known.
                Task { @MainActor in
                    for _ in 0..<40 where Runtime.shared.store.services.value == nil { try? await Task.sleep(for: .milliseconds(250)) }
                    let items = Runtime.shared.store.signInCandidates(harness: "claude")
                    Runtime.shared.store.startSignIn(items)
                    WindowOpener.open(WindowID.signIn)
                }
            }
            if env["ACTL_OPEN"] == "settings" { WindowOpener.open(WindowID.settings) }
            // Debug only, fixtures only: exercise the streaming apply UI without a click.
            if env["ACTL_DEMO_APPLY"] == "1", Runtime.shared.usingFixtures {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Runtime.shared.store.applySelected() }
            }
        }
        DockIcon.update(level: Runtime.shared.store.level)
    }

    /// Show a Dock icon while a real window is open; go back to menu-bar-only when the last one closes.
    @MainActor
    static func windowsChanged() {
        let visible = NSApp.windows.filter { w in
            w.isVisible && w.identifier != nil && (w.identifier!.rawValue.hasPrefix(WindowID.main) || w.identifier!.rawValue.hasPrefix(WindowID.firstRun) || w.identifier!.rawValue.contains("Settings"))
        }
        let policy: NSApplication.ActivationPolicy = visible.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { NSApp.activate() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.open(WindowID.main) }
        return true
    }
}

/// Opens SwiftUI windows from AppKit-side code by asking any live view to forward the request.
@MainActor
enum WindowOpener {
    static let notification = Notification.Name("dev.actl.openWindow")
    static func open(_ id: String) {
        // If a window with this identifier already exists, just bring it forward.
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == id || $0.identifier?.rawValue.hasPrefix(id + "-") == true }) {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return
        }
        Runtime.shared.nav.pendingOpen.append(id)
        NotificationCenter.default.post(name: notification, object: id)
    }
}

/// A modifier that lets any view (the popover, the main window) service `WindowOpener` requests.
struct WindowOpenerHost: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(Navigation.self) private var nav
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: WindowOpener.notification)) { n in
                guard let id = n.object as? String else { return }
                if let i = nav.pendingOpen.firstIndex(of: id) { nav.pendingOpen.remove(at: i) }
                open(id)
            }
            .onAppear {
                for id in nav.pendingOpen { open(id) }
                nav.pendingOpen.removeAll()
            }
    }
    private func open(_ id: String) {
        if id == WindowID.settings { openSettings() } else { openWindow(id: id) }
        NSApp.activate()
    }
}

extension View {
    func hostsWindowOpener() -> some View { modifier(WindowOpenerHost()) }
}

// MARK: - Dock icon state variants

@MainActor
enum DockIcon {
    private static var current: StatusLevel?
    static func update(level: StatusLevel) {
        guard level != current else { return }
        current = level
        let name: String? = switch level {
        case .attention: "actl-icon-attention-1024"
        case .error: "actl-icon-error-1024"
        default: nil
        }
        if let name, let url = Bundle.main.url(forResource: name, withExtension: "png") ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources"), let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        } else {
            NSApp.applicationIconImage = nil
        }
    }
}

// MARK: - Menu commands

struct AppCommands: Commands {
    var nav: Navigation
    var store: AppStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Go") {
            ForEach(Navigation.Screen.allCases) { s in
                if s != .proxy || store.proxyConfigured {
                    Button(s.title) { nav.go(s) }
                }
            }
            Divider()
            Button("Command Palette…") { nav.paletteOpen.toggle() }.keyboardShortcut("k", modifiers: .command)
            Button("Settings…") { WindowOpener.open(WindowID.settings) }
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await store.refreshAll() } }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Review Changes") { nav.go(.review) }.keyboardShortcut("r", modifiers: .command)
        }
    }
}
