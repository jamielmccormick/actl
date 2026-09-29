// The observable app store: stale-while-revalidate cache over the engine, plus the
// in-flight apply run, the sign-in queue and the undo toast. Everything runs on the main actor;
// engine work is awaited, never blocking.

import Foundation
import Observation

public enum Loadable<T: Sendable>: Sendable {
    case idle
    case loading(previous: T?)
    case loaded(T, at: Date)
    case failed(String, previous: T?)

    public var value: T? {
        switch self {
        case .idle: return nil
        case .loading(let p), .failed(_, let p): return p
        case .loaded(let v, _): return v
        }
    }
    public var isLoading: Bool { if case .loading = self { return true }; return false }
    public var error: String? { if case .failed(let e, _) = self { return e }; return nil }
    public var loadedAt: Date? { if case .loaded(_, let at) = self { return at }; return nil }
    public var isIdle: Bool { if case .idle = self { return true }; return false }

    /// Age in seconds since the last successful load (nil if never loaded).
    public func age(now: Date = Date()) -> TimeInterval? { loadedAt.map { now.timeIntervalSince($0) } }
}

public struct ApplyRun: Sendable, Hashable {
    public var runId: String
    public var actionIds: [String]
    public var states: [String: StepState] = [:]
    public var messages: [String: String] = [:]
    public var backupDir: String?
    public var backupFiles: [String] = []
    public var startedAt: Date
    public var result: (ok: Int, failed: Int, tookMs: Int)?
    public var error: String?
    public var isUndo: Bool = false

    public init(runId: String, actionIds: [String], startedAt: Date = Date(), isUndo: Bool = false) {
        self.runId = runId; self.actionIds = actionIds; self.startedAt = startedAt; self.isUndo = isUndo
    }

    public static func == (a: ApplyRun, b: ApplyRun) -> Bool {
        a.runId == b.runId && a.states == b.states && a.messages == b.messages && a.error == b.error && a.result?.ok == b.result?.ok && a.result?.failed == b.result?.failed
    }
    public func hash(into h: inout Hasher) { h.combine(runId); h.combine(states) }

    public var isFinished: Bool { result != nil || error != nil }
    public var completed: Int { states.values.filter { $0 == .ok || $0 == .failed || $0 == .skipped }.count }
    public var currentActionId: String? { actionIds.first { states[$0] == .running } ?? actionIds.first { states[$0] == nil } }
}

public struct SignInItem: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable { case queued, opening, waiting, done, failed(String?), skipped }
    public var harness: HarnessId
    public var server: String
    public var serviceName: String
    public var serviceId: String?
    public var state: State = .queued
    public var id: String { "\(harness):\(server)" }
    public init(harness: HarnessId, server: String, serviceName: String, serviceId: String? = nil) {
        self.harness = harness; self.server = server; self.serviceName = serviceName; self.serviceId = serviceId
    }
}

public struct SignInQueue: Sendable, Hashable {
    public var items: [SignInItem]
    public var index: Int = 0
    public var autoContinue: Bool
    /// True when a sign-in finished and the queue is waiting for the user to press Continue.
    public var awaitingContinue: Bool = false
    public var stopped: Bool = false
    public var startedAt: Date

    public init(items: [SignInItem], autoContinue: Bool, startedAt: Date = Date()) {
        self.items = items; self.autoContinue = autoContinue; self.startedAt = startedAt
    }

    public var current: SignInItem? { index < items.count ? items[index] : nil }
    public var next: SignInItem? { index + 1 < items.count ? items[index + 1] : nil }
    public var isFinished: Bool { stopped || index >= items.count }
    public var doneCount: Int { items.filter { $0.state == .done }.count }
}

public struct Toast: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var title: String
    public var detail: String?
    public var undoRunId: String?
    public var isError: Bool = false
    public init(title: String, detail: String? = nil, undoRunId: String? = nil, isError: Bool = false) {
        self.title = title; self.detail = detail; self.undoRunId = undoRunId; self.isError = isError
    }
}

/// Persisted preferences (UserDefaults). Kept in the store so views observe changes.
public struct Preferences: Sendable, Hashable {
    public var autoContinueSignIn = true
    public var firstRunCompleted = false
    public var notificationsRequested = false
    public var harnessColorOverrides: [HarnessId: Int] = [:]
    public var showMenuBarCount = true
    public var proxyEnabled: Bool? = nil     // nil = auto
    public var argentEnabled = true

    public init() {}

    static let key = "dev.actl.preferences"

    public static func load(_ defaults: UserDefaults = .standard) -> Preferences {
        var p = Preferences()
        guard let d = defaults.dictionary(forKey: key) else { return p }
        p.autoContinueSignIn = d["autoContinueSignIn"] as? Bool ?? true
        p.firstRunCompleted = d["firstRunCompleted"] as? Bool ?? false
        p.notificationsRequested = d["notificationsRequested"] as? Bool ?? false
        p.harnessColorOverrides = d["harnessColorOverrides"] as? [String: Int] ?? [:]
        p.showMenuBarCount = d["showMenuBarCount"] as? Bool ?? true
        p.proxyEnabled = d["proxyEnabled"] as? Bool
        p.argentEnabled = d["argentEnabled"] as? Bool ?? true
        return p
    }

    public func save(_ defaults: UserDefaults = .standard) {
        var d: [String: Any] = [
            "autoContinueSignIn": autoContinueSignIn,
            "firstRunCompleted": firstRunCompleted,
            "notificationsRequested": notificationsRequested,
            "harnessColorOverrides": harnessColorOverrides,
            "showMenuBarCount": showMenuBarCount,
            "argentEnabled": argentEnabled,
        ]
        if let proxyEnabled { d["proxyEnabled"] = proxyEnabled }
        defaults.set(d, forKey: Preferences.key)
    }
}

@MainActor
@Observable
public final class AppStore {
    public let engine: Engine
    public let isFixtures: Bool

    public var status: Loadable<Status> = .idle
    public var inventory: Loadable<Inventory> = .idle
    public var services: Loadable<[Service]> = .idle
    public var budget: Loadable<Budget> = .idle
    public var plan: Loadable<Plan> = .idle
    public var proxy: Loadable<ProxySnapshot> = .idle
    public var activity: Loadable<[ActivityEntry]> = .idle
    public var manifest: ManifestInfo?

    public var selection = PlanSelection()
    public var applyRun: ApplyRun?
    public var signIn: SignInQueue?
    public var toast: Toast?
    public var preferences: Preferences {
        didSet { preferences.save() }
    }
    public var engineError: String?
    public var lastInventoryAt: Date?
    public var budgetRepo: String?

    /// Notifications the app should post; the app layer drains this.
    public var pendingNotifications: [(id: String, title: String, body: String)] = []
    private var notified: Set<String> = []

    private var refreshing: Set<String> = []
    private var loginTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    public init(engine: Engine, isFixtures: Bool = false, preferences: Preferences = Preferences.load()) {
        self.engine = engine
        self.isFixtures = isFixtures
        self.preferences = preferences
    }

    // MARK: Derived

    /// Harnesses come from the inventory; before it loads, status gives ids and names.
    public var harnesses: [Harness] {
        if let inv = inventory.value, !inv.harnesses.isEmpty {
            return inv.harnesses.enumerated().map { i, h in
                var h = h
                if h.colorSlot == 0 && i > 0 && inv.harnesses.filter({ $0.colorSlot == 0 }).count > 1 { h.colorSlot = i }
                return h
            }
        }
        if let s = status.value {
            return s.harnesses.enumerated().map { i, h in Harness(id: h.id, name: h.name, code: Harness.code(for: h.name), supported: true, installed: true, colorSlot: i) }
        }
        return [
            Harness(id: "claude", name: "Claude Code", code: "CC", supported: true, installed: false, colorSlot: 0),
            Harness(id: "codex", name: "Codex", code: "CX", supported: true, installed: false, colorSlot: 1),
        ]
    }

    public var managedHarnesses: [Harness] { harnesses.filter { $0.supported && $0.installed } }

    public func harness(_ id: HarnessId) -> Harness? { harnesses.first { $0.id == id } }

    /// Effective colour slot after the user's overrides from Settings.
    public func colorSlot(for id: HarnessId) -> Int {
        preferences.harnessColorOverrides[id] ?? harness(id)?.colorSlot ?? 0
    }

    public var proxyConfigured: Bool {
        if preferences.proxyEnabled == false { return false }
        if let p = proxy.value, p.isConfigured { return true }
        if let s = status.value, s.proxy != nil { return true }
        return false
    }

    public var isSyncing: Bool {
        inventory.isLoading || (applyRun != nil && !(applyRun?.isFinished ?? true))
    }

    public var level: StatusLevel {
        if engineError != nil && status.value == nil { return .error }
        if isSyncing { return .syncing }
        guard let s = status.value else { return .attention }
        return s.level == .syncing ? StatusLevel.derive(from: s) : s.level
    }

    public var attentionCount: Int { status.value?.attention.count ?? 0 }
    public var planCount: Int { plan.value?.actions.count ?? 0 }
    public var manifestPath: String { plan.value?.manifestPath ?? manifest?.path ?? "~/.config/actl/manifest.toml" }

    public var servicesNeedingAttention: Int { services.value?.filter(\.needsAttention).count ?? 0 }
    public var skillsPending: Int { skillsWithState.filter { $0.syncState == "pending" || $0.syncState == "conflict" }.count }

    /// Skills with a derived `syncState` when the engine did not report one: pending or conflict when the plan
    /// names the skill in a `skills.sync` / `skills.resolve-conflict` action, else in-sync (both harnesses)
    /// or only-here.
    public var skillsWithState: [Skill] {
        guard let skills = inventory.value?.skills else { return [] }
        let actions = plan.value?.actions ?? []
        let syncText = actions.filter { $0.kind == .skillsSync }.map { ($0.title + " " + ($0.detail ?? "")).lowercased() }.joined(separator: " ")
        let conflictText = actions.filter { $0.kind == .skillsResolveConflict }.map { ($0.id + " " + $0.title + " " + ($0.detail ?? "")).lowercased() }.joined(separator: " ")
        // A ~/.claude/skills entry with the same name as a canonical skill is its synced copy: fold it into
        // the canonical row instead of listing it twice.
        let canonicalNames = Set(skills.filter { $0.source == "agents-user" }.map { $0.name.lowercased() })
        let copies = Set(skills.filter { $0.source == "claude-user" && canonicalNames.contains($0.name.lowercased()) }.map { $0.name.lowercased() })
        return skills.compactMap { s in
            let key = s.name.lowercased()
            if s.source == "claude-user", copies.contains(key), s.syncState == nil { return nil }
            guard s.syncState == nil else { return s }
            var out = s
            if conflictText.contains(key) { out.syncState = "conflict" }
            else if syncText.contains(key) { out.syncState = "pending" }
            else if s.source == "agents-user", copies.contains(key) { out.syncState = "in-sync"; out.visibleIn.claude = true }
            else if s.visibleIn.claude && s.visibleIn.codex { out.syncState = "in-sync" }
            else { out.syncState = "only-here" }
            return out
        }
    }

    // MARK: Refresh

    /// On launch: status first (fast), then the heavier commands.
    public func bootstrap() async {
        seedInventoryFromCache()
        await refreshStatus()
        // Cached first so every screen fills within a second, then a fresh inventory (5–15 s) and a re-read.
        async let b: () = refreshServices()
        async let c: () = refreshBudget()
        async let d: () = refreshPlan()
        async let e: () = refreshActivity()
        async let f: () = refreshProxy()
        async let g: () = refreshManifest()
        _ = await (b, c, d, e, f, g)
        await refreshInventory(force: true)
    }

    /// The cheap set, run after FSEvents fire.
    public func refreshCheap() async {
        async let a: () = refreshStatus()
        async let b: () = refreshServices()
        async let c: () = refreshPlan()
        async let d: () = refreshActivity()
        async let e: () = refreshBudget()
        _ = await (a, b, c, d, e)
    }

    public func refreshAll() async {
        async let a: () = refreshInventory(force: true)
        async let b: () = refreshCheap()
        async let c: () = refreshProxy()
        _ = await (a, b, c)
    }

    /// Runs `inventory` if the data is older than `maxAge` seconds (or never loaded).
    public func refreshInventoryIfStale(maxAge: TimeInterval) async {
        if let at = lastInventoryAt, Date().timeIntervalSince(at) < maxAge { return }
        await refreshInventory(force: true)
    }

    public func refreshStatus() async {
        await load(\.status, key: "status", args: ["status"], as: Status.self) { [weak self] s in
            self?.detectNotifications(s)
        }
    }

    /// Optimistic read: the engine's last inventory (`~/.cache/actl/inventory.json`) paints Skills and
    /// Instructions instantly; the fresh inventory replaces it seconds later.
    public func seedInventoryFromCache() {
        guard !isFixtures, inventory.value == nil else { return }
        let cache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        let url = cache.appendingPathComponent("actl/inventory.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        let inv = (try? decoder.decode(Envelope<Inventory>.self, from: data).data) ?? (try? decoder.decode(Inventory.self, from: data))
        guard let inv else { return }
        let at = inv.generatedAt.flatMap(ISO8601.parse) ?? Date.distantPast
        inventory = .loading(previous: inv)
        if lastInventoryAt == nil { lastInventoryAt = at }
    }

    /// A fresh inventory (runs `claude mcp list`, 5–15 s). Afterwards the cached commands are re-read so
    /// services, budget and plan reflect it without a second health check.
    public func refreshInventory(force: Bool = false) async {
        if !force, let at = lastInventoryAt, Date().timeIntervalSince(at) < 300 { return }
        var args = ["inventory"]
        if let r = budgetRepo { args.append("--repo=\(r)") }
        await load(\.inventory, key: "inventory", args: args, as: Inventory.self) { [weak self] inv in
            self?.lastInventoryAt = Date()
            if let s = inv.services { self?.services = .loaded(s, at: Date()) }
            if let b = inv.budget { self?.budget = .loaded(b, at: Date()) }
        }
        // status and the cached commands read the inventory cache, so re-read them after a full inventory.
        await refreshStatus()
        async let a: () = refreshServices()
        async let b: () = refreshBudget()
        async let c: () = refreshPlan()
        _ = await (a, b, c)
    }

    /// The engine's `--cached` flag: reuse the last inventory instead of health-checking every server.
    private var cachedFlag: [String] { isFixtures ? [] : ["--cached"] }

    public func refreshServices() async {
        await load(\.services, key: "services", args: ["services"] + cachedFlag, as: [Service].self)
    }

    public func refreshBudget(repo: String? = nil) async {
        let r = repo ?? budgetRepo
        var args = ["budget"]
        if let r { args.append("--repo=\(r)") }
        await load(\.budget, key: "budget", args: args + cachedFlag, as: Budget.self)
    }

    public func refreshPlan() async {
        await load(\.plan, key: "plan", args: ["plan"] + cachedFlag, as: Plan.self) { [weak self] p in
            guard let self else { return }
            if self.selection.selected.isEmpty && self.selection.choices.isEmpty {
                self.selection = PlanSelection(plan: p)
            } else {
                self.selection.reconcile(with: p)
            }
        }
    }

    public func refreshProxy() async {
        if preferences.proxyEnabled == false { return }
        await load(\.proxy, key: "proxy", args: ["proxy"], as: ProxySnapshot.self) { [weak self] p in
            self?.detectProxyNotifications(p)
        }
    }

    public func refreshActivity() async {
        await load(\.activity, key: "activity", args: ["activity", "--limit=50"], as: [ActivityEntry].self)
    }

    public func refreshManifest() async {
        if let env = try? await engine.envelope(ManifestInfo.self, ["manifest", "show"]) {
            manifest = env.data
        }
    }

    private func load<T: Decodable & Sendable>(_ keyPath: ReferenceWritableKeyPath<AppStore, Loadable<T>>, key: String, args: [String], as: T.Type, then: ((T) -> Void)? = nil) async {
        guard !refreshing.contains(key) else { return }
        refreshing.insert(key)
        defer { refreshing.remove(key) }
        let previous = self[keyPath: keyPath].value
        self[keyPath: keyPath] = .loading(previous: previous)
        do {
            let env = try await engine.envelope(T.self, args)
            self[keyPath: keyPath] = .loaded(env.data, at: Date())
            engineError = nil
            then?(env.data)
        } catch is CancellationError {
            self[keyPath: keyPath] = previous.map { .loaded($0, at: Date()) } ?? .idle
        } catch {
            let message = (error as? EngineError)?.errorDescription ?? error.localizedDescription
            self[keyPath: keyPath] = .failed(message, previous: previous)
            if case .notFound = error as? EngineError { engineError = message }
            else if previous == nil && key == "status" { engineError = message }
        }
    }

    // MARK: Apply / undo

    public func apply(actionIds: [String]) {
        guard !actionIds.isEmpty, applyRun == nil || applyRun!.isFinished else { return }
        runStream(args: ["apply"] + actionIds, actionIds: actionIds, isUndo: false)
    }

    public func applySelected() {
        guard let p = plan.value else { return }
        apply(actionIds: selection.applyArgs(in: p))
    }

    public func undo(runId: String) {
        let ids = activity.value?.first { $0.runId == runId }?.actions.map(\.id) ?? []
        runStream(args: ["undo", runId], actionIds: ids, isUndo: true)
    }

    private func runStream(args: [String], actionIds: [String], isUndo: Bool) {
        applyTask?.cancel()
        var run = ApplyRun(runId: "", actionIds: actionIds, isUndo: isUndo)
        for id in actionIds { run.states[id] = nil }
        applyRun = run
        applyTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.engine.events(ApplyEvent.self, args) {
                    self.handle(event)
                }
                if var r = self.applyRun, !r.isFinished {
                    r.error = "The engine stopped before reporting a result."
                    self.applyRun = r
                }
            } catch {
                if var r = self.applyRun {
                    r.error = (error as? EngineError)?.errorDescription ?? error.localizedDescription
                    self.applyRun = r
                }
            }
            await self.refreshCheap()
        }
    }

    private func handle(_ event: ApplyEvent) {
        guard var run = applyRun else { return }
        switch event {
        case .start(let runId, let actions):
            run.runId = runId
            if run.actionIds.isEmpty { run.actionIds = actions }
        case .backup(_, let files, let dir):
            run.backupDir = dir
            run.backupFiles = files
        case .step(_, let actionId, let state, let message):
            run.states[actionId] = state
            if let message { run.messages[actionId] = message }
            if !run.actionIds.contains(actionId) { run.actionIds.append(actionId) }
        case .done(let runId, let ok, let failed, let tookMs):
            if !runId.isEmpty { run.runId = runId }
            run.result = (ok, failed, tookMs)
            if !run.isUndo, ok > 0 {
                showToast(Toast(title: "Applied \(ok) change\(ok == 1 ? "" : "s")", detail: failed > 0 ? "\(failed) failed" : nil, undoRunId: run.runId))
            }
        case .error(_, let message):
            run.error = message
        case .unknown:
            break
        }
        applyRun = run
    }

    public func dismissApplyRun() { applyRun = nil }

    /// One-click "Make lazy": runs the service's plan action directly and offers Undo.
    public func makeLazy(service: Service) {
        guard let action = plan.value?.actions.first(where: { $0.kind == .serviceMakeLazy && $0.title.localizedCaseInsensitiveContains(service.name) }) ?? plan.value?.actions.first(where: { $0.kind == .serviceMakeLazy && $0.id.contains(service.id) }) else {
            showToast(Toast(title: "No lazy alternative is planned for \(service.name) yet", detail: "Run Review to re-plan.", isError: true))
            return
        }
        apply(actionIds: [action.id])
    }

    /// Bulk "Make lazy (N)" from Services/Context: selects the corresponding plan actions for Review.
    public func planMakeLazy(serviceIds: [String]) -> Int {
        guard let p = plan.value else { return 0 }
        var n = 0
        for a in p.actions where a.kind == .serviceMakeLazy {
            if serviceIds.contains(where: { a.id.contains($0) || a.title.localizedCaseInsensitiveContains($0) }) {
                selection.set(a, selected: true); n += 1
            }
        }
        return n
    }

    public func showToast(_ t: Toast) {
        toast = t
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled, self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    // MARK: Sign-in queue

    public func startSignIn(_ requests: [SignInItem]) {
        guard !requests.isEmpty else { return }
        signIn = SignInQueue(items: requests, autoContinue: preferences.autoContinueSignIn)
        runCurrentSignIn()
    }

    public func startSignIn(harness: HarnessId, servers: [String]) {
        let items = servers.map { server in
            let svc = services.value?.first { s in s.providers[harness]?.serverName == server || s.providers[harness]?.ref == server || s.id == server }
            return SignInItem(harness: harness, server: server, serviceName: svc?.name ?? server, serviceId: svc?.id)
        }
        startSignIn(items)
    }

    /// Every provider that can sign in, across services, for one harness (or all).
    public func signInCandidates(harness: HarnessId? = nil) -> [SignInItem] {
        guard let list = services.value else { return [] }
        var out: [SignInItem] = []
        for s in list.sorted(by: { $0.name < $1.name }) {
            for (h, p) in s.providers where p.canSignIn && p.health == .needsAuth {
                if let harness, harness != h { continue }
                out.append(SignInItem(harness: h, server: p.serverName ?? p.ref, serviceName: s.name, serviceId: s.id))
            }
        }
        return out
    }

    private func runCurrentSignIn() {
        guard var q = signIn, let item = q.current, !q.stopped else { return }
        q.items[q.index].state = .opening
        q.awaitingContinue = false
        signIn = q
        loginTask?.cancel()
        loginTask = Task { [weak self] in
            guard let self else { return }
            var finished = false
            do {
                for try await event in self.engine.events(LoginEvent.self, ["login", item.harness, item.server, "--json"]) {
                    guard var q = self.signIn else { return }
                    switch event {
                    case .opening: q.items[q.index].state = .opening
                    case .waiting: q.items[q.index].state = .waiting
                    case .done(_, _, let ok, let message):
                        q.items[q.index].state = ok ? .done : .failed(message)
                        finished = true
                    case .unknown: break
                    }
                    self.signIn = q
                }
            } catch {
                if var q = self.signIn {
                    q.items[q.index].state = .failed((error as? EngineError)?.errorDescription ?? error.localizedDescription)
                    self.signIn = q
                    finished = true
                }
            }
            if !finished, var q = self.signIn, q.items[q.index].state != .done {
                q.items[q.index].state = .failed("The sign-in ended without a result.")
                self.signIn = q
            }
            self.afterSignInStep()
        }
    }

    private func afterSignInStep() {
        guard var q = signIn else { return }
        let ok = q.current?.state == .done
        if q.autoContinue && ok {
            q.index += 1
            signIn = q
            if q.isFinished { finishSignIn() } else { runCurrentSignIn() }
        } else {
            q.awaitingContinue = true
            signIn = q
            if q.index + 1 >= q.items.count && ok { /* leave the last card up for Continue → close */ }
        }
    }

    public func continueSignIn() {
        guard var q = signIn else { return }
        q.index += 1
        signIn = q
        if q.isFinished { finishSignIn() } else { runCurrentSignIn() }
    }

    public func skipSignIn() {
        guard var q = signIn else { return }
        loginTask?.cancel()
        if q.index < q.items.count { q.items[q.index].state = .skipped }
        q.index += 1
        signIn = q
        if q.isFinished { finishSignIn() } else { runCurrentSignIn() }
    }

    public func retrySignIn() { runCurrentSignIn() }

    public func stopSignIn() {
        loginTask?.cancel()
        signIn?.stopped = true
        finishSignIn()
    }

    public func setSignInAutoContinue(_ on: Bool) {
        preferences.autoContinueSignIn = on
        signIn?.autoContinue = on
    }

    private func finishSignIn() {
        let done = signIn?.doneCount ?? 0
        Task { [weak self] in
            await self?.refreshCheap()
            await self?.refreshInventory(force: true)
        }
        if done > 0 { showToast(Toast(title: "Signed in to \(done) service\(done == 1 ? "" : "s")")) }
        signIn = nil
    }

    // MARK: Manifest

    public func adoptManifest() async -> ManifestInfo? {
        do {
            let env = try await engine.envelope(ManifestInfo.self, ["manifest", "adopt"] + cachedFlag)
            manifest = env.data
            // Don't make first run wait on the plan; it can take seconds and the window closes next.
            Task { await refreshPlan() }
            return env.data
        } catch {
            showToast(Toast(title: "Could not adopt the manifest", detail: (error as? EngineError)?.errorDescription ?? error.localizedDescription, isError: true))
            return nil
        }
    }

    // MARK: Notifications (deduplicated by id)

    private func detectNotifications(_ s: Status) {
        for item in s.attention where item.severity != .info {
            let id = "attention:\(item.id)"
            guard !notified.contains(id) else { continue }
            notified.insert(id)
            // Only once the first status has been seen: launch state is not "new".
            if notifiedSeededOnce { pendingNotifications.append((id, item.title, item.detail ?? "")) }
        }
        notifiedSeededOnce = true
    }

    private var notifiedSeededOnce = false
    private var proxySeeded = false

    private func detectProxyNotifications(_ p: ProxySnapshot) {
        for a in p.accounts where a.state == .cooldown {
            let id = "proxy-cooldown:\(a.id):\(a.nextRetryAfter ?? "")"
            guard !notified.contains(id) else { continue }
            notified.insert(id)
            if proxySeeded { pendingNotifications.append((id, "\(a.displayLabel) is in cooldown", a.statusMessage ?? "The proxy stopped routing to this account.")) }
        }
        if p.updateAvailable, let l = p.latestVersion {
            let id = "proxy-update:\(l)"
            if !notified.contains(id) {
                notified.insert(id)
                if proxySeeded { pendingNotifications.append((id, "CLIProxyAPI \(l) available", "Installed \(p.installedVersion ?? "?") · updating restarts the proxy for about 3 s")) }
            }
        }
        proxySeeded = true
    }
}
