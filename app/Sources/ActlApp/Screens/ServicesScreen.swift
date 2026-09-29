// Services: a list with one lane per harness, filters, multi-select with a bulk "Make lazy" bar,
// and a detail comparison grid (attributes as rows, harnesses as columns, labels once).

import ActlCore
import SwiftUI

struct ServicesScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @State private var filter = "all"
    @State private var selected: Set<String> = []
    @State private var confirmingLazy = false
    @State private var showCommand = false

    private var services: [Service] { (store.services.value ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    private var filtered: [Service] {
        switch filter {
        case "attention": return services.filter(\.needsAttention)
        case "gaps": return services.filter(\.isGap)
        default: return services
        }
    }
    private var current: Service? {
        let id = nav.selectedService ?? filtered.first?.id
        return services.first { $0.id == id }
    }
    private var lazySelection: [Service] {
        services.filter { selected.contains($0.id) && $0.providers.values.contains { $0.lazyAlternative != nil } }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Services", count: store.services.value?.count, subtitle: summary) {
                FilterSwitcher(options: [("all", "All"), ("attention", "Needs attention"), ("gaps", "Gaps")], selection: $filter)
                Button("Add service…") { store.showToast(Toast(title: "Adding services is coming soon", detail: "Add a [service] entry to the manifest and Review will plan it.")) }
            }
            if !selected.isEmpty { bulkBar }
            HStack(spacing: 0) {
                list.frame(minWidth: 480, idealWidth: 560, maxWidth: 620)
                VHairline()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { if nav.selectedService == nil { nav.selectedService = filtered.first?.id } }
        .onChange(of: filter) { _, _ in if !filtered.contains(where: { $0.id == nav.selectedService }) { nav.selectedService = filtered.first?.id } }
    }

    private var summary: String? {
        guard let list = store.services.value else { return nil }
        let both = list.filter { $0.parity == .both }.count
        var parts = ["\(both) in both harnesses"]
        for h in store.managedHarnesses {
            let only = list.filter { $0.providers.count == 1 && $0.providers.keys.contains(h.id) }.count
            if only > 0 { parts.append("\(only) \(h.name.split(separator: " ").first ?? "")-only") }
            let failing = list.filter { $0.providers[h.id]?.health == .failed }.count
            if failing > 0 { parts.append("\(failing) failing in \(h.name.split(separator: " ").first ?? "")") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Bulk bar

    private var bulkBar: some View {
        let lazy = lazySelection
        let saves = lazy.reduce(0) { $0 + ($1.providers["claude"]?.contextTokens ?? 0) }
        let skills = lazy.reduce(0) { $0 + ($1.providers["claude"]?.skills.count ?? 0) }
        return HStack(spacing: 12) {
            Text("\(selected.count) selected: \(services.filter { selected.contains($0.id) }.map(\.name).joined(separator: ", "))").font(Type.base(.semibold)).foregroundStyle(Palette.fg).lineLimit(1)
            if lazy.isEmpty {
                Text("None of these has a lazy alternative.").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
            } else {
                Text("Make lazy saves \(Fmt.int(saves)) tokens/session in Claude · loses \(skills) plugin skill\(skills == 1 ? "" : "s") and updates · planned change, goes through Review").font(Type.sm()).foregroundStyle(Palette.fgSecondary).lineLimit(1)
            }
            Spacer()
            Button("Make lazy (\(lazy.count))") {
                let n = store.planMakeLazy(serviceIds: lazy.map(\.id))
                selected.removeAll()
                if n > 0 { nav.go(.review) } else { store.showToast(Toast(title: "No lazy actions in the current plan", detail: "Re-check to plan them.", isError: true)) }
            }
            .buttonStyle(.borderedProminent).disabled(lazy.isEmpty)
            Button("Cancel") { selected.removeAll() }.buttonStyle(.plain).foregroundStyle(Palette.fgSecondary)
        }
        .padding(.horizontal, 20).frame(height: 40)
        .background(Palette.accentSoft)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SectionLabel(text: "Service").frame(width: 176, alignment: .leading)
                ForEach(store.managedHarnesses) { h in
                    HStack(spacing: 6) { HarnessDot(slot: store.colorSlot(for: h.id)); SectionLabel(text: h.name) }.frame(width: 104, alignment: .leading)
                }
                Spacer(minLength: 0)
                SectionLabel(text: "Tokens").frame(width: 64, alignment: .trailing).fixedSize()
            }
            .padding(.horizontal, 20).frame(height: 34)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.services.value == nil {
                        ForEach(0..<8, id: \.self) { _ in skeletonRow; Hairline() }
                    } else if filtered.isEmpty {
                        Text(filter == "all" ? "No services yet. Connectors, MCP servers and plugins show up here." : "Nothing matches this filter.").font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(height: 60)
                    } else {
                        ForEach(filtered) { s in
                            row(s)
                            Hairline()
                        }
                    }
                }
            }
            Hairline()
            HStack(alignment: .top) {
                Text("Tokens = always-on cost per Claude session. Codex loads services lazily (0).").font(Type.xs()).foregroundStyle(Palette.fgTertiary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("Claude total \(Fmt.int(services.reduce(0) { $0 + ($1.providers["claude"]?.contextTokens ?? 0) }))").font(Type.xs()).foregroundStyle(Palette.fgSecondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.bgSunken).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) { SkeletonLine(width: 90); SkeletonLine(width: 70, height: 10) }
            Spacer()
        }
        .padding(.horizontal, 20).frame(height: 62)
    }

    private func row(_ s: Service) -> some View {
        let isCurrent = current?.id == s.id
        let isSelected = selected.contains(s.id)
        return HStack(spacing: 12) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { isSelected }, set: { on in if on { selected.insert(s.id) } else { selected.remove(s.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .opacity(isSelected || !selected.isEmpty ? 1 : 0.35)
                    .accessibilityLabel("Select \(s.name)")
                ServiceMark(s, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(Type.base(.medium)).foregroundStyle(Palette.fg).lineLimit(1)
                    Text(kinds(s)).font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(1)
                }
            }
            .frame(width: 176, alignment: .leading)
            ForEach(store.managedHarnesses) { h in
                Group {
                    if let p = s.providers[h.id] {
                        StatusLabel(health: p.health, short: true, font: Type.sm(.medium), iconSize: 14)
                    } else {
                        StatusLabel(icon: .blocked, word: "Not available", color: Palette.fgTertiary, font: Type.sm(), iconSize: 14)
                    }
                }
                .frame(width: 104, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text(s.contextTokens > 0 ? Fmt.int(s.contextTokens) : (s.providers["claude"] == nil ? "—" : "0"))
                .font(Type.sm(s.contextTokens >= 4000 ? .semibold : .regular)).foregroundStyle(Palette.fg)
        }
        .padding(.horizontal, 20).frame(height: 62)
        .background(isCurrent ? Palette.bgSelected : .clear)
        .contentShape(Rectangle())
        .onTapGesture { nav.selectedService = s.id }
        .hoverHighlight(0)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func kinds(_ s: Service) -> String {
        store.managedHarnesses.map { h in
            guard let p = s.providers[h.id] else { return "—" }
            switch p.kind { case .plugin: return "Plugin"; case .mcp: return "MCP"; case .connector: return "Connector"; case .claudeAI: return "claude.ai"; case .unknown: return "?" }
        }.joined(separator: " · ")
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let s = current {
            ServiceDetail(service: s, showCommand: $showCommand)
        } else {
            VStack(spacing: 8) {
                Icon(.services, size: 24, color: Palette.fgTertiary)
                Text("Select a service to compare it across harnesses.").font(Type.base()).foregroundStyle(Palette.fgTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ServiceDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    var service: Service
    @Binding var showCommand: Bool
    @State private var tokenText = ""
    @State private var confirmingLazy = false

    private var harnesses: [Harness] { store.managedHarnesses }
    private var signInTarget: (HarnessId, Provider)? {
        for h in harnesses { if let p = service.providers[h.id], p.canSignIn, p.health == .needsAuth { return (h.id, p) } }
        return nil
    }
    private var lazyTarget: (HarnessId, Provider)? {
        for h in harnesses { if let p = service.providers[h.id], p.lazyAlternative != nil { return (h.id, p) } }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                grid
                skillsTable
                parityNote
                actions
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ServiceMark(service, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(service.name).font(Type.lg()).tracking(-0.4).foregroundStyle(Palette.fg)
                Text(headerLine).font(Type.base()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let (h, p) = signInTarget {
                Button("Sign in to \(store.harness(h)?.name.split(separator: " ").first ?? "")…") {
                    store.startSignInThenRest(SignInItem(harness: h, server: p.serverName ?? p.ref, serviceName: service.name, serviceId: service.id))
                    openWindow(id: WindowID.signIn)
                }
                .buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Reveal config in Finder") { External.revealInFinder(configPath(for: harnesses.first?.id ?? "claude")) }
                Button("Open in Terminal") { External.openInTerminal(configPath(for: harnesses.first?.id ?? "claude")) }
                Divider()
                Button("Show sign-in command") { showCommand.toggle() }
            } label: { Icon(.more, size: 14, color: Palette.fg) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.borderStrong, lineWidth: 1))
                .accessibilityLabel("More actions")
        }
    }

    private var headerLine: String {
        var parts: [String] = []
        parts.append(parityWord)
        let skills = Set(service.providers.values.flatMap(\.skills)).count
        if skills > 0 { parts.append("\(skills) skill\(skills == 1 ? "" : "s")") }
        if let g = service.gapReason { parts.append(g) }
        return parts.joined(separator: " · ")
    }

    private var parityWord: String {
        switch service.parity {
        case .both: return "in both harnesses"
        case .onlyClaude: return "Claude Code only"
        case .onlyCodex: return "Codex only"
        case .gap: return "gap"
        case .partial: return "partial parity"
        case .unknown: return "parity unknown"
        }
    }

    // Attributes as rows, harnesses as columns, labels once.
    private var grid: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                Color.clear.frame(width: 110, height: 1)
                ForEach(harnesses) { h in
                    HStack(spacing: 6) {
                        HarnessChip(harness: h, slot: store.colorSlot(for: h.id), size: 14)
                        Text(h.name).font(Type.sm(.semibold)).foregroundStyle(Palette.fg)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.harness(store.colorSlot(for: h.id))).frame(height: 2) }
                }
            }
            .frame(height: 34)
            gridRow("Connection") { h, p in
                if let p { StatusLabel(health: p.health, font: Type.sm(.medium)) } else { Text("Not set up").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
            }
            gridRow("Provided by") { h, p in Text(providedBy(p)).font(Type.sm()).foregroundStyle(p == nil ? Palette.fgTertiary : Palette.fg) }
            gridRow("Auth") { h, p in Text(authLine(p)).font(Type.sm()).foregroundStyle(p == nil ? Palette.fgTertiary : Palette.fg) }
            gridRow("Skills") { h, p in Text(skillsLine(h, p)).font(Type.sm()).foregroundStyle(p == nil ? Palette.fgTertiary : Palette.fg) }
            gridRow("Context cost") { h, p in Text(costLine(p)).font(Type.sm()).foregroundStyle(p == nil ? Palette.fgTertiary : Palette.fg) }
            gridRow("Config") { h, p in
                Text(p == nil ? "—" : Fmt.middleTruncate(configPath(for: h), max: 30)).font(Type.mono(11)).foregroundStyle(p == nil ? Palette.fgTertiary : Palette.fg).help(configPath(for: h))
            }
            gridRow("Last checked") { h, p in
                Text(p == nil ? "—" : "\(store.status.value?.checkedDate.map(Fmt.time) ?? "—") · \(h) mcp list").font(Type.sm()).foregroundStyle(p == nil ? Palette.fgTertiary : Palette.fg)
            }
        }
    }

    private func gridRow<C: View>(_ label: String, @ViewBuilder cell: @escaping (HarnessId, Provider?) -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(width: 110, alignment: .leading)
            ForEach(harnesses) { h in
                cell(h.id, service.providers[h.id]).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            }
        }
        .frame(height: 36)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }

    private func providedBy(_ p: Provider?) -> String {
        guard let p else { return "—" }
        switch p.kind {
        case .plugin:
            let base = p.ref.split(separator: "@").first.map(String.init) ?? p.ref
            return "Plugin \(base)" + (p.lazyAlternative != nil ? " → MCP" : "")
        case .mcp: return "MCP server · \(p.lazyAlternative?.transport ?? (p.ref.contains("http") ? "http" : "stdio"))"
        case .connector: return "ChatGPT connector"
        case .claudeAI: return "claude.ai connector"
        case .unknown: return p.ref
        }
    }

    private func authLine(_ p: Provider?) -> String {
        guard let p else { return "—" }
        let kind: String = switch p.auth { case .oauth: "OAuth"; case .token: "Token"; case .none: "No auth"; case .chatgpt: "ChatGPT account"; case .unknown: "Unknown auth" }
        if let d = p.detail, p.auth != .chatgpt { return d.localizedCaseInsensitiveContains(kind) ? d : "\(kind) · \(d)" }
        return kind
    }

    private func skillsLine(_ h: HarnessId, _ p: Provider?) -> String {
        guard let p else { return "—" }
        if p.skills.isEmpty { return "none" }
        return "\(p.skills.count), " + (p.kind == .plugin ? "bundled with the plugin" : "from ~/.agents/skills")
    }

    private func costLine(_ p: Provider?) -> String {
        guard let p else { return "—" }
        let t = p.contextTokens ?? 0
        return t > 0 ? "\(Fmt.int(t)) tokens every session" : "0 · tools load on first call"
    }

    private func configPath(for h: HarnessId) -> String {
        guard let p = service.providers[h] else { return "" }
        switch (h, p.kind) {
        case ("claude", .plugin): return "~/.claude/plugins/cache/\(p.ref.split(separator: "@").first ?? "")/.mcp.json"
        case ("claude", _): return "~/.claude.json"
        case ("codex", .connector): return "~/.codex/plugins"
        case ("codex", _): return "~/.codex/config.toml"
        default: return store.harness(h)?.home ?? "~"
        }
    }

    @ViewBuilder
    private var skillsTable: some View {
        let names = Array(Set(service.providers.values.flatMap(\.skills))).sorted()
        if !names.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Skills this service brings").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                    Text(skillsSubtitle(names)).font(Type.sm()).foregroundStyle(Palette.fgTertiary)
                    Spacer()
                }
                .frame(height: 32)
                Hairline()
                ForEach(names, id: \.self) { n in
                    HStack(spacing: 12) {
                        Text(n).font(Type.mono(12)).foregroundStyle(Palette.fg).frame(width: 180, alignment: .leading).lineLimit(1)
                        ForEach(harnesses) { h in
                            let has = service.providers[h.id]?.skills.contains(n) ?? false
                            Text(has ? (service.providers[h.id]?.kind == .plugin ? "\(h.name.split(separator: " ").first ?? ""): plugin" : "\(h.name.split(separator: " ").first ?? ""): ~/.agents/skills") : "\(h.name.split(separator: " ").first ?? ""): —")
                                .font(Type.sm()).foregroundStyle(has ? Palette.fg : Palette.fgTertiary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        let everywhere = harnesses.allSatisfy { service.providers[$0.id]?.skills.contains(n) ?? false }
                        StatusLabel(icon: everywhere ? .connected : .gap, word: everywhere ? "In sync" : "One harness", color: everywhere ? Palette.ok : Palette.fgSecondary)
                    }
                    .frame(height: 34)
                    Hairline()
                }
            }
        }
    }

    private func skillsSubtitle(_ names: [String]) -> String {
        let everywhere = names.allSatisfy { n in harnesses.allSatisfy { service.providers[$0.id]?.skills.contains(n) ?? false } }
        return everywhere ? "same \(names.count) in both harnesses" : "\(names.count) skills, not in every harness"
    }

    @ViewBuilder
    private var parityNote: some View {
        if let text = ServiceCopy.parityNote(service, harnesses: harnesses) {
            NoteWell(icon: service.parity == .both ? .connected : .gap, tint: service.parity == .both ? Palette.ok : Palette.fgSecondary, text: text)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let (h, _) = lazyTarget {
                    if confirmingLazy {
                        HStack(spacing: 6) {
                            Text("Switch now? Undo stays available.").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
                            Button("Cancel") { confirmingLazy = false }
                            Button("Switch") { confirmingLazy = false; store.makeLazy(service: service) }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button("Switch \(store.harness(h)?.name.split(separator: " ").first ?? "") to bare MCP") { confirmingLazy = true }
                    }
                }
                Button("Reveal config in Finder") { External.revealInFinder(configPath(for: harnesses.first?.id ?? "claude")) }
                Button("Open in Terminal") { External.openInTerminal(configPath(for: harnesses.first?.id ?? "claude")) }
            }
            if service.providers.values.contains(where: { $0.auth == .token && $0.health == .failed }) {
                tokenEntry
            }
            if let (h, p) = signInTarget {
                CommandWell(command: "\(h) mcp login \(p.serverName ?? p.ref)")
            } else if showCommand, let h = harnesses.first, let p = service.providers[h.id] {
                CommandWell(command: "\(h.id) mcp login \(p.serverName ?? p.ref)")
            }
        }
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(service.name) needs an API token, not a browser sign-in").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
            Text("Stored in the macOS keychain · never written to config files").font(Type.xs()).foregroundStyle(Palette.fgTertiary)
            HStack(spacing: 8) {
                SecureField("\(service.id.uppercased())_API_TOKEN", text: $tokenText).textFieldStyle(.roundedBorder).font(Type.mono(12)).frame(maxWidth: 360)
                Button("Save and test") { store.showToast(Toast(title: "Token storage is coming soon", detail: "The engine will accept tokens in a later release.", isError: true)); tokenText = "" }.buttonStyle(.borderedProminent).disabled(tokenText.isEmpty)
                Button("Where do I get one?") { External.open("https://\(service.id).com/") }
            }
        }
        .padding(12)
        .card(radius: Radius.md, fill: Palette.bgSunken)
    }
}

enum ServiceCopy {
    static func parityNote(_ s: Service, harnesses: [Harness]) -> String? {
        guard harnesses.count >= 2 else { return nil }
        let providers = harnesses.compactMap { s.providers[$0.id] }
        if s.parity == .both, providers.count == harnesses.count {
            let needs = providers.contains { $0.health == .needsAuth }
            let cost = providers.map { $0.contextTokens ?? 0 }.max() ?? 0
            let costly = harnesses.first { (s.providers[$0.id]?.contextTokens ?? 0) == cost && cost > 0 }
            var text = "Parity: equal" + (needs ? " once you sign in" : "") + "."
            let skills = providers.first?.skills.count ?? 0
            if skills > 0 { text += " Both harnesses expose the same \(skills) skill\(skills == 1 ? "" : "s")." }
            if let costly, cost > 0 {
                text += " The only difference is cost: \(costly.name) pays \(Fmt.int(cost)) tokens up front because the plugin injects its skill listing"
                if s.providers[costly.id]?.lazyAlternative != nil { text += "; switching \(costly.name.split(separator: " ").first ?? "") to the bare MCP server would drop that to 0 but lose plugin updates." } else { text += "." }
            }
            return text
        }
        if let g = s.gapReason { return "Gap: \(g)." }
        if s.parity == .partial {
            if let failed = harnesses.first(where: { s.providers[$0.id]?.health == .failed }) {
                return "Partial: \(failed.name) can't connect (\(s.providers[failed.id]?.detail ?? "failed")). The other harness is fine, so tools differ until this is fixed."
            }
            return "Partial parity: the harnesses expose different tools for this service."
        }
        let present = harnesses.filter { s.providers[$0.id] != nil }.map(\.name)
        let missing = harnesses.filter { s.providers[$0.id] == nil }.map(\.name)
        if !missing.isEmpty { return "Only in \(present.joined(separator: ", ")). Add it to \(missing.joined(separator: ", ")) from the manifest to close the gap." }
        return nil
    }
}
