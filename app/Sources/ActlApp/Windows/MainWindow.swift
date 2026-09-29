// Main window: source-list sidebar, unified toolbar, one screen at a time, the command palette overlay,
// the undo toast, and the apply sheet hooks.

import ActlCore
import AppKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            ZStack {
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.bg)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .overlay(alignment: .bottom) {
            if let toast = store.toast { ToastView(toast: toast).padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay {
            if nav.paletteOpen { CommandPalette().transition(.opacity) }
        }
        .animation(.snappy(duration: 0.2), value: store.toast?.id)
        .animation(.easeOut(duration: 0.12), value: nav.paletteOpen)
        .hostsWindowOpener()
        .onChange(of: store.signIn?.startedAt) { _, s in if s != nil { openWindow(id: WindowID.signIn) } }
        .onChange(of: nav.screen) { _, s in Runtime.shared.proxyVisible = s == .proxy }
        .onAppear { Runtime.shared.proxyVisible = nav.screen == .proxy }
        .background(WindowAccessor())
    }

    @ViewBuilder
    private var screen: some View {
        switch nav.screen {
        case .home: HomeScreen()
        case .services: ServicesScreen()
        case .skills: SkillsScreen()
        case .instructions: InstructionsScreen()
        case .contextBudget: ContextBudgetScreen()
        case .proxy: ProxyScreen()
        case .review: ReviewScreen()
        case .activity: ActivityScreen()
        }
    }
}

/// Gives the window a stable identifier and lets AppKit-side code find it.
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            if w.identifier == nil { w.identifier = NSUserInterfaceItemIdentifier(WindowID.main) }
            w.titlebarSeparatorStyle = .line
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav

    var body: some View {
        @Bindable var nav = nav
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 10)
            List(selection: $nav.screen) {
                ForEach(mainItems) { s in
                    row(s).tag(s)
                }
                Section {
                    row(.review).tag(Navigation.Screen.review)
                    row(.activity).tag(Navigation.Screen.activity)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            if Runtime.shared.usingFixtures {
                HStack(spacing: 6) {
                    Icon(.blocked, size: 12, color: Palette.fgTertiary)
                    Text("Demo data").font(Type.xs(.medium)).foregroundStyle(Palette.fgTertiary)
                }
                .padding(.horizontal, 16).padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Running on fixtures (ACTL_FIXTURES=1). No engine is called.")
            }
            manifestFooter
        }
        .background(.clear)
    }

    private var mainItems: [Navigation.Screen] {
        var items: [Navigation.Screen] = [.home, .services, .skills, .instructions, .contextBudget]
        if store.proxyConfigured { items.append(.proxy) }
        return items
    }

    private var searchField: some View {
        Button {
            nav.paletteOpen = true
        } label: {
            HStack(spacing: 6) {
                Icon(.search, size: 12, color: Palette.fgTertiary)
                Text("Search").font(Type.base()).foregroundStyle(Palette.fgTertiary)
                Spacer()
                KeyHint(text: "⌘K")
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Palette.bgSunken.opacity(0.9), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search and commands, Command K")
    }

    private func row(_ s: Navigation.Screen) -> some View {
        HStack(spacing: 8) {
            Icon(s.icon, size: 16, color: s == .review ? Palette.accent : Palette.fgSecondary)
                .frame(width: 16)
            Text(s.title).font(Type.base()).foregroundStyle(s == .review ? Palette.accent : Palette.fg)
            Spacer()
            trailing(s)
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailing(_ s: Navigation.Screen) -> some View {
        switch s {
        case .services:
            if let n = store.services.value?.count { count(n) }
        case .skills:
            if store.skillsPending > 0 { count(store.skillsPending) }
        case .proxy:
            let cool = store.proxy.value?.accounts.filter { $0.state == .cooldown }.count ?? store.status.value?.proxy?.accounts.filter { $0.state == .cooldown }.count ?? 0
            if cool > 0 { count(cool) }
        case .review:
            if store.planCount > 0 {
                Text("\(store.planCount)").font(Type.xs(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Palette.accent, in: Capsule())
                    .accessibilityLabel("\(store.planCount) changes to review")
            }
        default: EmptyView()
        }
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)").font(Type.xs()).foregroundStyle(Palette.fgTertiary)
    }

    private var manifestFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: "Manifest")
            Text(store.manifestPath).font(Type.mono(11)).foregroundStyle(Palette.fgSecondary).lineLimit(1).truncationMode(.middle)
                .help(store.manifestPath)
            Text(footerLine).font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contextMenu {
            Button("Reveal in Finder") { External.revealInFinder(store.manifestPath) }
            Button("Open in Terminal") { External.openInTerminal(store.manifestPath) }
        }
    }

    private var footerLine: String {
        if store.plan.value?.manifestExists == false { return "Not adopted yet" }
        if let at = store.plan.loadedAt { return "Checked \(Fmt.time(at)) · every 30 min" }
        return "Checked every 30 min"
    }
}

// MARK: - Toast

struct ToastView: View {
    @Environment(AppStore.self) private var store
    var toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Icon(toast.isError ? .failed : .connected, size: 16, color: toast.isError ? Palette.error : Palette.ok)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(Type.base(.medium)).foregroundStyle(Palette.fg)
                if let d = toast.detail { Text(d).font(Type.xs()).foregroundStyle(Palette.fgSecondary) }
            }
            if let run = toast.undoRunId {
                Button("Undo") { store.toast = nil; store.undo(runId: run) }.controlSize(.small)
            }
            Button {
                store.toast = nil
            } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.fgTertiary) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Screen chrome shared by every screen

/// Title row: "Services · 16" plus a subtitle in the toolbar area, with trailing controls.
struct ScreenHeader<Trailing: View>: View {
    var title: String
    var count: Int?
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(Type.md(.semibold)).foregroundStyle(Palette.fg)
                if let count { Text("· \(Fmt.int(count))").font(Type.md(.semibold)).foregroundStyle(Palette.fg) }
            }
            if let subtitle { Text(subtitle).font(Type.base()).foregroundStyle(Palette.fgTertiary).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 12)
            trailing
        }
        .frame(height: 52)
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Segmented filter that matches the design's pill switcher.
struct FilterSwitcher<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { opt in
                Button {
                    selection = opt.0
                } label: {
                    Text(opt.1).font(Type.sm(.medium))
                        .foregroundStyle(selection == opt.0 ? Palette.fg : Palette.fgSecondary)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(selection == opt.0 ? Palette.bg : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(selection == opt.0 ? Palette.border : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == opt.0 ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.bgSunken, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
