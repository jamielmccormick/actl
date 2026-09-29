// Instructions: files per repo and global, with which harness loads each one.

import ActlCore
import SwiftUI

struct InstructionsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav

    private var files: [InstructionFile] { store.inventory.value?.instructions ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Instructions", count: files.isEmpty ? nil : files.count, subtitle: subtitle) {
                Button("Load preview") { nav.go(.contextBudget) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.inventory.value == nil {
                        if let e = store.inventory.error { InlineError(message: e, retry: { Task { await store.refreshInventory(force: true) } }) }
                        else { VStack(spacing: 12) { ForEach(0..<5, id: \.self) { _ in HStack { SkeletonLine(width: 220); Spacer(); SkeletonLine(width: 60) } } } }
                    } else if files.isEmpty {
                        Text("No instruction files found. AGENTS.md, CLAUDE.md, CLAUDE.local.md and .claude/rules are listed here.").font(Type.base()).foregroundStyle(Palette.fgTertiary)
                    } else {
                        group("Global", files.filter { $0.scope == "global" })
                        ForEach(owners, id: \.self) { owner in
                            group(owner, files.filter { $0.scope != "global" && $0.owner == owner })
                        }
                        note
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var owners: [String] {
        var seen: [String] = []
        for f in files where f.scope != "global" && !seen.contains(f.owner) { seen.append(f.owner) }
        return seen
    }

    private var subtitle: String? {
        guard !files.isEmpty else { return nil }
        let both = files.filter { $0.loadedBy.count >= 2 }.count
        let tokens = files.reduce(0) { $0 + $1.estimatedTokens }
        return "\(both) read by both harnesses · \(Fmt.compact(tokens)) tokens on disk · \(owners.count) repo\(owners.count == 1 ? "" : "s")"
    }

    private func group(_ title: String, _ list: [InstructionFile]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SectionLabel(text: title)
                Spacer()
                SectionLabel(text: "Loaded by").frame(width: 150, alignment: .leading)
                SectionLabel(text: "Lines").frame(width: 60, alignment: .trailing)
                SectionLabel(text: "≈ Tokens").frame(width: 80, alignment: .trailing)
            }
            .frame(height: 32)
            Hairline()
            ForEach(list) { f in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(f.scope == "global" ? f.path : f.rel).font(Type.mono(12)).foregroundStyle(Palette.fg).lineLimit(1).truncationMode(.middle)
                            if f.pathScoped { tag("path-scoped", Palette.ok) }
                            if !f.imports.isEmpty { tag("@imports \(f.imports.count)", Palette.fgSecondary) }
                            if f.scope != "global" && !f.tracked { tag("untracked", Palette.fgTertiary) }
                            if isDrift(f) { tag("drift", Palette.warn) }
                        }
                        if !f.preview.isEmpty {
                            Text(f.preview.replacingOccurrences(of: "\n", with: " ")).font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(1)
                        }
                    }
                    Spacer()
                    loadedBy(f).frame(width: 150, alignment: .leading)
                    Text(Fmt.int(f.lines)).font(Type.sm()).foregroundStyle(Palette.fgSecondary).frame(width: 60, alignment: .trailing)
                    Text(Fmt.int(f.estimatedTokens)).font(Type.sm(isDrift(f) ? .semibold : .regular)).foregroundStyle(isDrift(f) ? Palette.warn : Palette.fg).frame(width: 80, alignment: .trailing)
                }
                .frame(height: 44)
                .contextMenu {
                    Button("Reveal in Finder") { External.revealInFinder(f.path) }
                    Button("Open in Terminal") { External.openInTerminal(f.path) }
                }
                Hairline()
            }
        }
    }

    private func isDrift(_ f: InstructionFile) -> Bool {
        store.plan.value?.actions.contains { $0.kind == .ruleRescope && ($0.diff?.path == f.path || $0.detail?.contains(f.path) == true) } ?? false
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(Type.xs(.medium)).foregroundStyle(color).padding(.horizontal, 6).frame(height: 18)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func loadedBy(_ f: InstructionFile) -> some View {
        HStack(spacing: 6) {
            ForEach(store.managedHarnesses) { h in
                if f.loadedBy.contains(h.id) {
                    HarnessChip(harness: h, slot: store.colorSlot(for: h.id), size: 14)
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Palette.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 14, height: 14)
                        .accessibilityLabel("Not loaded by \(h.name)")
                }
            }
            Text(f.loadedBy.compactMap { store.harness($0)?.name }.joined(separator: " + ").isEmpty ? "Neither" : f.loadedBy.compactMap { store.harness($0)?.name.split(separator: " ").first.map(String.init) }.joined(separator: " + "))
                .font(Type.sm()).foregroundStyle(Palette.fgSecondary)
        }
    }

    private var note: some View {
        NoteWell(icon: .instructions, tint: Palette.fgSecondary, text: "Claude Code reads CLAUDE.md, and AGENTS.md when there is no CLAUDE file; nested files load when it reads files in that directory, and @imports follow up to 4 hops. Codex reads AGENTS.md from the git root down to the cwd, with a 32 KiB combined cap. Load preview in Context budget shows the exact order for one repo.")
    }
}

// MARK: - Activity

struct ActivityScreen: View {
    @Environment(AppStore.self) private var store
    @State private var now = Date()

    private var entries: [ActivityEntry] { store.activity.value ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Activity", count: entries.isEmpty ? nil : entries.count, subtitle: entries.isEmpty ? nil : "runs, watches and automatic changes · newest first") {
                Button("Reveal log") { External.revealInFinder("~/.config/actl/activity.jsonl") }
            }
            ScrollView {
                VStack(spacing: 0) {
                    if let run = store.applyRun {
                        ApplyProgressCard(run: run).padding(.bottom, 20)
                    }
                    if store.activity.value == nil {
                        if let e = store.activity.error { InlineError(message: e, retry: { Task { await store.refreshActivity() } }) }
                        else { ForEach(0..<4, id: \.self) { _ in HStack { SkeletonLine(width: 60); SkeletonLine(width: 400); Spacer() }.frame(height: 52); Hairline() } }
                    } else if entries.isEmpty {
                        Text("No runs yet. Applied changes, undo, and automatic checks are recorded in ~/.config/actl/activity.jsonl.").font(Type.base()).foregroundStyle(Palette.fgTertiary).frame(height: 60)
                    } else {
                        ForEach(entries) { e in
                            row(e)
                            Hairline()
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 20)
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private func row(_ e: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.date.map { Fmt.timeOrDay($0, now: now) } ?? "").font(Type.sm()).foregroundStyle(Palette.fg)
                Text(sourceWord(e.source)).font(Type.xs()).foregroundStyle(Palette.fgTertiary)
            }
            .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(e.actions) { a in
                    HStack(spacing: 8) {
                        Icon(a.state == .ok ? .connected : (a.state == .failed ? (e.source == .watch ? .drift : .failed) : .blocked), size: 14, color: a.state == .ok ? Palette.ok : (a.state == .failed ? (e.source == .watch ? Palette.warn : Palette.error) : Palette.fgTertiary))
                        Text(a.title).font(Type.base()).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("run \(e.runId)" + (e.undoneAt.flatMap(ISO8601.parse).map { " · undone \(Fmt.timeOrDay($0, now: now))" } ?? "")).font(Type.xs()).foregroundStyle(Palette.fgTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                ActivityState(entry: e)
                if e.undoable && e.undoneAt == nil {
                    Button("Undo") { store.undo(runId: e.runId) }.controlSize(.small)
                        .disabled(store.applyRun != nil && !store.applyRun!.isFinished)
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private func sourceWord(_ s: ActivitySource) -> String {
        switch s { case .user: return "You applied"; case .watch: return "Watch"; case .auto: return "Automatic" }
    }
}
