// ⌘K command palette: actions, services and places, fully keyboard-driven.

import ActlCore
import SwiftUI

struct PaletteItem: Identifiable, Hashable {
    enum Section: String { case actions = "Actions", services = "Services", goTo = "Go to" }
    var id: String
    var section: Section
    var title: String
    var hint: String?
    var iconName: IconName?
    var service: Service?
    var run: @MainActor () -> Void

    static func == (a: PaletteItem, b: PaletteItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct CommandPalette: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.22).ignoresSafeArea().onTapGesture { nav.paletteOpen = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Icon(.search, size: 14, color: Palette.fgTertiary)
                    TextField("Search services, actions and places", text: $query)
                        .textFieldStyle(.plain).font(Type.md(.regular)).foregroundStyle(Palette.fg)
                        .focused($focused)
                        .onSubmit { runCurrent() }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { nav.paletteOpen = false; return .handled }
                    KeyHint(text: "esc").padding(.horizontal, 6).frame(height: 18).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.borderStrong))
                }
                .padding(.horizontal, 16).frame(height: 48)
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sections, id: \.0) { section, list in
                                SectionLabel(text: section.rawValue).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                                ForEach(list) { item in
                                    row(item, selected: flat.firstIndex(of: item) == index).id(item.id)
                                }
                            }
                            if flat.isEmpty {
                                Text("No matches for \u{201C}\(query)\u{201D}.").font(Type.base()).foregroundStyle(Palette.fgTertiary).padding(16)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .frame(height: min(360, CGFloat(flat.count) * 32 + CGFloat(sections.count) * 28 + 12))
                    .onChange(of: index) { _, i in if i < flat.count { proxy.scrollTo(flat[i].id, anchor: .center) } }
                }
                Hairline()
                HStack(spacing: 14) {
                    KeyHint(text: "↑↓ move")
                    KeyHint(text: "↩ run")
                    KeyHint(text: "⌘↩ add to plan instead")
                    Spacer()
                    KeyHint(text: "⌘K anywhere, even from the menu bar")
                }
                .padding(.horizontal, 16).frame(height: 32)
            }
            .frame(width: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 96)
        }
        .onAppear { focused = true; index = 0 }
        .onChange(of: query) { _, _ in index = 0 }
    }

    private func move(_ d: Int) {
        guard !flat.isEmpty else { return }
        index = (index + d + flat.count) % flat.count
    }

    private func runCurrent() {
        guard index < flat.count else { return }
        flat[index].run()
        nav.paletteOpen = false
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if let s = item.service { ServiceMark(s, size: 20) } else if let i = item.iconName { Icon(i, size: 16, color: selected ? .white : Palette.fgSecondary).frame(width: 20) } else { Color.clear.frame(width: 20, height: 20) }
            Text(item.title).font(Type.base(.medium)).foregroundStyle(selected ? .white : Palette.fg).lineLimit(1)
            Spacer()
            if let h = item.hint { Text(h).font(Type.xs()).foregroundStyle(selected ? .white.opacity(0.8) : Palette.fgTertiary) }
            if item.section == .services, let s = item.service { serviceStatus(s, selected: selected) }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(selected ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { item.run(); nav.paletteOpen = false }
        .onHover { if $0, let i = flat.firstIndex(of: item) { index = i } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func serviceStatus(_ s: Service, selected: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(store.managedHarnesses) { h in
                if let p = s.providers[h.id] {
                    HStack(spacing: 5) {
                        HarnessDot(slot: store.colorSlot(for: h.id))
                        Text(p.health.word).font(Type.xs(.medium)).foregroundStyle(selected ? .white : Palette.health(p.health))
                    }
                }
            }
        }
    }

    // MARK: Items

    private var all: [PaletteItem] {
        var out: [PaletteItem] = []
        let services = store.services.value ?? []
        for s in services {
            for h in store.managedHarnesses {
                if let p = s.providers[h.id], p.canSignIn, p.health == .needsAuth {
                    out.append(PaletteItem(id: "signin:\(h.id):\(s.id)", section: .actions, title: "Sign in to \(s.name) in \(h.name)", hint: "opens browser", service: s) {
                        store.startSignInThenRest(SignInItem(harness: h.id, server: p.serverName ?? p.ref, serviceName: s.name, serviceId: s.id))
                        openWindow(id: WindowID.signIn)
                    })
                }
                if let p = s.providers[h.id], p.lazyAlternative != nil {
                    out.append(PaletteItem(id: "lazy:\(h.id):\(s.id)", section: .actions, title: "Switch \(s.name) in \(h.name.split(separator: " ").first ?? "") to bare MCP", hint: "\u{2212}\(Fmt.int(p.contextTokens ?? 0)) tokens · adds to plan", service: s) {
                        _ = store.planMakeLazy(serviceIds: [s.id]); nav.go(.review)
                    })
                }
            }
        }
        for h in store.managedHarnesses {
            let c = store.signInCandidates(harness: h.id)
            if c.count > 1 {
                out.append(PaletteItem(id: "signin-all:\(h.id)", section: .actions, title: "Sign in to all \(c.count) \(h.name.split(separator: " ").first ?? "") services, back-to-back", hint: "~\(max(1, c.count * 25 / 60)) min", iconName: .signIn) {
                    store.startSignIn(c); openWindow(id: WindowID.signIn)
                })
            }
        }
        if store.planCount > 0 {
            out.append(PaletteItem(id: "apply", section: .actions, title: "Review and apply \(store.planCount) planned changes", hint: "⌘R", iconName: .apply) { nav.go(.review) })
        }
        out.append(PaletteItem(id: "recheck", section: .actions, title: "Re-check both harnesses", hint: "runs claude mcp list", iconName: .syncing) { Task { await store.refreshAll() } })
        out.append(PaletteItem(id: "adopt", section: .actions, title: "Adopt current setup as the manifest", hint: store.plan.value?.manifestExists == true ? "already adopted" : nil, iconName: .instructions) { Task { _ = await store.adoptManifest() } })
        for s in services {
            out.append(PaletteItem(id: "svc:\(s.id)", section: .services, title: s.name, service: s) { nav.go(.services, service: s.id) })
        }
        for screen in Navigation.Screen.allCases where screen != .proxy || store.proxyConfigured {
            out.append(PaletteItem(id: "go:\(screen.rawValue)", section: .goTo, title: screen.title, iconName: screen.icon) { nav.go(screen) })
        }
        if let b = store.budget.value {
            for (h, hb) in b.harnesses {
                for l in hb.levers.prefix(12) {
                    out.append(PaletteItem(id: "budget:\(h):\(l.id)", section: .goTo, title: "Context budget · \(store.harness(h)?.name.split(separator: " ").first.map(String.init) ?? h) · \(l.label)", hint: "\(Fmt.int(l.tokens)) tokens", iconName: .contextBudget) { nav.go(.contextBudget) })
                }
            }
        }
        out.append(PaletteItem(id: "settings", section: .goTo, title: "Settings", hint: "⌘,", iconName: .settings) { WindowOpener.open(WindowID.settings) })
        return out
    }

    private var flat: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered: [PaletteItem] = q.isEmpty
            ? all.filter { $0.section != .services || $0.service?.needsAttention == true }.prefix(18).map { $0 }
            : all.compactMap { item in matchScore(item.title.lowercased(), q).map { (item, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
        let order: [PaletteItem.Section] = [.actions, .services, .goTo]
        return order.flatMap { sec in filtered.filter { $0.section == sec } }
    }

    private var sections: [(PaletteItem.Section, [PaletteItem])] {
        let order: [PaletteItem.Section] = [.actions, .services, .goTo]
        return order.compactMap { sec in
            let items = flat.filter { $0.section == sec }
            return items.isEmpty ? nil : (sec, items)
        }
    }

    /// The last query word (the noun being typed) must appear in the title; every earlier word that also
    /// matches lowers the score. Word-start matches rank first, then earlier positions.
    private func matchScore(_ text: String, _ q: String) -> Int? {
        let words = q.split(separator: " ").map(String.init)
        guard let last = words.last, let lr = text.range(of: last) else { return nil }
        var score = 0
        for (i, word) in words.enumerated() {
            guard let r = text.range(of: word) else { score += 1000; continue }
            let pos = text.distance(from: text.startIndex, to: r.lowerBound)
            let atWordStart = pos == 0 || text[text.index(before: r.lowerBound)] == " "
            score += (i == words.count - 1 ? pos : pos / 4) + (atWordStart ? 0 : 100)
        }
        _ = lr
        return score
    }
}
