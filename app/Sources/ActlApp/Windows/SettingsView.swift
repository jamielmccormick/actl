// Settings: General, Harnesses, Scan folders, Integrations, About.

import ActlCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            HarnessSettings().tabItem { Label("Harnesses", systemImage: "square.grid.2x2") }
            FoldersSettings().tabItem { Label("Folders", systemImage: "folder") }
            IntegrationsSettings().tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 720)
        .background(Palette.bg)
    }
}

/// Label column at a fixed edge, values in ink, one hairline per row.
struct SettingRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(label).font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(width: 150, alignment: .leading)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 36)
            Hairline()
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppStore.self) private var store
    @State private var loginOn = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var interval = 5

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "General").padding(.bottom, 8)
            SettingRow(label: "Config file") {
                HStack {
                    Text(ConfigFile.defaultPath.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(Type.mono(12)).foregroundStyle(Palette.fg)
                    Spacer()
                    Button("Reveal") { External.revealInFinder(ConfigFile.defaultPath.path) }.buttonStyle(.plain).font(Type.sm(.medium)).foregroundStyle(Palette.accent)
                }
            }
            SettingRow(label: "Manifest") {
                HStack {
                    Text(store.manifestPath).font(Type.mono(12)).foregroundStyle(Palette.fg)
                    Spacer()
                    if store.plan.value?.manifestExists == false {
                        Button("Adopt current setup") { Task { _ = await store.adoptManifest() } }.controlSize(.small)
                    } else if let at = store.plan.loadedAt {
                        Text("checked \(Fmt.time(at))").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
                    }
                }
            }
            SettingRow(label: "Open at login") {
                HStack(spacing: 10) {
                    Toggle("", isOn: $loginOn).toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(!LoginItem.isAvailable)
                        .onChange(of: loginOn) { _, on in loginError = LoginItem.set(on); if loginError != nil { loginOn = LoginItem.isEnabled } }
                        .accessibilityLabel("Open at login")
                    Text(LoginItem.isAvailable ? (loginError ?? "Runs as a menu bar item; the window opens on demand") : "Available when running from actl.app").font(Type.sm()).foregroundStyle(loginError == nil ? Palette.fgSecondary : Palette.error)
                }
            }
            SettingRow(label: "Menu bar item") {
                HStack(spacing: 10) {
                    Toggle("", isOn: $store.preferences.showMenuBarCount).toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel("Show attention count next to the glyph")
                    Text("Show attention count next to the glyph").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
                }
            }
            SettingRow(label: "Sign-in queue") {
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { store.preferences.autoContinueSignIn }, set: { store.setSignInAutoContinue($0) })).toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel("Continue to the next sign-in automatically")
                    Text("Continue to the next sign-in automatically").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
                }
            }
            SettingRow(label: "Re-check every") {
                HStack(spacing: 10) {
                    Text("30 minutes").font(Type.sm()).foregroundStyle(Palette.fg)
                    Text("Health checks run `claude mcp list` and `codex mcp list`; about 5–10 s. Files refresh within a second.").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(height: 380)
    }
}

struct HarnessSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Harnesses")
                Spacer()
                Button("Reset order") { store.preferences.harnessColorOverrides = [:] }.controlSize(.small).disabled(store.preferences.harnessColorOverrides.isEmpty)
            }
            .padding(.bottom, 8)
            Hairline()
            ForEach(store.harnesses) { h in
                HStack(spacing: 12) {
                    Button {
                        let slot = store.colorSlot(for: h.id)
                        store.preferences.harnessColorOverrides[h.id] = (slot + 1) % HarnessPalette.hues.count
                    } label: {
                        HarnessChip(harness: h, slot: store.colorSlot(for: h.id), size: 18)
                    }
                    .buttonStyle(.plain)
                    .help("Click to cycle through the six harness colours (\(HarnessPalette.names[store.colorSlot(for: h.id) % 6]))")
                    .accessibilityLabel("\(h.name) colour: \(HarnessPalette.names[store.colorSlot(for: h.id) % 6]). Click to change.")
                    Text(h.name).font(Type.base()).foregroundStyle(h.installed ? Palette.fg : Palette.fgTertiary).frame(width: 140, alignment: .leading)
                    Text(h.version ?? "").font(Type.sm()).foregroundStyle(Palette.fgSecondary).frame(width: 80, alignment: .leading)
                    Text(h.home ?? "").font(Type.mono(11)).foregroundStyle(Palette.fgSecondary).lineLimit(1)
                    Spacer()
                    if h.supported && h.installed { StatusLabel(icon: .connected, word: "Managed", color: Palette.ok) }
                    else if h.installed { Text("Detected · support coming").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
                    else { Text("Not found").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
                }
                .frame(height: 36)
                Hairline()
            }
            Text("Every harness gets its own colour chip and lane. Colours come from six OKLCH hues at equal lightness, so none shouts and colour is never the only cue: the two-letter code is always drawn. Columns, bars and switchers are built for n harnesses.").font(Type.xs()).foregroundStyle(Palette.fgTertiary).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
        .frame(height: 380)
    }
}

struct FoldersSettings: View {
    @Environment(AppStore.self) private var store
    @State private var scan = ConfigFile.load()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Scan folders").padding(.bottom, 4)
            Text("Code folders are walked for git checkouts; workspace folders hold children with AGENTS.md or CLAUDE.md. Projects your harnesses opened are always included. Saved to \(ConfigFile.defaultPath.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) under [scan].").font(Type.xs()).foregroundStyle(Palette.fgTertiary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            list("Code folders (roots)", $scan.roots, defaultsNote: scan.roots.isEmpty ? "Using defaults: ~/Code, ~/Developer, ~/Projects, ~/src, whichever exist" : nil)
            list("Workspace folders", $scan.workspaces, defaultsNote: scan.workspaces.isEmpty ? "None" : nil).padding(.top, 16)
            if let error { Text(error).font(Type.xs()).foregroundStyle(Palette.error).padding(.top, 8) }
            Spacer()
        }
        .padding(24)
        .frame(height: 380)
    }

    private func list(_ title: String, _ items: Binding<[String]>, defaultsNote: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(Type.sm(.medium)).foregroundStyle(Palette.fg)
                Spacer()
                Button("Add folder…") { add(to: items) }.controlSize(.small)
            }
            .frame(height: 28)
            Hairline()
            ForEach(items.wrappedValue, id: \.self) { p in
                HStack(spacing: 8) {
                    Icon(.reveal, size: 14, color: Palette.fgSecondary)
                    Text(p).font(Type.mono(12)).foregroundStyle(Palette.fg)
                    Spacer()
                    Button { items.wrappedValue.removeAll { $0 == p }; save() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.fgTertiary) }.buttonStyle(.plain).accessibilityLabel("Remove \(p)")
                }
                .frame(height: 28)
                Hairline()
            }
            if let defaultsNote { Text(defaultsNote).font(Type.xs()).foregroundStyle(Palette.fgTertiary).frame(height: 28) }
        }
    }

    private func add(to items: Binding<[String]>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in panel.urls {
            var p = url.path
            if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
            if !items.wrappedValue.contains(p) { items.wrappedValue.append(p) }
        }
        save()
    }

    private func save() {
        do { try ConfigFile.save(scan); error = nil } catch { self.error = "Could not write config.toml: \(error.localizedDescription)" }
        Task { await store.refreshInventory(force: true) }
    }
}

struct IntegrationsSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Integrations").padding(.bottom, 8)
            Hairline()
            HStack(alignment: .top, spacing: 12) {
                Toggle("", isOn: Binding(get: { store.preferences.proxyEnabled != false }, set: { store.preferences.proxyEnabled = $0 ? nil : false; if $0 { Task { await store.refreshProxy() } } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel("CLIProxyAPI")
                VStack(alignment: .leading, spacing: 2) {
                    Text("CLIProxyAPI").font(Type.base(.medium)).foregroundStyle(Palette.fg)
                    Text(proxyLine).font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
            Hairline()
            HStack(alignment: .top, spacing: 12) {
                Toggle("", isOn: $store.preferences.argentEnabled).toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel("Argent")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Argent").font(Type.base(.medium)).foregroundStyle(Palette.fg)
                    Text(argentLine).font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
            Hairline()
            Text("Integrations are off unless detected or enabled, and never required. The proxy's management key stays on disk; only an allowlist of GET routes is called, and one 401 stops further calls.").font(Type.xs()).foregroundStyle(Palette.fgTertiary).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
        .frame(height: 380)
    }

    private var proxyLine: String {
        if let p = store.proxy.value {
            return "\(p.endpoint) · \(p.listening ? "listening" : "not running") · management key \(p.keyConfigured ? "from ~/.cli-proxy-api/management-key" : "not found") · read-only GET allowlist"
        }
        return "Detected automatically on 127.0.0.1:8317 · read-only GET allowlist"
    }

    private var argentLine: String {
        if let lever = store.budget.value?.harnesses["claude"]?.levers.first(where: { $0.label.localizedCaseInsensitiveContains("argent") }) {
            return "Watches ~/.claude/rules/argent.md scope · \(Fmt.int(lever.tokens)) tokens when always-on"
        }
        return "Watches ~/.claude/rules/argent.md scope so an update can't quietly make it always-on"
    }
}

struct AboutSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AppIconView(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("actl").font(Type.lg()).tracking(-0.4).foregroundStyle(Palette.fg)
                    Text("Pronounced \u{201C}actual\u{201D}. The actual state of your coding agents.").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
                }
            }
            VStack(spacing: 0) {
                SettingRow(label: "Version") { Text(versionLine).font(Type.sm()).foregroundStyle(Palette.fg) }
                SettingRow(label: "Engine") { Text(engineLine).font(Type.mono(11)).foregroundStyle(Palette.fg).lineLimit(1).truncationMode(.middle) }
                SettingRow(label: "License") { Text("MIT © Jamie McCormick").font(Type.sm()).foregroundStyle(Palette.fg) }
                SettingRow(label: "Links") {
                    HStack(spacing: 16) {
                        Button("GitHub") { External.open("https://github.com/jamielmccormick/actl") }
                        Button("Docs") { External.open("https://github.com/jamielmccormick/actl/blob/main/docs/mac-app.md") }
                        Button("Check for updates") { External.open("https://github.com/jamielmccormick/actl/releases") }
                    }
                    .buttonStyle(.plain).font(Type.sm(.medium)).foregroundStyle(Palette.accent)
                }
            }
            Text("No telemetry. No network calls except health checks, sign-ins and logo fetches. Secrets never leave the engine process.").font(Type.xs()).foregroundStyle(Palette.fgTertiary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
        .frame(height: 380)
    }

    private var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "actl \(v) (build \(b)) · macOS \(os.majorVersion).\(os.minorVersion)"
    }

    private var engineLine: String {
        if store.isFixtures { return "fixtures (ACTL_FIXTURES=1) · demo data, no engine" }
        if case .success(let loc) = ProcessEngine.locate() { return ([loc.executable.path] + loc.prefixArgs).joined(separator: " ").replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        return "not found"
    }
}
