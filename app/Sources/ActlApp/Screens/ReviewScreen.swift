// Review changes: the plan grouped by harness, per-item toggles, consequences, diffs, choice pickers,
// Apply N with streaming progress, results with Undo all, and "Show the exact commands".

import ActlCore
import SwiftUI

struct ReviewScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    @State private var showCommands = false

    private var plan: Plan? { store.plan.value }
    private var selectedCount: Int { plan.map { store.selection.count(in: $0) } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Review changes", count: nil, subtitle: subtitle) {
                Button("Edit manifest") { External.openInTerminal(store.manifestPath) }
                Button {
                    store.applySelected()
                } label: {
                    HStack(spacing: 6) { Text("Apply \(selectedCount) change\(selectedCount == 1 ? "" : "s")"); KeyHint(text: "⌘↩").foregroundStyle(.white.opacity(0.7)) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selectedCount == 0 || (store.applyRun != nil && !store.applyRun!.isFinished))
            }
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        summaryBlock.padding(.bottom, 20)
                        manifestBanner
                        groups
                    }
                    .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VHairline()
                rail.frame(width: 360)
            }
        }
    }

    private var subtitle: String? {
        guard let p = plan else { return store.plan.isLoading ? "planning…" : nil }
        return "manifest vs this Mac · \(p.actions.count) difference\(p.actions.count == 1 ? "" : "s") · \(selectedCount) selected"
    }

    // MARK: Summary

    @ViewBuilder
    private var summaryBlock: some View {
        if let p = plan {
            VStack(alignment: .leading, spacing: 6) {
                Text(ReviewCopy.headline(plan: p, selection: store.selection, store: store)).font(Type.lg()).tracking(-0.4).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                Text("Nothing here touches secrets. Files are backed up to ~/.config/actl/backups before they are edited, and every step can be undone from Activity.").font(Type.base()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
            }
        } else if let e = store.plan.error {
            InlineError(message: e, retry: { Task { await store.refreshPlan() } })
        } else {
            SkeletonLine(width: 520, height: 20); SkeletonLine(width: 600, height: 13)
        }
    }

    @ViewBuilder
    private var manifestBanner: some View {
        if let p = plan, !p.manifestErrors.isEmpty {
            NoteWell(icon: .failed, tint: Palette.error, text: "The manifest has errors and is being ignored: " + p.manifestErrors.joined(separator: "; ") + ". Fix \(p.manifestPath) or adopt again.")
                .padding(.bottom, 16)
        } else if let p = plan, !p.manifestExists, !p.actions.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Icon(.instructions, size: 14, color: Palette.fgSecondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text("No manifest yet, so these are suggestions rather than drift.").font(Type.base(.medium)).foregroundStyle(Palette.fg)
                    Text("Adopt your current setup to record it as intent, exactly as it is; nothing else changes. After that, Review shows only what differs from what you meant.").font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Adopt current setup") { Task { _ = await store.adoptManifest() } }.controlSize(.small)
                }
            }
            .padding(12)
            .background(Palette.bgSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .padding(.bottom, 16)
        }
    }

    // MARK: Groups

    @ViewBuilder
    private var groups: some View {
        if let p = plan {
            if p.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !p.manifestExists {
                        Text("No manifest yet").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                        Text("Adopt your current setup as the manifest; nothing on disk changes until you review a plan and press Apply.").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
                        Button("Adopt current setup") { Task { _ = await store.adoptManifest() } }.buttonStyle(.borderedProminent)
                    } else {
                        StatusLabel(icon: .connected, word: "This Mac matches the manifest. Nothing to apply.", color: Palette.ok, font: Type.base(.medium), iconSize: 16)
                    }
                }
                .padding(.top, 8)
            } else {
                ForEach(p.groupedByHarness(), id: \.harness) { g in
                    groupHeader(g.harness, count: g.actions.count)
                    ForEach(g.actions) { a in
                        PlanRow(action: a, isRunning: store.applyRun?.states[a.id] == .running, runState: store.applyRun?.states[a.id])
                        Hairline()
                    }
                }
            }
        }
    }

    private func groupHeader(_ harness: String, count: Int) -> some View {
        HStack(spacing: 8) {
            if harness == "proxy" || harness == "other" {
                RoundedRectangle(cornerRadius: 2).fill(Palette.fgTertiary).frame(width: 8, height: 8)
                SectionLabel(text: "\(harness == "proxy" ? "Proxy" : "Other") · \(count) change\(count == 1 ? "" : "s")")
            } else {
                HarnessDot(slot: store.colorSlot(for: harness))
                SectionLabel(text: "\(store.harness(harness)?.name ?? harness) · \(count) change\(count == 1 ? "" : "s")")
            }
        }
        .frame(height: 32).padding(.top, 8)
    }

    // MARK: Rail

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                orderList
                if showCommands { commands }
                if let run = store.applyRun { ApplyProgressCard(run: run) }
            }
            .padding(24)
        }
    }

    private var orderList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What happens, in order").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
            let steps = ReviewCopy.steps(plan: plan, selection: store.selection, store: store)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(width: 12, alignment: .leading)
                    Text(s).font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(showCommands ? "Hide the exact commands" : "Show the exact commands") { showCommands.toggle() }
                .buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent).padding(.top, 2)
        }
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ReviewCopy.commands(plan: plan, selection: store.selection), id: \.self) { c in CommandWell(command: c) }
        }
    }
}

struct PlanRow: View {
    @Environment(AppStore.self) private var store
    var action: PlanAction
    var isRunning: Bool
    var runState: StepState?
    @State private var showDiff = false

    private var selected: Bool { store.selection.isSelected(action) }

    var body: some View {
        @Bindable var store = store
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { selected }, set: { store.selection.set(action, selected: $0) }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!store.selection.canSelect(action) && !selected)
                .padding(.top, 2)
                .accessibilityLabel("Include \(action.title)")
            Text(groupWord).font(Type.xs(.medium)).foregroundStyle(Palette.fgSecondary)
                .frame(width: 84).frame(height: 20)
                .background(Palette.bgSunken, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let s = serviceMark { ServiceMark(s, size: 16) }
                    Text(action.title).font(Type.base(.medium)).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                }
                if let d = action.detail { Text(d).font(Type.xs()).foregroundStyle(Palette.fgTertiary).fixedSize(horizontal: false, vertical: true) }
                if let c = action.consequence, isLongConsequence {
                    Text(c).font(Type.xs()).foregroundStyle(consequenceColor).fixedSize(horizontal: false, vertical: true)
                }
                if let c = action.requiresChoice { choicePicker(c) }
                if let diff = action.diff, showDiff || action.requiresChoice == nil { DiffView(diff: diff).padding(.top, 4) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 12)
        .opacity(runState == .skipped ? 0.5 : 1)
        .accessibilityElement(children: .contain)
    }

    private var groupWord: String {
        switch action.group {
        case .instructions: return "Instructions"
        case .skills: return "Skills"
        case .services: return "Services"
        case .plugins: return "Plugins"
        case .proxy: return "Update"
        case .other: return "Change"
        }
    }

    private var serviceMark: Service? {
        guard action.group == .services || action.group == .plugins else { return nil }
        return store.services.value?.first { action.title.localizedCaseInsensitiveContains($0.name) || action.id.contains($0.id) }
    }

    @ViewBuilder
    private var trailing: some View {
        if let runState {
            switch runState {
            case .running: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Running").font(Type.sm()).foregroundStyle(Palette.fgSecondary) }
            case .ok: StatusLabel(icon: .connected, word: "Done", color: Palette.ok)
            case .failed: StatusLabel(icon: .failed, word: "Failed", color: Palette.error)
            case .skipped: Text("Skipped").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
            }
        } else if let d = action.tokensDelta, d != 0 {
            Text(Fmt.tokensDelta(d)).font(Type.sm(.medium)).foregroundStyle(d < 0 ? Palette.ok : Palette.warn).frame(maxWidth: 170, alignment: .trailing)
        } else if let c = action.consequence, !isLongConsequence {
            Text(c).font(Type.sm(.medium)).foregroundStyle(consequenceColor).multilineTextAlignment(.trailing).frame(maxWidth: 170, alignment: .trailing)
        }
    }

    private var isLongConsequence: Bool { (action.consequence?.count ?? 0) > 36 }

    private var consequenceColor: Color {
        if let d = action.tokensDelta, d < 0 { return Palette.ok }
        if action.kind == .proxyUpdate { return Palette.warn }
        return Palette.fgSecondary
    }

    private func choicePicker(_ c: PlanChoice) -> some View {
        HStack(spacing: 0) {
            ForEach(c.options) { o in
                Button {
                    store.selection.choose(o.id, for: action)
                } label: {
                    Text(o.label).font(Type.sm(.medium))
                        .foregroundStyle(store.selection.choice(for: action) == o.id ? Palette.fg : Palette.fgSecondary)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(store.selection.choice(for: action) == o.id ? Palette.bg : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(store.selection.choice(for: action) == o.id ? Palette.border : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if action.diff != nil {
                Button(showDiff ? "Hide diff" : "Diff…") { showDiff.toggle() }.buttonStyle(.plain).font(Type.sm(.medium)).foregroundStyle(Palette.fgSecondary).padding(.horizontal, 10)
            }
        }
        .padding(2)
        .background(Palette.bgSunken, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.top, 4)
    }
}

struct DiffView: View {
    var diff: PlanDiff
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.before.split(separator: "\n", omittingEmptySubsequences: false), id: \.self) { l in
                Text("- " + l).font(Type.mono(12)).foregroundStyle(Palette.fg).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 3).background(Palette.diffRemoved)
            }
            ForEach(diff.after.split(separator: "\n", omittingEmptySubsequences: false), id: \.self) { l in
                Text("+ " + l).font(Type.mono(12)).foregroundStyle(Palette.fg).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 3).background(Palette.diffAdded)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("Diff of \(diff.path): before \(diff.before); after \(diff.after)")
    }
}

/// While applying: progress bar and a checklist; after: the result with Undo all.
struct ApplyProgressCard: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    var run: ApplyRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if run.isFinished { finished } else { progress }
        }
        .padding(16)
        .card(radius: Radius.lg)
    }

    private var titleFor: (String) -> String {
        { id in store.plan.value?.actions.first { $0.id == id }?.title ?? store.activity.value?.flatMap(\.actions).first { $0.id == id }?.title ?? id }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: run.isUndo ? "Undoing" : "While applying")
                Spacer()
                Text("\(run.completed) of \(run.actionIds.count) · \(Int(Date().timeIntervalSince(run.startedAt))) s").font(Type.xs()).foregroundStyle(Palette.fgTertiary)
            }
            ProgressView(value: Double(run.completed), total: Double(max(run.actionIds.count, 1))).tint(Palette.accent)
            ForEach(run.actionIds, id: \.self) { id in
                HStack(spacing: 8) {
                    switch run.states[id] {
                    case .ok: Icon(.connected, size: 14, color: Palette.ok)
                    case .failed: Icon(.failed, size: 14, color: Palette.error)
                    case .running: ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    case .skipped: Icon(.blocked, size: 14, color: Palette.fgTertiary)
                    case nil: Circle().strokeBorder(Palette.borderStrong, lineWidth: 1.4).frame(width: 12, height: 12).padding(1)
                    }
                    Text(titleFor(id)).font(Type.sm()).foregroundStyle(run.states[id] == nil ? Palette.fgTertiary : Palette.fg).lineLimit(1)
                }
            }
            if run.backupDir != nil {
                Text("Backed up \(run.backupFiles.count) file\(run.backupFiles.count == 1 ? "" : "s") to \(run.backupDir!)").font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(2)
            }
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: run.isUndo ? "After undoing" : "After applying")
            if let e = run.error {
                StatusLabel(icon: .failed, word: "Stopped", color: Palette.error, font: Type.base(.medium), iconSize: 16)
                Text(e).font(Type.sm()).foregroundStyle(Palette.fgSecondary).textSelection(.enabled)
            } else if let r = run.result {
                StatusLabel(icon: r.failed == 0 ? .connected : .failed, word: "\(run.isUndo ? "Restored" : "Applied") \(r.ok) change\(r.ok == 1 ? "" : "s") in \(String(format: "%.1f", Double(r.tookMs) / 1000)) s" + (r.failed > 0 ? " · \(r.failed) failed" : ""), color: r.failed == 0 ? Palette.ok : Palette.error, font: Type.base(.medium), iconSize: 16)
                Text(ReviewCopy.afterApply(store)).font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !run.isUndo, run.error == nil, !run.runId.isEmpty {
                    Button("Undo all") { store.undo(runId: run.runId) }
                }
                Button("Show log") { nav.go(.activity) }
                Button("Dismiss") { store.dismissApplyRun() }.buttonStyle(.plain).foregroundStyle(Palette.fgTertiary)
            }
        }
    }
}

enum ReviewCopy {
    @MainActor
    static func headline(plan: Plan, selection: PlanSelection, store: AppStore) -> String {
        let n = selection.count(in: plan)
        if plan.actions.isEmpty { return plan.manifestExists ? "Nothing to apply." : "No manifest to compare against yet." }
        if n == 0 {
            let lazy = plan.actions.filter { $0.kind == .serviceMakeLazy }.count
            let saves = plan.actions.filter { $0.kind == .serviceMakeLazy }.reduce(0) { $0 + ($1.tokensDelta ?? 0) }
            if lazy > 0, saves < 0 { return "Nothing selected. \(lazy) service\(lazy == 1 ? "" : "s") could go lazy for \(Fmt.compact(-saves)) fewer tokens per session." }
            return "Nothing selected. Tick the changes you want to apply."
        }
        var parts: [String] = []
        let deltas = selection.tokensDelta(in: plan)
        for (h, d) in deltas.sorted(by: { $0.key < $1.key }) where d < 0 {
            parts.append("saves \(Fmt.compact(-d)) tokens per \(store.harness(h)?.name.split(separator: " ").first.map(String.init) ?? h.capitalized) session")
        }
        let selected = plan.actions.filter { selection.isSelected($0) }
        let gaps = selected.filter { $0.kind == .mcpAdd || $0.kind == .pluginInstall || $0.consequence?.localizedCaseInsensitiveContains("gap") == true }.count
        if gaps > 0 { parts.append("closes \(gaps) gap\(gaps == 1 ? "" : "s")") }
        if selected.contains(where: { $0.kind == .proxyUpdate }) { parts.append("restarts the proxy once") }
        let syncs = selected.filter { $0.kind == .skillsSync || $0.kind == .skillsResolveConflict }.count
        if syncs > 0 && parts.count < 3 { parts.append("syncs skills") }
        if parts.isEmpty { return "Applying makes \(n) change\(n == 1 ? "" : "s")." }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + ", and " + parts.last! : parts[0]
        return "Applying " + list + "."
    }

    @MainActor
    static func steps(plan: Plan?, selection: PlanSelection, store: AppStore) -> [String] {
        guard let plan else { return [] }
        let selected = plan.actions.filter { selection.isSelected($0) }
        var steps: [String] = []
        let files = Set(selected.compactMap { $0.diff?.path } + selected.filter { $0.group == .skills }.map { _ in "~/.claude/skills/.actl-sync.json" }).count
        steps.append("Back up \(max(files, selected.isEmpty ? 0 : 1)) file\(files == 1 ? "" : "s") to ~/.config/actl/backups/<run>")
        if selected.contains(where: { $0.group == .skills }) { steps.append("Copy skills, write .actl-sync.json") }
        let edits = selected.filter { $0.group == .instructions || $0.group == .services || $0.group == .plugins }
        if !edits.isEmpty { steps.append("Edit " + Set(edits.compactMap { $0.diff?.path ?? defaultFile($0) }).sorted().joined(separator: ", ")) }
        if selected.contains(where: { $0.kind == .proxyUpdate }) { steps.append("brew upgrade cliproxyapi, restart, wait for /health") }
        steps.append("Re-check both harnesses and update the plan")
        return steps
    }

    private static func defaultFile(_ a: PlanAction) -> String? {
        switch a.harness { case "claude": return "~/.claude.json"; case "codex": return "~/.codex/config.toml"; default: return nil }
    }

    static func commands(plan: Plan?, selection: PlanSelection) -> [String] {
        guard let plan else { return [] }
        let ids = selection.actionIds(in: plan)
        var out = ["actl apply " + ids.joined(separator: " ")]
        for a in plan.actions where ids.contains(a.id) {
            switch a.kind {
            case .pluginInstall: out.append("\(a.harness ?? "claude") plugin install \(a.id.split(separator: ":").last ?? "")")
            case .pluginUninstall: out.append("\(a.harness ?? "claude") plugin uninstall \(a.id.split(separator: ":").last ?? "")")
            case .mcpAdd: out.append("\(a.harness ?? "codex") mcp add \(a.id.split(separator: ":").last ?? "")")
            case .mcpRemove: out.append("\(a.harness ?? "claude") mcp remove \(a.id.split(separator: ":").last ?? "")")
            case .proxyUpdate: out.append("brew upgrade cliproxyapi")
            case .skillsSync: out.append("actl skills apply")
            case .instructionsMode: out.append("claude config set instructionFiles claude-md-and-agents-md")
            default: break
            }
        }
        return out
    }

    @MainActor
    static func afterApply(_ store: AppStore) -> String {
        var parts: [String] = []
        if let b = store.budget.value {
            for h in store.managedHarnesses { if let t = b.harnesses[h.id]?.total { parts.append("\(h.name.split(separator: " ").first ?? "") now spends \(Fmt.compact(t)) tokens before you type") } }
        }
        if let p = store.proxy.value, let v = p.installedVersion { parts.append("Proxy is on \(v)") }
        if let plan = store.plan.value, let pending = plan.actions.first(where: { $0.requiresChoice != nil }) {
            parts.append("One item still needs a decision: \(pending.title.split(separator: " ").first ?? "")")
        }
        return parts.joined(separator: ". ") + (parts.isEmpty ? "" : ".")
    }
}
