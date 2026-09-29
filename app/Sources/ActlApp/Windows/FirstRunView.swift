// First run: four calm steps. Detect harnesses and repos, optional integrations,
// adopt the current setup (changes nothing else), then open at login and the menu bar.

import ActlCore
import SwiftUI

struct FirstRunView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var step = 1
    @State private var proxyOn = true
    @State private var argentOn = true
    @State private var skillsSync = false
    @State private var openAtLogin = true
    @State private var menuBar = true
    @State private var weekly = false
    @State private var adopted: ManifestInfo?
    @State private var adopting = false
    @State private var scan = ConfigFile.load()
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    if step == 1 { AppIconView(size: 32) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Step \(step) of 4").font(Type.xs()).foregroundStyle(Palette.fgTertiary)
                        Text(title).font(Type.md()).foregroundStyle(Palette.fg)
                    }
                }
            }
            Group {
                switch step {
                case 1: harnesses
                case 2: repos
                case 3: integrations
                default: ready
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if step > 1 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 4 {
                    Button("Continue") { step += 1 }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(adopted == nil ? "Adopt and open actl" : "Open actl") { finish() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(adopting)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Palette.bg)
        .onAppear { proxyOn = store.proxyConfigured; argentOn = store.preferences.argentEnabled }
        .onChange(of: store.proxyConfigured) { _, v in proxyOn = v }

    }

    private var title: String {
        switch step { case 1: "Your harnesses"; case 2: "Repos and folders"; case 3: "Optional integrations"; default: "Ready" }
    }

    // Step 1
    private var harnesses: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("actl looked at this Mac. It manages the harnesses it fully understands and keeps an eye on the rest.").font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                Hairline()
                if store.inventory.value == nil && store.status.value == nil {
                    ForEach(0..<3, id: \.self) { _ in HStack { SkeletonLine(width: 120); Spacer(); SkeletonLine(width: 70) }.frame(height: 34); Hairline() }
                } else {
                    ForEach(store.harnesses.filter { $0.installed || $0.supported }) { h in
                        HStack(spacing: 8) {
                            if h.supported && h.installed { HarnessDot(slot: store.colorSlot(for: h.id)) } else { RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.borderStrong).frame(width: 8, height: 8) }
                            Text(h.name).font(Type.base()).foregroundStyle(h.installed ? Palette.fg : Palette.fgTertiary)
                            Spacer()
                            if let v = h.version { Text(v).font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
                            if h.supported && h.installed { StatusLabel(icon: .connected, word: "Managed", color: Palette.ok, font: Type.sm(.medium), iconSize: 13) }
                            else if h.installed { Text("Detected").font(Type.sm()).foregroundStyle(Palette.fgSecondary) }
                            else { Text("Not found").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
                        }
                        .frame(height: 34)
                        Hairline()
                    }
                }
            }
            Text("Detected harnesses show in the sidebar as read-only until support lands. Nothing is written to any of them.").font(Type.xs()).foregroundStyle(Palette.fgTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // Step 2
    private var repos: some View {
        let repos = store.inventory.value?.repos ?? []
        let roots = scan.roots.isEmpty ? (store.inventory.value?.config?.scanRoots ?? []) : scan.roots
        let history = repos.filter { r in !roots.contains { r.path.hasPrefix($0) } }
        return VStack(alignment: .leading, spacing: 12) {
            Text(repos.isEmpty ? "actl scans your code folders and the projects your harnesses already opened." : "Found \(repos.count) repo\(repos.count == 1 ? "" : "s") in your code folders and in projects the harnesses already opened.").font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                Hairline()
                ForEach(roots, id: \.self) { root in
                    HStack(spacing: 8) {
                        Icon(.reveal, size: 14, color: Palette.fgSecondary)
                        Text(root).font(Type.mono(12)).foregroundStyle(Palette.fg)
                        Spacer()
                        Text("\(repos.filter { $0.path.hasPrefix(root) }.count) repos").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
                        Button { scan.roots.removeAll { $0 == root }; saveScan() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.fgTertiary) }.buttonStyle(.plain).accessibilityLabel("Remove \(root)")
                    }
                    .frame(height: 30)
                    Hairline()
                }
                Button {
                    addFolder()
                } label: { HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)); Text("Add a folder…") }.font(Type.sm()).foregroundStyle(Palette.accent) }
                    .buttonStyle(.plain).frame(height: 30)
                Hairline()
            }
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Also from harness history")
                    Text(history.prefix(4).map(\.name).joined(separator: " · ")).font(Type.mono(12)).foregroundStyle(Palette.fgSecondary).lineLimit(2)
                }
            }
            Text("Main checkouts only; linked worktrees and .venv folders are skipped.").font(Type.xs()).foregroundStyle(Palette.fgTertiary)
        }
    }

    // Step 3
    private var integrations: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Off unless already on this Mac. Each adds a section to the sidebar; turn them on later in Settings.").font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                Hairline()
                integrationRow("CLIProxyAPI subscription pool", detail: store.proxyConfigured ? "Detected on \(store.proxy.value?.endpoint ?? "127.0.0.1:8317") · \(store.proxy.value?.accounts.count ?? 0) accounts · adds Proxy accounts" : "Not detected · adds Proxy accounts when it is", on: $proxyOn)
                integrationRow("Argent (simulator tooling)", detail: "Watches its rule scope so an update can't quietly make it always-on", on: $argentOn)
                integrationRow("Skills sync to ~/.claude/skills", detail: "Copies, never symlinks · hash manifest · conflicts are never overwritten", on: $skillsSync)
            }
        }
    }

    private func integrationRow(_ title: String, detail: String, on: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: on).toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel(title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Type.base()).foregroundStyle(Palette.fg)
                    Text(detail).font(Type.xs()).foregroundStyle(Palette.fgTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
            Hairline()
        }
    }

    // Step 4
    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(store.managedHarnesses.count) harness\(store.managedHarnesses.count == 1 ? "" : "es") · \(store.inventory.value?.repos.count ?? 0) repos").font(Type.md()).foregroundStyle(Palette.fg)
                Text([store.services.value.map { "\($0.count) services" }, store.inventory.value.map { "\($0.skills.count) skills" }, store.inventory.value.map { "\($0.instructions.count) instruction files" }].compactMap { $0 }.joined(separator: " · ")).font(Type.sm()).foregroundStyle(Palette.fgSecondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.bgSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            HStack(spacing: 8) {
                if adopting { ProgressView().controlSize(.small) } else if adopted != nil { Icon(.connected, size: 14, color: Palette.ok) }
                Text(adopted == nil ? (adopting ? "Adopting your current setup as the manifest…" : "Your current setup becomes the starting manifest, exactly as it is (actl manifest adopt). Nothing else on disk changes until you review a plan and press Apply.") : (adopted!.created == true ? "Adopted. The manifest records your setup exactly as it is; nothing else changed." : "A manifest already exists; kept as is."))
                    .font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                Hairline()
                checkRow("Open at login", $openAtLogin)
                checkRow("Show actl in the menu bar", $menuBar)
                checkRow("Check for updates weekly", $weekly)
            }
            if let loginError { Text(loginError).font(Type.xs()).foregroundStyle(Palette.error) }
            Text(adopted?.path ?? store.manifestPath).font(Type.mono(11)).foregroundStyle(Palette.fgTertiary)
        }
    }

    private func checkRow(_ title: String, _ on: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Toggle(isOn: on) { Text(title).font(Type.base()).foregroundStyle(Palette.fg) }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).frame(height: 34)
            Hairline()
        }
    }

    private func adopt() async {
        adopting = true
        adopted = await store.adoptManifest()
        adopting = false
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var p = url.path
            if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
            if !scan.roots.contains(p) { scan.roots.append(p); saveScan() }
        }
    }

    private func saveScan() {
        do { try ConfigFile.save(scan) } catch { store.showToast(Toast(title: "Could not write config.toml", detail: error.localizedDescription, isError: true)) }
        Task { await store.refreshInventory(force: true) }
    }

    private func finish() {
        if adopted == nil, store.manifest?.exists != true {
            Task { await adopt(); if adopted != nil { finish() } }
            return
        }
        store.preferences.argentEnabled = argentOn
        store.preferences.proxyEnabled = proxyOn ? nil : false
        store.preferences.showMenuBarCount = menuBar
        if openAtLogin, LoginItem.isAvailable { loginError = LoginItem.set(true) }
        Task { _ = await NotificationBridge.shared.requestPermission() }
        store.preferences.firstRunCompleted = true
        dismiss()
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}
