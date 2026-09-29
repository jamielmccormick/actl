// The menu bar item: template glyph per status level (syncing alternates two frames, honouring
// Reduce Motion) and the popover, which is an inbox: two harness counts, then what needs you.

import ActlCore
import AppKit
import SwiftUI

@MainActor
enum MenuBarGlyph {
    static func image(for level: StatusLevel, frame2: Bool = false) -> NSImage? {
        let name: String = switch level {
        case .healthy: "menubar-healthy"
        case .attention: "menubar-attention"
        case .error: "menubar-error"
        case .syncing: frame2 ? "menubar-syncing-frame2" : "menubar-syncing"
        }
        guard let img = IconCache.image(name, subdirectory: "glyphs") else { return nil }
        img.size = NSSize(width: 18, height: 18)
        return img
    }
}

struct MenuBarLabel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame2 = false
    @State private var ticker: Task<Void, Never>?

    var body: some View {
        let level = store.level
        HStack(spacing: 4) {
            if let img = MenuBarGlyph.image(for: level, frame2: frame2 && !reduceMotion) {
                Image(nsImage: img).renderingMode(.template)
            } else {
                Image(systemName: "circle.circle")
            }
            if let text = trailingText(level) {
                Text(text)
            }
        }
        .accessibilityLabel("actl: \(level.word)")
        .onChange(of: level, initial: true) { _, new in
            ticker?.cancel()
            frame2 = false
            guard new == .syncing, !reduceMotion else { return }
            ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(900))
                    frame2.toggle()
                }
            }
        }
        .onChange(of: level) { _, new in DockIcon.update(level: new) }
    }

    private func trailingText(_ level: StatusLevel) -> String? {
        guard store.preferences.showMenuBarCount else { return nil }
        switch level {
        case .attention:
            let n = store.attentionCount
            return n > 0 ? "\(n)" : nil
        case .error:
            if let s = store.status.value {
                if let h = s.harnesses.first(where: { $0.total > 0 && $0.connected == 0 }) { return "\(h.name) down" }
                if let e = s.attention.first(where: { $0.severity == .error }) { return shortCause(e) }
            }
            return store.engineError != nil ? "engine" : nil
        default:
            return nil
        }
    }

    private func shortCause(_ item: AttentionItem) -> String {
        // "2 Claude servers failed" → "2 failed"
        let words = item.title.split(separator: " ")
        if let n = words.first, Int(n) != nil, let last = words.last { return "\(n) \(last)" }
        return String(item.title.prefix(18))
    }
}

// MARK: - Popover

struct PopoverView: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @State private var confirming: String?
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            header
            harnessCounts
            if store.engineError != nil, store.status.value == nil {
                engineErrorBlock
            } else {
                attention
            }
            if store.proxyConfigured, let accounts = proxyRows, !accounts.isEmpty {
                proxySection(accounts)
            }
            footer
        }
        .background(Palette.bg.opacity(0.001))
        .hostsWindowOpener()
        .onAppear { Runtime.shared.popoverOpened(); now = Date() }
        .onDisappear { Runtime.shared.popoverVisible = false }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // Header: icon, wordmark, checked time, level pill.
    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("actl").font(Type.md(.semibold)).tracking(-0.45).foregroundStyle(Palette.fg)
                Text(checkedText).font(Type.xs()).foregroundStyle(Palette.fgTertiary)
            }
            Spacer(minLength: 8)
            StatusPill(level: store.level)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    private var checkedText: String {
        if store.status.isLoading && store.status.value == nil { return "Checking…" }
        if let d = store.status.value?.checkedDate { return "Checked \(Fmt.relative(d, now: now))" }
        if let d = store.status.loadedAt { return "Checked \(Fmt.relative(d, now: now))" }
        return "Not checked yet"
    }

    // Two (or n) harness cards.
    private var harnessCounts: some View {
        let hs = store.status.value?.harnesses ?? store.managedHarnesses.map { StatusHarness(id: $0.id, name: $0.name, connected: 0, total: 0, needsSignIn: 0, failed: 0) }
        return Group {
            if hs.count > 3 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(hs) { harnessCard($0) }
                }
            } else {
                HStack(spacing: 8) { ForEach(hs) { harnessCard($0) } }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func harnessCard(_ h: StatusHarness) -> some View {
        let slot = store.colorSlot(for: h.id)
        let loading = store.status.value == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HarnessDot(slot: slot)
                Text(h.name.uppercased()).font(Type.xs(.semibold)).tracking(0.44).foregroundStyle(Palette.fgSecondary).lineLimit(1)
            }
            if loading {
                SkeletonLine(width: 72, height: 20).padding(.vertical, 2)
                SkeletonLine(width: 96, height: 11)
            } else {
                Text("\(h.connected) of \(h.total)").font(Type.lg()).tracking(-0.4).foregroundStyle(Palette.fg)
                harnessStatusLine(h)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card(radius: 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func harnessStatusLine(_ h: StatusHarness) -> some View {
        if h.total == 0 {
            StatusLabel(icon: .blocked, word: "No services", color: Palette.fgTertiary, font: Type.xs(.medium), iconSize: 12)
        } else if h.needsSignIn == 0 && h.failed == 0 && h.connected == h.total {
            StatusLabel(icon: .connected, word: "All connected", color: Palette.ok, font: Type.xs(.medium), iconSize: 12)
        } else {
            var parts: [String] = []
            let _ = { if h.needsSignIn > 0 { parts.append("\(h.needsSignIn) need sign-in") }; if h.failed > 0 { parts.append("\(h.failed) failed") } }()
            let other = h.total - h.connected - h.needsSignIn - h.failed
            let _ = { if other > 0 { parts.append("\(other) blocked") } }()
            StatusLabel(icon: h.failed > 0 ? .failed : .warn, word: parts.joined(separator: " · "), color: h.failed > 0 ? Palette.error : Palette.warn, font: Type.xs(.medium), iconSize: 12)
        }
    }

    private var engineErrorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            InlineError(message: store.engineError ?? "", retry: { Task { await store.bootstrap() } })
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    // The attention inbox.
    @ViewBuilder
    private var attention: some View {
        let items = (store.status.value?.attention ?? []).orderedByBlocking()
        VStack(spacing: 0) {
            if items.isEmpty {
                if store.status.value == nil {
                    ForEach(0..<3, id: \.self) { _ in skeletonRow }
                } else {
                    calmConfirmation
                }
            } else {
                HStack {
                    SectionLabel(text: "Needs attention · \(items.count)")
                    Spacer()
                    Button("Review all") { openMain(.review) }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent)
                }
                .padding(.horizontal, 4).padding(.vertical, 6)
                ForEach(Array(items.prefix(6))) { item in
                    Hairline()
                    attentionRow(item)
                }
                if items.count > 6 {
                    Hairline()
                    Button("\(items.count - 6) more in Home") { openMain(.home) }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent).padding(.vertical, 6)
                }
                Hairline()
            }
        }
        .padding(.horizontal, 12)
    }

    private var skeletonRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.bgSunken).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) { SkeletonLine(width: 180, height: 12); SkeletonLine(width: 120, height: 10) }
            Spacer()
            SkeletonLine(width: 56, height: 22)
        }
        .padding(.horizontal, 4).padding(.vertical, 8)
    }

    private var calmConfirmation: some View {
        VStack(spacing: 6) {
            Icon(.connected, size: 20, color: Palette.ok)
            Text("Both harnesses match the manifest").font(Type.base(.medium)).foregroundStyle(Palette.fg)
            Text(nextCheckText).font(Type.xs()).foregroundStyle(Palette.fgTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }

    private var nextCheckText: String {
        if let at = store.lastInventoryAt {
            let mins = max(0, Int((30 * 60 - now.timeIntervalSince(at)) / 60))
            return "Next check in \(mins) min"
        }
        return "Checks run every 30 min"
    }

    private func attentionRow(_ item: AttentionItem) -> some View {
        let tint = tintFor(item)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(width: 20, height: 20)
                .overlay(Icon(.forAttention(item.kind, severity: item.severity), size: 12, color: tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Type.base(.medium)).foregroundStyle(Palette.fg).lineLimit(1)
                if item.kind == .signIn, let servers = item.fix?.signIn?.servers, !servers.isEmpty {
                    signInMarks(item.fix!.signIn!.harness, servers)
                } else if let d = item.detail {
                    Text(d).font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            actionButton(item)
        }
        .padding(.horizontal, 4).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func tintFor(_ item: AttentionItem) -> Color {
        switch item.kind {
        case .failed: return Palette.error
        case .signIn: return store.harness(item.harness ?? "").map { Palette.harness(store.colorSlot(for: $0.id)) } ?? Palette.warn
        case .sync: return Palette.accent
        case .drift, .quota: return Palette.warn
        case .update, .gap, .other: return Palette.fgSecondary
        }
    }

    private func signInMarks(_ harness: HarnessId, _ servers: [String]) -> some View {
        let services = store.services.value ?? []
        let marks: [Service] = servers.compactMap { s in services.first { $0.providers[harness]?.serverName == s || $0.providers[harness]?.ref == s || $0.id == s } }
        return HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(marks.prefix(4)) { ServiceMark($0, size: 16) }
            }
            if servers.count > 4 {
                Text("+\(servers.count - 4) more").font(Type.xs()).foregroundStyle(Palette.fgTertiary)
            } else if marks.isEmpty {
                Text(servers.prefix(3).joined(separator: ", ")).font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ item: AttentionItem) -> some View {
        if let fix = item.fix {
            if let s = fix.signIn {
                Button(fix.label) {
                    store.startSignIn(harness: s.harness, servers: s.servers)
                    openWindow(id: WindowID.signIn)
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            } else if let ids = fix.actionIds, !ids.isEmpty {
                if confirming == item.id {
                    HStack(spacing: 4) {
                        Button("Cancel") { confirming = nil }.controlSize(.small)
                        Button(applyVerb(item)) { confirming = nil; store.apply(actionIds: ids); openMain(.review) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                } else {
                    Button(fix.label) { withAnimation(.snappy(duration: 0.18)) { confirming = item.id } }.controlSize(.small)
                }
            } else {
                Button(fix.label) { openMain(detailScreen(item)) }.controlSize(.small)
            }
        } else {
            Button("Details") { openMain(detailScreen(item)) }.controlSize(.small)
        }
    }

    private func applyVerb(_ item: AttentionItem) -> String {
        switch item.kind {
        case .sync: return "Sync now"
        case .update: return "Update"
        default: return "Apply"
        }
    }

    private func detailScreen(_ item: AttentionItem) -> Navigation.Screen {
        switch item.kind {
        case .failed, .signIn, .gap: return .services
        case .sync: return .skills
        case .drift: return .contextBudget
        case .quota, .update: return store.proxyConfigured ? .proxy : .home
        case .other: return .home
        }
    }

    // Proxy accounts (only when configured).
    private var proxyRows: [ProxyAccount]? {
        if let p = store.proxy.value { return p.accounts }
        if let s = store.status.value?.proxy {
            return s.accounts.map { ProxyAccount(email: $0.label, status: $0.state.rawValue, unavailable: $0.state == .cooldown, nextRetryAfter: $0.retryAt) }
        }
        return nil
    }

    private func proxySection(_ accounts: [ProxyAccount]) -> some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Proxy accounts · last 3 h")
                Spacer()
                if let c = store.proxy.value?.config {
                    Text([c.strategy, c.sessionAffinity.map { "affinity \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(Type.xs()).foregroundStyle(Palette.fgTertiary)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
            ForEach(accounts) { a in
                Hairline()
                proxyRow(a)
            }
            Hairline()
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func proxyRow(_ a: ProxyAccount) -> some View {
        let slot = store.colorSlot(for: a.provider ?? "")
        let color = Palette.harness(slot)
        let cooldown = a.state == .cooldown
        return HStack(spacing: 8) {
            HarnessDot(slot: slot)
            Text(a.displayLabel).font(Type.sm()).foregroundStyle(Palette.fg).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
            Sparkline(values: a.recent.map { Double($0.success + $0.failed) }, color: cooldown ? Palette.fgTertiary : color, dashed: cooldown)
                .frame(width: 44, height: 18)
            Spacer(minLength: 4)
            Text(cooldown ? retryText(a) : "\(Fmt.int(a.success)) · \(a.failed) failed")
                .font(Type.xs()).foregroundStyle(Palette.fgSecondary).lineLimit(1).fixedSize()
            Text(stateWord(a.state)).font(Type.xs(.medium)).foregroundStyle(stateColor(a.state)).frame(width: 54, alignment: .trailing).fixedSize()
            if cooldown {
                Menu {
                    Button("Open Proxy accounts") { openMain(.proxy) }
                    Button("Retry now") {}.disabled(true)
                    Button("Re-auth…") {}.disabled(true)
                } label: {
                    Icon(.more, size: 12, color: Palette.fg)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.borderStrong, lineWidth: 1))
                .help("Proxy writes are coming soon")
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(a.displayLabel), \(stateWord(a.state)), \(a.success) ok, \(a.failed) failed")
    }

    private func retryText(_ a: ProxyAccount) -> String {
        if let r = a.nextRetryAfter, let d = ISO8601.parse(r) { return "retry \(Fmt.monthDayTime(d))" }
        return "retry later"
    }

    private func stateWord(_ s: ProxyAccountState) -> String {
        switch s { case .active: return "Active"; case .cooldown: return "Cooldown"; case .disabled: return "Paused"; case .error: return "Error" }
    }

    private func stateColor(_ s: ProxyAccountState) -> Color {
        switch s { case .active: return Palette.ok; case .cooldown: return Palette.warn; case .disabled: return Palette.fgTertiary; case .error: return Palette.error }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openMain(nav.screen)
            } label: {
                HStack(spacing: 6) { Text("Open actl"); KeyHint(text: "⌘O") }
            }
            .keyboardShortcut("o", modifiers: .command)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(Type.sm()).foregroundStyle(Palette.fgTertiary)
                .keyboardShortcut("q", modifiers: .command)
            Button {
                openMain(.review)
            } label: {
                HStack(spacing: 6) {
                    Text(store.planCount > 0 ? "Review \(store.planCount) change\(store.planCount == 1 ? "" : "s")" : "Review changes")
                    KeyHint(text: "⌘R").foregroundStyle(.white.opacity(0.7))
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(12)
    }

    private func openMain(_ screen: Navigation.Screen) {
        nav.go(screen)
        WindowOpener.open(WindowID.main)
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

/// The app icon at small sizes (from the bundle's .icns, or the PNG ladder in dev).
struct AppIconView: View {
    var size: CGFloat
    var body: some View {
        Group {
            if let img = AppIconView.image {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Palette.fg)
                    .overlay(Circle().fill(Color(nsColor: NSColor(hex: 0xF4EFE2))).frame(width: size * 0.3))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @MainActor static let image: NSImage? = {
        if Bundle.main.bundleURL.pathExtension == "app" { return NSApp.applicationIconImage }
        // Dev run from the repo: use the brand PNG if it can be found next to the checkout.
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        for up in ["../../../design/brand/actl-icon-256.png", "../../design/brand/actl-icon-256.png"] {
            if let u = exe?.appendingPathComponent(up).standardizedFileURL, let i = NSImage(contentsOf: u) { return i }
        }
        return nil
    }()
}
