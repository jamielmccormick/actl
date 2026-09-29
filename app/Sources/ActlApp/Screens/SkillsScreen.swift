// Skills: grouped by source (canonical, Claude plugins, repos), sync state per harness,
// the conflict resolution choice, and Sync.

import ActlCore
import SwiftUI

struct SkillsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    @State private var mode = "source"
    @State private var expanded: Set<String> = []
    @State private var resolving: String?

    private var skills: [Skill] { store.skillsWithState }
    private var pending: [Skill] { skills.filter { $0.syncState == "pending" } }
    private var conflicts: [Skill] { skills.filter { $0.syncState == "conflict" } }
    private var syncAction: PlanAction? { store.plan.value?.actions.first { $0.kind == .skillsSync } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Skills", count: skills.isEmpty ? nil : skills.count, subtitle: subtitle) {
                FilterSwitcher(options: [("source", "By source"), ("attention", "Needs attention"), ("az", "A–Z")], selection: $mode)
                if let a = syncAction {
                    Button("Sync \(pending.count > 0 ? "\(pending.count) " : "")to Claude") { store.apply(actionIds: [a.id]) }.buttonStyle(.borderedProminent)
                        .disabled(store.applyRun != nil && !store.applyRun!.isFinished)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.inventory.value == nil {
                        if let e = store.inventory.error { InlineError(message: e, retry: { Task { await store.refreshInventory(force: true) } }) } else { skeleton }
                    } else if skills.isEmpty {
                        Text("No skills found in ~/.agents/skills, ~/.claude/skills or ~/.codex/skills.").font(Type.base()).foregroundStyle(Palette.fgTertiary)
                    } else {
                        switch mode {
                        case "attention": group("Needs attention", skills.filter { $0.syncState == "pending" || $0.syncState == "conflict" || $0.broken }, columns: ("Claude Code", "Codex", "State"), key: "attention")
                        case "az": group("All skills · A–Z", skills.sorted { $0.name < $1.name }, columns: ("Claude Code", "Codex", "State"), key: "az")
                        default: bySource
                        }
                        decisions
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var subtitle: String? {
        guard !skills.isEmpty else { return store.inventory.isLoading ? "counting…" : nil }
        let inSync = skills.filter { $0.syncState == "in-sync" || ($0.syncState == nil && $0.visibleIn.claude && $0.visibleIn.codex) }.count
        let one = skills.filter { $0.visibleIn.claude != $0.visibleIn.codex }.count
        return "\(inSync) in sync · \(pending.count) pending · \(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s") · \(one) in one harness"
    }

    private var skeleton: some View {
        VStack(spacing: 12) { ForEach(0..<6, id: \.self) { _ in HStack { SkeletonLine(width: 160); Spacer(); SkeletonLine(width: 80); SkeletonLine(width: 80) } } }
    }

    // MARK: By source

    private var bySource: some View {
        let canonical = skills.filter { $0.source == "agents-user" }
        let claudeOnly = skills.filter { $0.source == "claude-user" }
        let codexLegacy = skills.filter { $0.source == "codex-user" }
        let plugins = skills.filter { $0.source == "claude-plugin" || $0.source == "codex-plugin" }
        let repo = skills.filter { $0.source == "agents-project" || $0.source == "claude-project" }
        return VStack(alignment: .leading, spacing: 28) {
            if !canonical.isEmpty { group("~/.agents/skills · canonical · \(canonical.count)", canonical, columns: ("Claude Code", "Codex", "State"), key: "canonical") }
            if !claudeOnly.isEmpty { group("~/.claude/skills · only here, promoted to ~/.agents on sync · \(claudeOnly.count)", claudeOnly, columns: ("Claude Code", "Codex", "State"), key: "claude-user") }
            if !codexLegacy.isEmpty { group("~/.codex/skills · legacy · \(codexLegacy.count)", codexLegacy, columns: ("Claude Code", "Codex", "State"), key: "codex-user") }
            if !plugins.isEmpty { pluginGroup(plugins) }
            repoGroup(repo)
        }
    }

    private func group(_ title: String, _ list: [Skill], columns: (String, String, String), key: String) -> some View {
        let sorted = list.sorted { rank($0) < rank($1) }
        let isOpen = expanded.contains(key)
        let attention = sorted.filter { rank($0) < 3 }
        let shown: [Skill] = isOpen ? sorted : (attention.isEmpty ? Array(sorted.prefix(6)) : attention)
        let rest = sorted.filter { s in !shown.contains { $0.id == s.id } }
        return VStack(spacing: 0) {
            header(title, columns: columns)
            Hairline()
            ForEach(shown) { s in
                skillRow(s)
                Hairline()
            }
            if !rest.isEmpty {
                let allBoth = rest.allSatisfy { $0.visibleIn.claude && $0.visibleIn.codex }
                HStack(spacing: 8) {
                    Text(rest.prefix(4).map(\.name).joined(separator: ", ") + (rest.count > 4 ? " … +\(rest.count - 4)" : "")).font(Type.mono(12)).foregroundStyle(Palette.fg).lineLimit(1)
                    Spacer()
                    Group {
                        if allBoth { StatusLabel(icon: .connected, word: "In sync", color: Palette.ok) }
                        else { Text(rest.allSatisfy(\.visibleIn.claude) ? "Visible" : "mixed").font(Type.sm()).foregroundStyle(Palette.fgSecondary) }
                    }
                    .frame(width: 130, alignment: .leading)
                    Text(rest.allSatisfy(\.visibleIn.codex) ? "Canonical" : (rest.contains(where: \.visibleIn.codex) ? "mixed" : "Not available")).font(Type.sm()).foregroundStyle(rest.allSatisfy(\.visibleIn.codex) ? Palette.ok : Palette.fgTertiary).frame(width: 130, alignment: .leading)
                    Button("Show \(rest.count) more") { expanded.insert(key) }.buttonStyle(.plain).font(Type.sm()).foregroundStyle(Palette.fgSecondary).frame(width: 130, alignment: .trailing)
                }
                .frame(height: 36)
                Hairline()
            } else if isOpen && sorted.count > 6 {
                Button("Show less") { expanded.remove(key) }.buttonStyle(.plain).font(Type.sm()).foregroundStyle(Palette.fgSecondary).frame(maxWidth: .infinity, alignment: .trailing).frame(height: 32)
            }
        }
    }

    private func rank(_ s: Skill) -> Int {
        switch s.syncState { case "conflict": return 0; case "pending": return 1; default: return s.broken ? 2 : (s.visibleIn.claude != s.visibleIn.codex ? 3 : 4) }
    }

    private func header(_ title: String, columns: (String, String, String)) -> some View {
        HStack(spacing: 8) {
            SectionLabel(text: title)
            Spacer()
            HStack(spacing: 6) { HarnessDot(slot: store.colorSlot(for: "claude")); SectionLabel(text: columns.0) }.frame(width: 130, alignment: .leading)
            HStack(spacing: 6) { HarnessDot(slot: store.colorSlot(for: "codex")); SectionLabel(text: columns.1) }.frame(width: 130, alignment: .leading)
            SectionLabel(text: columns.2).frame(width: 130, alignment: .trailing)
        }
        .frame(height: 32)
    }

    private func skillRow(_ s: Skill) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(s.name).font(Type.mono(12)).foregroundStyle(Palette.fg).lineLimit(1)
                if s.broken { Text("broken link").font(Type.xs()).foregroundStyle(Palette.error) }
            }
            Spacer()
            claudeCell(s).frame(width: 130, alignment: .leading)
            codexCell(s).frame(width: 130, alignment: .leading)
            stateCell(s).frame(width: 130, alignment: .trailing)
        }
        .frame(height: 36)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func claudeCell(_ s: Skill) -> some View {
        switch s.syncState {
        case "conflict": Text("Edited in place").font(Type.sm(.medium)).foregroundStyle(Palette.error)
        case "pending": Text("Pending copy").font(Type.sm(.medium)).foregroundStyle(Palette.warn)
        default:
            if s.source == "claude-plugin" { Text("Via plugin").font(Type.sm()).foregroundStyle(Palette.accent) }
            else if s.source == "codex-plugin" { Text("Not available").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
            else if s.visibleIn.claude { Text(s.source == "claude-user" || s.source == "claude-project" ? "Canonical" : "In sync").font(Type.sm()).foregroundStyle(Palette.ok) }
            else if s.source == "agents-user" { Text("No copy yet").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
            else { Text("Not visible").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
        }
    }

    @ViewBuilder
    private func codexCell(_ s: Skill) -> some View {
        if s.codexDisabled { Text("Disabled").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
        else if s.source == "codex-plugin" { Text("Via plugin").font(Type.sm()).foregroundStyle(Palette.accent) }
        else if s.source == "agents-user" || s.source == "agents-project" || s.source == "codex-user" { Text("Canonical").font(Type.sm()).foregroundStyle(Palette.ok) }
        else if s.visibleIn.codex { Text("In sync").font(Type.sm()).foregroundStyle(Palette.ok) }
        else { Text("Not available").font(Type.sm()).foregroundStyle(Palette.fgTertiary) }
    }

    @ViewBuilder
    private func stateCell(_ s: Skill) -> some View {
        if s.syncState == "conflict" {
            HStack(spacing: 6) {
                Button("Diff") { nav.go(.review) }.controlSize(.small)
                Button("Resolve…") { nav.go(.review) }.controlSize(.small)
            }
        } else if s.syncState == "pending" {
            Text("changed").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
        } else if (s.source == "agents-project" || s.source == "claude-user"), s.visibleIn.claude != s.visibleIn.codex {
            Button(s.source == "claude-user" ? "Promote to ~/.agents" : "Copy to Claude") { nav.go(.review) }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent)
                .padding(.horizontal, 8).frame(height: 22).background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Text("").frame(width: 1)
        }
    }

    // Skills-only plugins live here, grouped by plugin.
    private func pluginGroup(_ list: [Skill]) -> some View {
        let byPlugin = Dictionary(grouping: list, by: \.owner)
        let serviceIds = Set((store.services.value ?? []).map(\.id))
        let names = byPlugin.keys.sorted { (serviceIds.contains($0) ? 1 : 0, $0) < (serviceIds.contains($1) ? 1 : 0, $1) }
        let isOpen = expanded.contains("plugins")
        let shown = isOpen ? names : Array(names.prefix(3))
        let levers = store.budget.value?.harnesses["claude"]?.levers ?? []
        return VStack(spacing: 0) {
            header("From plugins · skills only, not services · \(list.count)", columns: ("Claude Code", "Codex", "Always-on cost"))
            Hairline()
            ForEach(shown, id: \.self) { p in
                let items = byPlugin[p] ?? []
                let base = p.split(separator: "@").first.map(String.init) ?? p
                let isService = serviceIds.contains(base) || serviceIds.contains(p)
                let isCodex = items.first?.source == "codex-plugin"
                let cost = levers.first { $0.label.lowercased().hasPrefix(base.lowercased()) }
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ServiceMark(name: store.services.value?.first { $0.id == base }?.name ?? base, logo: store.services.value?.first { $0.id == base }?.logo, size: 16)
                        Text(base).font(Type.mono(12)).foregroundStyle(Palette.fg).lineLimit(1)
                        Text("· \(items.count) skill\(items.count == 1 ? "" : "s")" + (isService ? " · also a service" : "")).font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(1)
                    }
                    Spacer()
                    Text(isCodex ? "Not available" : "Via plugin").font(Type.sm()).foregroundStyle(isCodex ? Palette.fgTertiary : Palette.accent).frame(width: 130, alignment: .leading)
                    Text(isCodex ? "Via plugin" : (items.allSatisfy(\.visibleIn.codex) ? "In sync" : "Not available")).font(Type.sm()).foregroundStyle(isCodex ? Palette.accent : (items.allSatisfy(\.visibleIn.codex) ? Palette.ok : Palette.fgTertiary)).frame(width: 130, alignment: .leading)
                    Text(cost.map { ($0.estimated ? "~" : "") + Fmt.int($0.tokens) } ?? "—").font(Type.sm()).foregroundStyle(Palette.fg).frame(width: 130, alignment: .trailing)
                }
                .frame(height: 36)
                Hairline()
            }
            if names.count > shown.count {
                HStack {
                    Text(names.dropFirst(shown.count).prefix(6).map { $0.split(separator: "@").first.map(String.init) ?? $0 }.joined(separator: ", ") + " … +\(names.count - shown.count) plugins").font(Type.sm()).foregroundStyle(Palette.fg).lineLimit(1)
                    Spacer()
                    Text("Via plugin").font(Type.sm()).foregroundStyle(Palette.accent).frame(width: 130, alignment: .leading)
                    Text("mixed").font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(width: 130, alignment: .leading)
                    Button("Show all") { expanded.insert("plugins") }.buttonStyle(.plain).font(Type.sm()).foregroundStyle(Palette.fgSecondary).frame(width: 130, alignment: .trailing)
                }
                .frame(height: 36)
                Hairline()
            }
        }
    }

    private func repoGroup(_ list: [Skill]) -> some View {
        let byRepo = Dictionary(grouping: list, by: \.owner)
        return VStack(spacing: 0) {
            header("Repo skills · .agents/skills in \(byRepo.count) repo\(byRepo.count == 1 ? "" : "s") · \(list.count)", columns: ("Claude Code", "Codex", ""))
            Hairline()
            ForEach(byRepo.keys.sorted(), id: \.self) { repo in
                let items = byRepo[repo] ?? []
                HStack(spacing: 8) {
                    Text("\((repo as NSString).lastPathComponent) · \(items.count) skill\(items.count == 1 ? "" : "s")").font(Type.mono(12)).foregroundStyle(Palette.fg)
                    Spacer()
                    Text(items.allSatisfy(\.visibleIn.claude) ? "In sync" : "Not visible").font(Type.sm()).foregroundStyle(items.allSatisfy(\.visibleIn.claude) ? Palette.ok : Palette.fgTertiary).frame(width: 130, alignment: .leading)
                    Text("Canonical").font(Type.sm()).foregroundStyle(Palette.ok).frame(width: 130, alignment: .leading)
                    if !items.allSatisfy(\.visibleIn.claude) {
                        Button("Copy to Claude") { nav.go(.review) }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent)
                            .padding(.horizontal, 8).frame(height: 22).background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .frame(width: 130, alignment: .trailing)
                    } else { Text("").frame(width: 130) }
                }
                .frame(height: 36)
                Hairline()
            }
            if byRepo.isEmpty { Text("No repo skills. Add .agents/skills to a repo and it shows up here.").font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(height: 36) }
        }
    }

    // The two decisions from the design board.
    private var decisions: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "\u{201C}Make lazy\u{201D} · one click, no review trip")
                HStack(alignment: .top, spacing: 10) {
                    Icon(.connected, size: 14, color: Palette.ok).padding(.top, 2)
                    Text(lastLazy ?? "Switching a service to its bare MCP server drops the plugin's skill listing and per-session cost. It lands in Recent activity with Undo for 24 h, and the manifest records the choice so Review never re-proposes the plugin.").font(Type.sm()).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let run = lastLazyRun { Button("Undo") { store.undo(runId: run) }.controlSize(.small) }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.bgSunken, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Sign-in queue · auto-continue")
                Toggle(isOn: Binding(get: { store.preferences.autoContinueSignIn }, set: { store.setSignInAutoContinue($0) })) {
                    Text("Continue to the next sign-in automatically").font(Type.base()).foregroundStyle(Palette.fg)
                }
                .toggleStyle(.switch).controlSize(.small)
                Text("Default on. Off: after each \u{201C}Connected\u{201D} the sheet waits with Continue ↩ / Skip / Stop, so you can check the browser account it used before moving on.").font(Type.xs()).foregroundStyle(Palette.fgTertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.bgSunken, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
    }

    private var lastLazyEntry: ActivityEntry? {
        store.activity.value?.first { $0.actions.contains { $0.id.hasPrefix("service.make-lazy") } && $0.undoneAt == nil }
    }
    private var lastLazy: String? { lastLazyEntry.map { ($0.actions.first { $0.id.hasPrefix("service.make-lazy") }?.title ?? "") + "." } }
    private var lastLazyRun: String? { lastLazyEntry.flatMap { $0.undoable ? $0.runId : nil } }
}
