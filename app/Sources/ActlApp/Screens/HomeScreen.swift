// Home: the parity headline, one bar per harness, the attention queue ordered by what blocks work
// first, recent activity, and a right rail with context, skills and proxy summaries.

import ActlCore
import SwiftUI

struct HomeScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(\.openWindow) private var openWindow
    @State private var filter: String = "all"
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Home", count: nil, subtitle: subtitleDate) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    HStack(spacing: 6) { Icon(.syncing, size: 12, color: Palette.fg); Text("Re-check") }
                }
                .disabled(store.isSyncing)
                Button(store.planCount > 0 ? "Review \(store.planCount) change\(store.planCount == 1 ? "" : "s")" : "Review changes") { nav.go(.review) }
                    .buttonStyle(.borderedProminent)
            }
            ScrollView {
                VStack(spacing: 0) {
                    headline.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 24)
                    Hairline()
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            attentionQueue
                            recentActivity
                        }
                        .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VHairline()
                        rightRail.frame(width: 328)
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var subtitleDate: String {
        let checked = store.status.value?.checkedDate ?? store.status.loadedAt
        return Fmt.longDate(now) + (checked.map { " · checked \(Fmt.time($0))" } ?? "")
    }

    // MARK: Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                if let s = store.status.value {
                    Text(HomeCopy.headline(s, harnesses: store.harnesses)).font(Type.xl()).tracking(-0.56).foregroundStyle(Palette.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(HomeCopy.subtitle(store)).font(Type.base()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
                } else if let e = store.status.error ?? store.engineError {
                    Text("actl can't read this Mac yet").font(Type.xl()).tracking(-0.56).foregroundStyle(Palette.fg)
                    InlineError(message: e, retry: { Task { await store.bootstrap() } })
                } else {
                    SkeletonLine(width: 620, height: 26).padding(.vertical, 3)
                    SkeletonLine(width: 480, height: 13).padding(.vertical, 2)
                }
            }
            VStack(spacing: 12) {
                ForEach(store.status.value?.harnesses ?? placeholderHarnesses) { h in harnessBar(h) }
            }
        }
    }

    private var placeholderHarnesses: [StatusHarness] {
        store.managedHarnesses.map { StatusHarness(id: $0.id, name: $0.name, connected: 0, total: 0, needsSignIn: 0, failed: 0) }
    }

    private func harnessBar(_ h: StatusHarness) -> some View {
        let slot = store.colorSlot(for: h.id)
        let blocked = max(0, h.total - h.connected - h.needsSignIn - h.failed)
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                HarnessDot(slot: slot)
                Text(h.name).font(Type.base(.medium)).foregroundStyle(Palette.fg)
            }
            .frame(width: 120, alignment: .leading)
            ParityBar(connected: h.connected, needsSignIn: h.needsSignIn, failed: h.failed, total: h.total, height: 12)
                .frame(maxWidth: 470)
            HStack(spacing: 12) {
                Text("\(h.connected) connected").foregroundStyle(h.total == 0 ? Palette.fgTertiary : Palette.ok)
                if h.needsSignIn > 0 { Text("\(h.needsSignIn) need sign-in").foregroundStyle(Palette.warn) }
                if h.failed > 0 { Text("\(h.failed) failed").foregroundStyle(Palette.error) }
                if blocked > 0 { Text("\(blocked) blocked").foregroundStyle(Palette.fgTertiary) }
                if h.needsSignIn == 0 && h.failed == 0 && blocked == 0, let only = HomeCopy.onlyHere(store, harness: h.id) { Text(only).foregroundStyle(Palette.fgTertiary) }
            }
            .font(Type.sm())
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Attention queue

    private var items: [AttentionItem] {
        let all = (store.status.value?.attention ?? []).orderedByBlocking()
        if filter == "all" { return all }
        return all.filter { $0.harness == filter }
    }

    private var attentionQueue: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(store.status.value.map { "Attention · \($0.attention.count)" } ?? "Attention").font(Type.md()).foregroundStyle(Palette.fg)
                Text("ordered by what blocks work first").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
                Spacer()
                FilterSwitcher(options: [("all", "All")] + store.managedHarnesses.map { ($0.id, $0.name.split(separator: " ").first.map(String.init) ?? $0.name) }, selection: $filter)
            }
            .frame(height: 36)
            if store.status.value == nil {
                ForEach(0..<4, id: \.self) { _ in
                    Hairline()
                    HStack(spacing: 12) { SkeletonLine(width: 70); SkeletonLine(width: 60); SkeletonLine(width: 260); Spacer(); SkeletonLine(width: 64, height: 22) }.frame(height: 47)
                }
            } else if items.isEmpty {
                Hairline()
                HStack(spacing: 10) {
                    Icon(.connected, size: 16, color: Palette.ok)
                    Text(filter == "all" ? "Nothing needs you. Both harnesses match the manifest." : "Nothing needs you in \(store.harness(filter)?.name ?? filter).").font(Type.base()).foregroundStyle(Palette.fgSecondary)
                }
                .frame(height: 47)
            } else {
                ForEach(items) { item in
                    Hairline()
                    attentionRow(item)
                }
            }
            Hairline()
        }
    }

    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(spacing: 12) {
            KindChip(kind: item.kind, severity: item.severity).frame(width: 96, alignment: .leading)
            harnessLabel(item.harness).frame(width: 76, alignment: .leading)
            if let svc = serviceFor(item) { ServiceMark(svc, size: 20) }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Type.base(.medium)).foregroundStyle(Palette.fg).lineLimit(1)
                if let d = item.detail { Text(d).font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            attentionAction(item)
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .contain)
    }

    private func serviceFor(_ item: AttentionItem) -> Service? {
        guard item.kind == .failed || item.kind == .quota, let list = store.services.value else { return nil }
        return list.first { item.title.localizedCaseInsensitiveContains($0.name) }
    }

    @ViewBuilder
    private func harnessLabel(_ id: HarnessId?) -> some View {
        if let id, id == "proxy" {
            HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(Palette.fgTertiary).frame(width: 8, height: 8); Text("Proxy").font(Type.sm()).foregroundStyle(Palette.fgSecondary) }
        } else if let id, let h = store.harness(id) {
            HStack(spacing: 6) { HarnessDot(slot: store.colorSlot(for: id)); Text(h.name.split(separator: " ").first.map(String.init) ?? h.name).font(Type.sm()).foregroundStyle(Palette.fgSecondary) }
        } else {
            Text("").frame(width: 8)
        }
    }

    @ViewBuilder
    private func attentionAction(_ item: AttentionItem) -> some View {
        if let s = item.fix?.signIn {
            Button(item.fix?.label == "Sign in…" ? "Sign in to all…" : item.fix!.label) {
                store.startSignIn(harness: s.harness, servers: s.servers)
                openWindow(id: WindowID.signIn)
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        } else if let ids = item.fix?.actionIds, !ids.isEmpty, planHas(ids) {
            Button {
                nav.go(.review)
            } label: {
                Text("In plan").font(Type.sm(.medium)).foregroundStyle(Palette.accent).padding(.horizontal, 10).frame(height: 22)
                    .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("In plan, open Review changes")
        } else if item.kind == .failed, item.detail?.localizedCaseInsensitiveContains("token") == true || item.title.localizedCaseInsensitiveContains("token") {
            Button("Add token…") { nav.go(.services, service: serviceFor(item)?.id) }.controlSize(.small)
        } else if item.kind == .gap {
            Button("Accept gap") { store.showToast(Toast(title: "Gaps are accepted in the manifest", detail: "Edit \(store.manifestPath) to record why.")) }.controlSize(.small)
        } else {
            Button(item.fix?.label ?? "Details") { nav.go(detailScreen(item)) }.controlSize(.small)
        }
    }

    private func planHas(_ ids: [String]) -> Bool {
        guard let p = store.plan.value else { return false }
        let set = Set(p.actions.map(\.id))
        return ids.allSatisfy { set.contains($0) }
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

    // MARK: Recent activity

    private var recentActivity: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Recent activity").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                Text("what the app did on its own, and what you applied").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
                Spacer()
                Button("Open activity") { nav.go(.activity) }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent)
            }
            .frame(height: 40).padding(.top, 12)
            ForEach((store.activity.value ?? []).prefix(3)) { e in
                Hairline()
                activityRow(e)
            }
            if (store.activity.value ?? []).isEmpty {
                Hairline()
                Text(store.activity.isLoading ? "Loading…" : "No runs yet. Applied changes and automatic checks show up here.").font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(height: 36)
            }
        }
    }

    private func activityRow(_ e: ActivityEntry) -> some View {
        let harness = harnessOf(e)
        return HStack(spacing: 12) {
            Text(e.date.map { Fmt.timeOrDay($0, now: now) } ?? "").font(Type.xs()).foregroundStyle(Palette.fgTertiary).frame(width: 60, alignment: .leading)
            harnessLabelForActivity(e, harness).frame(width: 76, alignment: .leading)
            Text(ActivityCopy.summary(e)).font(Type.base()).foregroundStyle(Palette.fg).lineLimit(2)
            Spacer(minLength: 8)
            ActivityState(entry: e)
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
    }

    private func harnessOf(_ e: ActivityEntry) -> HarnessId? {
        if e.source == .watch { return nil }
        let t = e.actions.map(\.title).joined(separator: " ").lowercased()
        for h in store.harnesses where t.contains(h.name.lowercased()) || t.contains(h.id) { return h.id }
        if t.contains("proxy") { return "proxy" }
        return nil
    }

    @ViewBuilder
    private func harnessLabelForActivity(_ e: ActivityEntry, _ harness: HarnessId?) -> some View {
        if e.source == .watch {
            HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(Palette.fgTertiary).frame(width: 8, height: 8); Text("Watch").font(Type.sm()).foregroundStyle(Palette.fgSecondary) }
        } else {
            harnessLabel(harness)
        }
    }

    // MARK: Right rail

    private var rightRail: some View {
        VStack(alignment: .leading, spacing: 28) {
            contextMini
            skillsMini
            if store.proxyConfigured { proxyMini }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var contextMini: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Context before you type").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                Spacer()
                Button("Open budget") { nav.go(.contextBudget) }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent)
            }
            if let b = store.budget.value {
                let scale = b.harnesses.values.map(\.total).max() ?? 1
                ForEach(store.managedHarnesses) { h in
                    if let hb = b.harnesses[h.id] {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                HStack(spacing: 6) { HarnessDot(slot: store.colorSlot(for: h.id)); Text(h.name).font(Type.sm()).foregroundStyle(Palette.fgSecondary) }
                                Spacer()
                                Text("\(Fmt.compact(hb.total)) tokens/session").font(Type.md(.semibold)).foregroundStyle(Palette.fgSecondary)
                            }
                            StackedBar(slot: store.colorSlot(for: h.id), categories: hb.categories, scale: scale, height: 8)
                            Text(hb.categories.filter { $0.tokens > 0 }.map { "\(Fmt.compact($0.tokens)) \(BudgetCopy.categoryName($0.id))" }.joined(separator: " · "))
                                .font(Type.xs()).foregroundStyle(Palette.fgTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let lever = BudgetCopy.biggestLever(b) {
                    NoteWell(icon: .warn, tint: Palette.warn, text: lever)
                }
            } else if let e = store.budget.error {
                InlineError(message: e, retry: { Task { await store.refreshBudget() } })
            } else {
                SkeletonLine(width: 200, height: 14); SkeletonLine(width: 270, height: 8); SkeletonLine(width: 200, height: 14); SkeletonLine(width: 270, height: 8)
            }
        }
    }

    private var skillsMini: some View {
        let skills = store.skillsWithState
        let inBoth = skills.filter { $0.syncState == "in-sync" }.count
        let pending = skills.filter { $0.syncState == "pending" }.count
        let conflict = skills.filter { $0.syncState == "conflict" }.count
        let onlyOne = skills.filter { $0.visibleIn.claude != $0.visibleIn.codex }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(skills.isEmpty ? "Skills" : "Skills · \(skills.count)").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                Spacer()
                Button("Open skills") { nav.go(.skills) }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent)
            }
            if skills.isEmpty {
                Text(store.inventory.isLoading ? "Counting skills…" : "No skills found.").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
            } else {
                miniRow(.connected, Palette.ok, "In sync in both harnesses", inBoth)
                miniRow(.syncing, Palette.warn, "Pending sync to Claude", pending)
                miniRow(.warn, Palette.error, "Edited in place (conflict)", conflict)
                miniRow(.gap, Palette.fgSecondary, "Only in one harness", onlyOne)
            }
        }
    }

    private func miniRow(_ icon: IconName, _ color: Color, _ label: String, _ n: Int) -> some View {
        HStack(spacing: 8) {
            Icon(icon, size: 14, color: color)
            Text(label).font(Type.sm()).foregroundStyle(Palette.fg)
            Spacer()
            Text(Fmt.int(n)).font(Type.sm(.medium)).foregroundStyle(Palette.fg)
        }
        .accessibilityElement(children: .combine)
    }

    private var proxyMini: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Proxy · last 3 h").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                Spacer()
                Button("Open accounts") { nav.go(.proxy) }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent)
            }
            if let p = store.proxy.value {
                ZStack {
                    ForEach(store.managedHarnesses) { h in
                        let series = p.accounts.filter { $0.provider == h.id }
                        let n = series.map(\.recent.count).max() ?? 0
                        let merged = (0..<n).map { i in series.reduce(0.0) { $0 + Double(i < $1.recent.count ? $1.recent[i].success + $1.recent[i].failed : 0) } }
                        Sparkline(values: merged, color: Palette.harness(store.colorSlot(for: h.id)))
                    }
                }
                .frame(height: 44)
                let active = p.accounts.filter { $0.state == .active }.count
                let cool = p.accounts.filter { $0.state == .cooldown }.count
                Text("\(active) account\(active == 1 ? "" : "s") active" + (cool > 0 ? " · \(cool) in cooldown" : "")).font(Type.xs()).foregroundStyle(Palette.fgSecondary)
                Text("\(Fmt.int(p.accounts.reduce(0) { $0 + $1.success })) ok · \(Fmt.int(p.accounts.reduce(0) { $0 + $1.failed })) failed").font(Type.xs()).foregroundStyle(Palette.fgSecondary)
            } else if let e = store.proxy.error {
                Text(e).font(Type.xs()).foregroundStyle(Palette.fgTertiary)
            } else {
                SkeletonLine(width: 270, height: 44); SkeletonLine(width: 160, height: 11)
            }
        }
    }
}

// MARK: - Copy helpers

enum HomeCopy {
    static func headline(_ s: Status, harnesses: [Harness]) -> String {
        let parts: [String] = s.harnesses.map { h in
            if h.total == 0 { return "\(h.name) has no services yet." }
            if h.connected == h.total { return "\(h.name) is fully set up." }
            var gaps: [String] = []
            if h.needsSignIn > 0 { gaps.append("\(h.needsSignIn) sign-in\(h.needsSignIn == 1 ? "" : "s")") }
            if h.failed > 0 { gaps.append("\(h.failed) fix\(h.failed == 1 ? "" : "es")") }
            let other = h.total - h.connected - h.needsSignIn - h.failed
            if gaps.isEmpty && other > 0 { gaps.append("\(other) service\(other == 1 ? "" : "s")") }
            return "\(h.name) is \(gaps.joined(separator: " and ")) short of parity."
        }
        if s.harnesses.count >= 2, s.harnesses.allSatisfy({ $0.connected == $0.total && $0.total > 0 }) {
            let names = s.harnesses.map(\.name)
            return names.dropLast().joined(separator: ", ") + " and " + names.last! + " are fully set up."
        }
        // Lead with the good news, as in the design.
        let sorted = parts.enumerated().sorted { a, b in
            let ha = s.harnesses[a.offset], hb = s.harnesses[b.offset]
            return (ha.connected == ha.total ? 0 : 1, a.offset) < (hb.connected == hb.total ? 0 : 1, b.offset)
        }
        return sorted.map(\.element).joined(separator: " ")
    }

    @MainActor
    static func subtitle(_ store: AppStore) -> String {
        var counts: [String] = []
        if let n = store.services.value?.count { counts.append("\(n) service\(n == 1 ? "" : "s")") }
        if let inv = store.inventory.value {
            counts.append("\(inv.skills.count) skill\(inv.skills.count == 1 ? "" : "s")")
            counts.append("\(inv.instructions.count) instruction file\(inv.instructions.count == 1 ? "" : "s")")
        }
        if store.proxyConfigured, let n = store.proxy.value?.accounts.count { counts.append("\(n) proxy account\(n == 1 ? "" : "s")") }
        var tail = ""
        if let p = store.plan.value {
            if !p.manifestExists { tail = " No manifest yet; adopt one in Settings to start planning." }
            else if p.actions.isEmpty { tail = " The manifest matches this Mac; nothing to review." }
            else {
                let when = store.plan.loadedAt.map { " since \(Fmt.time($0))" } ?? ""
                tail = " Nothing has changed in the manifest\(when); \(p.actions.count) fix\(p.actions.count == 1 ? " is" : "es are") ready to review."
            }
        }
        return counts.joined(separator: " · ") + "." + tail
    }

    @MainActor
    static func onlyHere(_ store: AppStore, harness: HarnessId) -> String? {
        guard let list = store.services.value else { return nil }
        let only = list.filter { $0.providers.keys.contains(harness) && $0.providers.count == 1 }
        guard !only.isEmpty else { return nil }
        let name = store.harness(harness)?.name ?? harness
        return "\(only.count) \(name)-only (\(only.prefix(2).map(\.name).joined(separator: ", "))\(only.count > 2 ? ", …" : ""))"
    }
}

enum ActivityCopy {
    static func summary(_ e: ActivityEntry) -> String {
        guard let first = e.actions.first else { return "Run \(e.runId)" }
        if e.actions.count == 1 { return first.title }
        let ok = e.actions.filter { $0.state == .ok }.count
        let extra = e.actions.dropFirst().map { $0.title.prefix(1).lowercased() + $0.title.dropFirst() }
        return "Applied \(ok) change\(ok == 1 ? "" : "s") · \(first.title.prefix(1).lowercased() + first.title.dropFirst())" + (extra.isEmpty ? "" : ", " + extra.joined(separator: ", "))
    }
}

struct ActivityState: View {
    var entry: ActivityEntry
    var body: some View {
        if entry.undoneAt != nil {
            StatusLabel(icon: .undo, word: "Undone", color: Palette.fgTertiary)
        } else if entry.actions.contains(where: { $0.state == .failed }) {
            StatusLabel(icon: entry.source == .watch ? .drift : .failed, word: entry.source == .watch ? "Drift" : "Failed", color: entry.source == .watch ? Palette.warn : Palette.error)
        } else if entry.source == .auto {
            Text("Auto").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
        } else {
            StatusLabel(icon: .connected, word: "Done", color: Palette.ok)
        }
    }
}

enum BudgetCopy {
    static func categoryName(_ c: BudgetCategory) -> String {
        switch c {
        case .plugins: return "plugins"
        case .skillsListing: return "skills listing"
        case .instructions: return "instructions"
        case .rules: return "rules"
        case .drift: return "drift"
        case .other: return "other"
        }
    }

    static func biggestLever(_ b: Budget) -> String? {
        var best: (HarnessId, BudgetLever)?
        for (h, hb) in b.harnesses {
            for l in hb.levers where l.action != nil {
                if best == nil || l.tokens > best!.1.tokens { best = (h, l) }
            }
        }
        guard let (h, l) = best, let total = b.harnesses[h]?.total, total > 0 else { return nil }
        let verb: String = switch l.action { case .rescope: "re-scoping"; case .makeLazy: "making \(l.label.replacingOccurrences(of: " plugin", with: "")) lazy"; case .disable: "disabling"; default: "changing" }
        let name = h == "claude" ? "Claude" : h.capitalized
        let pct = Int((Double(l.tokens) / Double(total) * 100).rounded())
        return "Biggest lever: \(verb) \(l.action == .rescope ? "the \(l.label.replacingOccurrences(of: " (always-on)", with: ""))" : "") saves \(Fmt.compact(l.tokens)) per \(name) session (\u{2212}\(pct)%)."
            .replacingOccurrences(of: "  ", with: " ")
    }
}
