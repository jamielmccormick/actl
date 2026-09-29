// Context budget: a stacked bar per harness, ranked levers, multi-select bulk Make lazy (becomes a
// planned change), and a Load preview with a repo picker.

import ActlCore
import SwiftUI

struct ContextBudgetScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    @State private var scope = "global"
    @State private var selected: Set<String> = []
    @State private var showAll: Set<String> = []
    @State private var repo: String = ""

    private var budget: Budget? { store.budget.value }
    private var scale: Int { budget?.harnesses.values.map(\.total).max() ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Context budget", count: nil, subtitle: "tokens each harness spends before you type a word") {
                FilterSwitcher(options: [("global", "Global"), ("repo", "Per repo")], selection: $scope)
            }
            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(store.managedHarnesses.enumerated()), id: \.element.id) { i, h in
                            if i > 0 { VHairline() }
                            harnessColumn(h).frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    Hairline()
                    loadPreview
                }
            }
        }
        .onAppear { if repo.isEmpty { repo = budget?.loadPreview?.repo ?? store.inventory.value?.repos.first?.path ?? "" } }
        .onChange(of: budget?.loadPreview?.repo) { _, r in if let r, repo.isEmpty { repo = r } }
    }

    // MARK: Per-harness column

    private func harnessColumn(_ h: Harness) -> some View {
        let slot = store.colorSlot(for: h.id)
        let hb = budget?.harnesses[h.id]
        let deltas = store.plan.value.map { store.selection.tokensDelta(in: $0)[h.id] ?? 0 } ?? 0
        let planned = store.plan.value?.actions.filter { $0.harness == h.id && ($0.tokensDelta ?? 0) != 0 }.reduce(0) { $0 + ($1.tokensDelta ?? 0) } ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) { HarnessDot(slot: slot); Text(h.name).font(Type.base(.semibold)).foregroundStyle(Palette.fg) }
                Spacer()
                if let hb { Text("\(hb.levers.count) items").font(Type.xs()).foregroundStyle(Palette.fgTertiary) }
            }
            if let hb {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.int(hb.total)).font(Type.xl()).tracking(-0.56).foregroundStyle(Palette.fg)
                    Text("tokens before you type").font(Type.base()).foregroundStyle(Palette.fgSecondary)
                    Spacer()
                    if planned < 0 {
                        Text("\(Fmt.int(hb.total + planned)) after the plan (\u{2212}\(Fmt.percent(-planned, of: hb.total)))").font(Type.sm(.medium)).foregroundStyle(Palette.ok)
                    } else {
                        Text(deltas == 0 ? "unchanged by the plan" : "\(Fmt.tokensDelta(deltas)) selected").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
                    }
                }
                StackedBar(slot: slot, categories: hb.categories, scale: scale, height: 12)
                HStack(spacing: 12) {
                    ForEach(hb.categories.filter { $0.tokens > 0 }) { c in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(StackedBar.tint(c.id, slot: slot)).frame(width: 8, height: 8)
                            Text("\(BudgetCopy.categoryName(c.id).capitalized) \(Fmt.int(c.tokens))").font(Type.xs()).foregroundStyle(Palette.fgSecondary)
                        }
                    }
                    if hb.total < scale && store.managedHarnesses.count > 1 { Text("same scale as \(store.managedHarnesses.first?.name.split(separator: " ").first ?? "")").font(Type.xs()).foregroundStyle(Palette.fgTertiary) }
                }
                levers(h.id, hb, slot: slot)
                if h.id == "claude" || hb.levers.contains(where: { $0.action == .makeLazy }) { bulkCard(h.id) } else { explainer(h) }
            } else if let e = store.budget.error {
                InlineError(message: e, retry: { Task { await store.refreshBudget() } })
            } else {
                SkeletonLine(width: 180, height: 28); SkeletonLine(width: 400, height: 12)
                ForEach(0..<6, id: \.self) { _ in HStack { SkeletonLine(width: 150); Spacer(); SkeletonLine(width: 120, height: 8); SkeletonLine(width: 50) } }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
    }

    private func levers(_ harness: HarnessId, _ hb: HarnessBudget, slot: Int) -> some View {
        let sorted = hb.levers.sorted { $0.tokens > $1.tokens }
        let open = showAll.contains(harness)
        let shown = open ? sorted : Array(sorted.prefix(10))
        let maxTokens = sorted.first?.tokens ?? 1
        return VStack(spacing: 0) {
            ForEach(shown) { l in
                leverRow(harness, l, slot: slot, maxTokens: maxTokens)
            }
            if sorted.count > 10 {
                HStack(spacing: 4) {
                    Button(open ? "Show top 10" : "Show all \(sorted.count)") { if open { showAll.remove(harness) } else { showAll.insert(harness) } }
                        .buttonStyle(.plain).font(Type.sm()).foregroundStyle(Palette.accent)
                    if let removed = store.activity.value?.flatMap(\.actions).first(where: { $0.id.hasPrefix("plugin.uninstall") }) {
                        Text("· \(removed.title.split(separator: "(").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? removed.title)").font(Type.sm()).foregroundStyle(Palette.fgTertiary).lineLimit(1)
                    }
                    Spacer()
                }
                .frame(height: 28)
            }
        }
    }

    private func leverRow(_ harness: HarnessId, _ l: BudgetLever, slot: Int, maxTokens: Int) -> some View {
        let isDrift = l.kind == .rule && (store.plan.value?.actions.contains { $0.kind == .ruleRescope } ?? false)
        let service = l.serviceId.flatMap { id in store.services.value?.first { $0.id == id } }
        let failing = service?.providers[harness]?.health == .failed
        let selectable = l.action == .makeLazy && l.serviceId != nil
        let isSelected = selectable && selected.contains(l.serviceId!)
        return HStack(spacing: 10) {
            if selectable {
                Toggle("", isOn: Binding(get: { isSelected }, set: { on in if on { selected.insert(l.serviceId!) } else { selected.remove(l.serviceId!) } }))
                    .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Select \(l.label)")
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
            if let service { ServiceMark(service, size: 16) }
            Text(l.label).font(Type.sm(isDrift ? .medium : .regular)).foregroundStyle(Palette.fg).lineLimit(1)
            Spacer(minLength: 8)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Palette.bgSunken)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(isDrift ? Palette.warn : (failing ? Palette.error.opacity(0.7) : Palette.harness(slot).opacity(l.kind == .plugin ? 1 : 0.45)))
                            .frame(width: max(3, geo.size.width * CGFloat(l.tokens) / CGFloat(max(maxTokens, 1))))
                    }
            }
            .frame(width: 110, height: 8)
            Text((l.estimated ? "~" : "") + Fmt.int(l.tokens)).font(Type.sm(.medium)).foregroundStyle(Palette.fg).frame(width: 56, alignment: .trailing)
            leverTag(l, isDrift: isDrift, failing: failing).frame(width: 76, alignment: .leading)
        }
        .frame(height: 26)
        .padding(.horizontal, 4)
        .background(isSelected ? Palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func leverTag(_ l: BudgetLever, isDrift: Bool, failing: Bool) -> some View {
        if isDrift { Text("drift · in plan").font(Type.xs()).foregroundStyle(Palette.warn) }
        else if failing { Text("failing").font(Type.xs()).foregroundStyle(Palette.error) }
        else if l.action == .makeLazy { Button("Make lazy") { if let id = l.serviceId { selected.insert(id) } }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent) }
        else if l.estimated { Text("estimate").font(Type.xs()).foregroundStyle(Palette.fgTertiary) }
        else if l.kind == .skills { Text("fixed").font(Type.xs()).foregroundStyle(Palette.fgTertiary) }
        else if l.kind == .instructions { Text("shared").font(Type.xs()).foregroundStyle(Palette.fgTertiary) }
        else if l.kind == .plugin, l.action == nil { Text("skills only").font(Type.xs()).foregroundStyle(Palette.fgTertiary) }
        else { Text("").frame(width: 1) }
    }

    private func bulkCard(_ harness: HarnessId) -> some View {
        let services = (store.services.value ?? []).filter { selected.contains($0.id) }
        let saves = services.reduce(0) { $0 + ($1.providers[harness]?.contextTokens ?? 0) }
        let skills = services.reduce(0) { $0 + ($1.providers[harness]?.skills.count ?? 0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(services.isEmpty ? "Select plugins to make lazy" : "\(services.count) plugin\(services.count == 1 ? "" : "s") selected: \(services.map(\.name).joined(separator: ", "))").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                Spacer()
                Button("Make lazy (\(services.count))") {
                    let n = store.planMakeLazy(serviceIds: services.map(\.id))
                    selected.removeAll()
                    if n > 0 { nav.go(.review) } else { store.showToast(Toast(title: "No lazy actions in the current plan", detail: "Re-check to plan them.", isError: true)) }
                }
                .buttonStyle(.borderedProminent).disabled(services.isEmpty)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(services.isEmpty ? "A plugin becomes its bare MCP server: tools stay identical, the plugin's skill listing and updates go." : "\u{2212}\(Fmt.int(saves)) tokens per \(store.harness(harness)?.name.split(separator: " ").first ?? "") session")
                if !services.isEmpty { Text("Loses \(skills) plugin skill\(skills == 1 ? "" : "s") and plugin updates; MCP tools stay identical") }
                Text("Becomes a planned change · goes through Review before anything is written")
            }
            .font(Type.xs()).foregroundStyle(Palette.fgSecondary)
        }
        .padding(16)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    private func explainer(_ h: Harness) -> some View {
        let other = store.managedHarnesses.first { $0.id != h.id }
        let ratio: String = {
            guard let b = budget, let mine = b.harnesses[h.id]?.total, let o = other.flatMap({ b.harnesses[$0.id]?.total }), mine > 0 else { return "" }
            let r = Int((Double(o) / Double(mine)).rounded())
            let word: String = switch r { case 2: "half"; case 3: "third"; case 4: "quarter"; case 5: "fifth"; default: "\(r)th" }
            return r >= 2 ? "\(h.name) costs about a \(word) of \(other!.name) for the same services because " : "\(h.name) is cheaper because "
        }()
        return NoteWell(icon: .contextBudget, tint: Palette.ok, text: ratio + "MCP servers and ChatGPT connectors load their tools on first call. In \(other?.name ?? "the other harness"), plugins pay up front; bare MCP servers cost 0. \u{201C}Make lazy\u{201D} switches a service to the bare server and is a plan item.")
    }

    // MARK: Load preview

    private var loadPreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Load preview").font(Type.md()).foregroundStyle(Palette.fg)
                    Text("Exactly which instruction files each harness reads for a repo, in the order they load.").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
                }
                Spacer()
                Picker("Repo", selection: $repo) {
                    ForEach(repoChoices, id: \.self) { r in Text(r).font(Type.mono(12)).tag(r) }
                }
                .labelsHidden().frame(maxWidth: 420)
                .onChange(of: repo) { _, r in
                    guard !r.isEmpty, r != budget?.loadPreview?.repo else { return }
                    store.budgetRepo = r
                    Task { await store.refreshBudget(repo: r) }
                }
            }
            if let lp = budget?.loadPreview {
                HStack(alignment: .top, spacing: 32) {
                    ForEach(store.managedHarnesses) { h in
                        previewColumn(h, lp.harnesses[h.id]).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else if store.budget.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Computing…").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
            } else {
                Text("Pick a repo to see what each harness loads.").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var repoChoices: [String] {
        var out = store.inventory.value?.repos.map(\.path) ?? []
        if let r = budget?.loadPreview?.repo, !out.contains(r) { out.insert(r, at: 0) }
        if !repo.isEmpty, !out.contains(repo) { out.insert(repo, at: 0) }
        return out
    }

    private func previewColumn(_ h: Harness, _ p: LoadPreviewHarness?) -> some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) { HarnessDot(slot: store.colorSlot(for: h.id)); Text("\(h.name) loads \(p?.files.count ?? 0) file\(p?.files.count == 1 ? "" : "s")").font(Type.base(.semibold)).foregroundStyle(Palette.fg) }
                Spacer()
                Text(Fmt.int(p?.total ?? 0)).font(Type.base(.semibold)).foregroundStyle(Palette.fg)
            }
            .frame(height: 32)
            Hairline()
            ForEach(Array((p?.files ?? []).enumerated()), id: \.offset) { i, f in
                let drift = f.reason.contains("drift")
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(width: 14, alignment: .leading)
                    if f.reason.contains("@import") { Text("↳").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
                    Text(f.path).font(Type.mono(12)).foregroundStyle(Palette.fg).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(f.reason).font(Type.xs()).foregroundStyle(drift ? Palette.warn : Palette.fgTertiary)
                    Text(Fmt.int(f.tokens)).font(Type.sm(drift ? .semibold : .regular)).foregroundStyle(Palette.fg).frame(width: 60, alignment: .trailing)
                }
                .frame(height: 28)
                .padding(.horizontal, 6)
                .background(drift ? Palette.warnSoft : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Hairline()
            }
            if (p?.files ?? []).isEmpty { Text("Nothing loads for this repo.").font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(height: 28) }
            Text(notLoaded(h)).font(Type.xs()).foregroundStyle(Palette.fgTertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notLoaded(_ h: Harness) -> String {
        if h.id == "codex" {
            let total = budget?.loadPreview?.harnesses["codex"]?.total ?? 0
            return "Not loaded: ~/.claude/rules/*, CLAUDE.md files, anything below the cwd. 32 KiB cap: \(Fmt.percent(total * 4, of: 32768)) used."
        }
        let nested = (store.inventory.value?.instructions ?? []).filter { $0.scope == "repo" && $0.owner != "" && repo.hasPrefix($0.owner) && $0.name.hasPrefix("CLAUDE") && !$0.path.hasPrefix(repo) }
        if let n = nested.first { return "Not loaded: \(n.rel) (nested; loads when Claude reads files there)." }
        return "Nested CLAUDE.md files load only when Claude reads files in that directory."
    }
}
