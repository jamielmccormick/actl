import ActlCore
import ActlFixtures
import Foundation
import Testing

@Suite struct EnvelopeDecoding {
    @Test func decodesStatusEnvelopeAndIgnoresUnknownFields() throws {
        let json = """
        {"schema":2,"command":"status","generatedAt":"2026-09-28T21:51:00Z","futureField":{"x":1},
         "data":{"level":"attention","harnesses":[{"id":"claude","name":"Claude Code","connected":15,"total":31,"needsSignIn":14,"failed":2,"extra":true}],
                 "attention":[{"id":"a","severity":"warn","kind":"sign-in","title":"t","fix":{"label":"Sign in…","signIn":{"harness":"claude","servers":["sentry"]}}}],
                 "checkedAt":"2026-09-28T21:51:00Z","stale":false}}
        """
        let env = try JSONDecoder().decode(Envelope<Status>.self, from: Data(json.utf8))
        #expect(env.schema == 2)
        #expect(env.command == "status")
        #expect(env.generatedAt != nil)
        #expect(env.data.level == .attention)
        #expect(env.data.harnesses.first?.needsSignIn == 14)
        #expect(env.data.attention.first?.fix?.signIn?.servers == ["sentry"])
    }

    @Test func unknownEnumValuesFallBack() throws {
        let json = """
        {"schema":2,"command":"services","data":[{"id":"x","name":"X","parity":"sideways","providers":{"claude":{"kind":"hologram","ref":"x","health":"melted","auth":"magic","canSignIn":false,"skills":[]}}}]}
        """
        let env = try JSONDecoder().decode(Envelope<[Service]>.self, from: Data(json.utf8))
        let p = try #require(env.data.first?.providers["claude"])
        #expect(p.kind == .unknown)
        #expect(p.health == .unknown)
        #expect(p.auth == .unknown)
        #expect(env.data.first?.parity == .unknown)
    }

    @Test func fixturesFollowTheContract() throws {
        for (name, type) in [("status", "status"), ("services", "services"), ("budget", "budget"), ("plan", "plan"), ("activity", "activity"), ("proxy", "proxy"), ("inventory", "inventory")] {
            let data = try #require(FixtureEngine.envelope(type, name))
            switch name {
            case "status": _ = try JSONDecoder().decode(Envelope<Status>.self, from: data)
            case "services":
                let s = try JSONDecoder().decode(Envelope<[Service]>.self, from: data).data
                #expect(s.count == 16)
                #expect(s.first { $0.id == "sentry" }?.providers["claude"]?.lazyAlternative != nil)
            case "budget":
                let b = try JSONDecoder().decode(Envelope<Budget>.self, from: data).data
                #expect(b.harnesses["claude"]?.total == 52145)
                #expect(b.loadPreview?.repo == "~/Code/acme/web")
            case "plan":
                let p = try JSONDecoder().decode(Envelope<Plan>.self, from: data).data
                #expect(p.actions.count == 10)
                #expect(p.actions.contains { $0.requiresChoice != nil })
            case "activity": _ = try JSONDecoder().decode(Envelope<[ActivityEntry]>.self, from: data)
            case "proxy":
                let p = try JSONDecoder().decode(Envelope<ProxySnapshot>.self, from: data).data
                #expect(p.accounts.count == 4)
                #expect(p.accounts.last?.state == .cooldown)
                #expect(p.updateAvailable)
            case "inventory":
                let i = try JSONDecoder().decode(Envelope<Inventory>.self, from: data).data
                #expect(i.harnesses.count == 6)
                #expect(!i.skills.isEmpty)
            default: break
            }
        }
    }

    @Test func applyEventsDecode() throws {
        let lines = [
            #"{"type":"start","runId":"r1","actions":["a","b"]}"#,
            #"{"type":"backup","runId":"r1","files":["~/.claude.json"],"dir":"~/.config/actl/backups/r1"}"#,
            #"{"type":"step","runId":"r1","actionId":"a","state":"running"}"#,
            #"{"type":"step","runId":"r1","actionId":"a","state":"ok","message":"done"}"#,
            #"{"type":"done","runId":"r1","ok":1,"failed":0,"tookMs":10}"#,
            #"{"type":"error","message":"boom"}"#,
            #"{"type":"telemetry","x":1}"#,
        ]
        let events = lines.compactMap { JSONLParser.decode(ApplyEvent.self, line: $0) }
        #expect(events.count == 7)
        #expect(events[0] == .start(runId: "r1", actions: ["a", "b"]))
        #expect(events[3] == .step(runId: "r1", actionId: "a", state: .ok, message: "done"))
        #expect(events[4].isTerminal)
        #expect(events[5] == .error(runId: nil, message: "boom"))
        #expect(events[6] == .unknown(type: "telemetry"))
    }
}

@Suite struct JSONLStreaming {
    @Test func splitsLinesAcrossChunks() {
        var p = JSONLParser()
        var out: [String] = []
        out += p.feed(Data("{\"a\":1}\n{\"b\":".utf8))
        #expect(out == ["{\"a\":1}"])
        out += p.feed(Data("2}\n\n  \n{\"c\":3}".utf8))
        #expect(out == ["{\"a\":1}", "{\"b\":2}"])
        out += p.finish()
        #expect(out == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
        #expect(p.finish().isEmpty)
    }

    @Test func ignoresNonJSONLines() {
        #expect(JSONLParser.decode(LoginEvent.self, line: "Opening browser…") == nil)
        let e = JSONLParser.decode(LoginEvent.self, line: #"{"type":"waiting","harness":"claude","server":"sentry"}"#)
        #expect(e == .waiting(harness: "claude", server: "sentry"))
    }

    @Test func fixtureEngineStreamsApplyToDone() async throws {
        let engine = FixtureEngine(delay: .zero)
        var terminal: ApplyEvent?
        var steps = 0
        for try await e in engine.events(ApplyEvent.self, ["apply", "skills.sync:user"]) {
            if case .step = e { steps += 1 }
            if e.isTerminal { terminal = e }
        }
        #expect(steps == 2)
        if case .done(_, let ok, let failed, _) = terminal { #expect(ok == 1); #expect(failed == 0) } else { Issue.record("no done event") }
    }
}

@Suite struct StatusLevelMapping {
    private func status(attention: [AttentionItem], harnesses: [StatusHarness] = []) -> Status {
        Status(level: .healthy, harnesses: harnesses, attention: attention, checkedAt: "", stale: false)
    }

    @Test func healthyWhenNothingNeedsAttention() {
        #expect(StatusLevel.derive(from: status(attention: [])) == .healthy)
    }

    @Test func attentionForWarnings() {
        let s = status(attention: [AttentionItem(id: "a", severity: .warn, kind: .signIn, title: "t")])
        #expect(StatusLevel.derive(from: s) == .attention)
    }

    @Test func errorForFailures() {
        let s = status(attention: [AttentionItem(id: "a", severity: .error, kind: .failed, title: "t")])
        #expect(StatusLevel.derive(from: s) == .error)
        let h = status(attention: [], harnesses: [StatusHarness(id: "claude", name: "Claude Code", connected: 1, total: 2, needsSignIn: 0, failed: 1)])
        #expect(StatusLevel.derive(from: h) == .error)
    }

    @Test func syncingWinsWhileRefreshing() {
        let s = status(attention: [AttentionItem(id: "a", severity: .error, kind: .failed, title: "t")])
        #expect(StatusLevel.derive(from: s, syncing: true) == .syncing)
    }

    @Test func attentionOrderedByWhatBlocksWorkFirst() {
        let items = [
            AttentionItem(id: "gap", severity: .info, kind: .gap, title: "gap"),
            AttentionItem(id: "sync", severity: .info, kind: .sync, title: "sync"),
            AttentionItem(id: "signin", severity: .warn, kind: .signIn, title: "signin"),
            AttentionItem(id: "failed", severity: .error, kind: .failed, title: "failed"),
            AttentionItem(id: "drift", severity: .warn, kind: .drift, title: "drift"),
        ]
        #expect(items.orderedByBlocking().map(\.id) == ["failed", "signin", "drift", "sync", "gap"])
    }
}

@Suite struct MonogramHashing {
    @Test func hueIsDeterministicAndInRange() {
        let a = Monogram.hue(for: "HubSpot")
        #expect(a == Monogram.hue(for: "HubSpot"))
        #expect(a >= 0 && a < 360)
        #expect(Monogram.hue(for: "HubSpot") != Monogram.hue(for: "Convex"))
        // (Σ char codes × 37) mod 360 for "Convex"
        let sum = "Convex".unicodeScalars.reduce(0) { $0 + Int($1.value) }
        #expect(Monogram.hue(for: "Convex") == Double((sum * 37) % 360))
    }

    @Test func initials() {
        #expect(Monogram.initials(for: "HubSpot") == "H")
        #expect(Monogram.initials(for: "Acme Pulse") == "AP")
        #expect(Monogram.initials(for: "google-drive") == "GD")
    }

    @Test func oklchConvertsKnownColours() {
        // --harness-1 clay oklch(0.56 0.11 45) ≈ #A95D3A in the design.
        let clay = HarnessPalette.color(slot: 0, dark: false)
        #expect(abs(clay.r * 255 - 0xA9) < 6)
        #expect(abs(clay.g * 255 - 0x5D) < 6)
        #expect(abs(clay.b * 255 - 0x3A) < 6)
        let spruce = HarnessPalette.color(slot: 1, dark: false)
        #expect(abs(spruce.r * 255 - 0x1B) < 8)
        #expect(abs(spruce.g * 255 - 0x88) < 6)
        #expect(HarnessPalette.color(slot: 7, dark: false) == HarnessPalette.color(slot: 1, dark: false))
    }

    @Test func harnessCodes() {
        #expect(Harness.code(for: "Claude Code") == "CC")
        #expect(Harness.code(for: "Codex") == "CX")
        #expect(Harness.code(for: "Gemini CLI") == "GM")
        #expect(Harness.code(for: "Acme Agent") == "AA")
    }
}

@Suite struct PlanSelectionLogic {
    private var plan: Plan {
        Plan(manifestPath: "~/.config/actl/manifest.toml", manifestExists: true, actions: [
            PlanAction(id: "a", harness: "claude", group: .instructions, kind: .ruleRescope, title: "a", tokensDelta: -17350, defaultSelected: true),
            PlanAction(id: "b", harness: "claude", group: .skills, kind: .skillsSync, title: "b", defaultSelected: true),
            PlanAction(id: "c", harness: "claude", group: .skills, kind: .skillsResolveConflict, title: "c",
                       requiresChoice: PlanChoice(options: [PlanChoiceOption(id: "keep", label: "Keep"), PlanChoiceOption(id: "take", label: "Take")]), defaultSelected: true),
            PlanAction(id: "d", harness: "codex", group: .services, kind: .mcpAdd, title: "d", tokensDelta: 0, defaultSelected: false),
        ], summary: PlanSummary(count: 4, tokensDelta: [:]))
    }

    @Test func defaultsSkipChoicesAndUnselected() {
        let s = PlanSelection(plan: plan)
        #expect(s.actionIds(in: plan) == ["a", "b"])
        #expect(s.count(in: plan) == 2)
    }

    @Test func choiceRequiredBeforeSelection() {
        var s = PlanSelection(plan: plan)
        let c = plan.actions[2]
        s.toggle(c)
        #expect(!s.isSelected(c))
        s.choose("keep", for: c)
        #expect(s.isSelected(c))
        #expect(s.choice(for: c) == "keep")
        s.toggle(c)
        #expect(!s.isSelected(c))
        s.choose("take", for: c)
        #expect(s.applyArgs(in: plan) == ["a", "b", "c=take"])
    }

    @Test func tokensDeltaSumsSelectedPerHarness() {
        var s = PlanSelection(plan: plan)
        #expect(s.tokensDelta(in: plan) == ["claude": -17350])
        s.toggle(plan.actions[0])
        #expect(s.tokensDelta(in: plan)["claude"] == nil)
        s.toggle(plan.actions[3])
        #expect(s.actionIds(in: plan) == ["b", "d"])
    }

    @Test func reconcileDropsVanishedActions() {
        var s = PlanSelection(plan: plan)
        s.choose("take", for: plan.actions[2])
        var smaller = plan
        smaller.actions.removeAll { $0.id == "c" || $0.id == "a" }
        s.reconcile(with: smaller)
        #expect(s.actionIds(in: smaller) == ["b"])
        #expect(s.choices.isEmpty)
    }

    @Test func groupedByHarnessPreservesOrder() {
        let g = plan.groupedByHarness()
        #expect(g.map(\.harness) == ["claude", "codex"])
        #expect(g[0].actions.count == 3)
    }
}

@Suite struct FormattingAndConfig {
    @Test func numbers() {
        #expect(Fmt.int(4039) == "4\u{2009}039")
        #expect(Fmt.int(-17350) == "\u{2212}17\u{2009}350")
        #expect(Fmt.compact(52145) == "52.1k")
        #expect(Fmt.compact(9727) == "9.7k")
        #expect(Fmt.compact(980) == "980")
        #expect(Fmt.compact(30000) == "30k")
    }

    @Test func scanConfigRoundTrip() {
        let original = """
        [scan]
        roots = ["~/Code"]
        # keep me
        maxDepth = 3

        [proxy]
        enabled = "auto"
        """
        let cfg = ConfigFile.readScan(from: original)
        #expect(cfg.roots == ["~/Code"])
        let out = ConfigFile.writeScan(ScanConfig(roots: ["~/Code", "~/Developer"], workspaces: ["~/Documents/Notes"]), into: original)
        #expect(out.contains("roots = [\"~/Code\", \"~/Developer\"]"))
        #expect(out.contains("workspaces = [\"~/Documents/Notes\"]"))
        #expect(out.contains("maxDepth = 3"))
        #expect(out.contains("[proxy]"))
        #expect(ConfigFile.readScan(from: out).workspaces == ["~/Documents/Notes"])
        let fresh = ConfigFile.writeScan(ScanConfig(roots: ["~/src"]), into: "")
        #expect(fresh == "[scan]\nroots = [\"~/src\"]\n")
    }
}

@Suite struct LargeEngineOutput {
    /// Regression: output larger than the 64 KB pipe buffer used to deadlock `run` (first run hung after adopt).
    @Test func runReturnsMegabyteOfStdoutAndStderr() async throws {
        let script = "head -c 1048576 /dev/zero | tr '\\\\0' 'a'; head -c 200000 /dev/zero | tr '\\\\0' 'e' >&2"
        let engine = ProcessEngine(location: EngineLocation(executable: URL(fileURLWithPath: "/bin/sh"), prefixArgs: ["-c", script]))
        let data = try await engine.run([])
        #expect(data.count == 1_048_576)
    }
}
