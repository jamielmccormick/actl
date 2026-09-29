// Models for the actl engine contract (docs/engine-contract.md, schema 2).
// Decoding is tolerant: unknown fields are ignored, unknown enum strings fall back to a
// documented `unknown`/`other` case, and optional fields stay optional.

import Foundation

public struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    public let schema: Int
    public let command: String
    public let generatedAt: Date?
    public let data: T

    public init(schema: Int, command: String, generatedAt: Date?, data: T) {
        self.schema = schema
        self.command = command
        self.generatedAt = generatedAt
        self.data = data
    }

    enum CodingKeys: String, CodingKey { case schema, command, generatedAt, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 0
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .generatedAt) {
            generatedAt = ISO8601.parse(raw)
        } else {
            generatedAt = nil
        }
        data = try c.decode(T.self, forKey: .data)
    }
}

/// A string enum that never fails to decode: unknown values map to `Self.fallback`.
public protocol TolerantEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    static var fallback: Self { get }
}

public extension TolerantEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }
}

public enum ISO8601 {
    nonisolated(unsafe) private static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        withFractions.date(from: s) ?? plain.date(from: s)
    }

    public static func string(_ d: Date) -> String { plain.string(from: d) }
}

// MARK: - Harnesses

public typealias HarnessId = String

public struct Harness: Codable, Sendable, Hashable, Identifiable {
    public var id: HarnessId
    public var name: String
    public var code: String
    public var supported: Bool
    public var installed: Bool
    public var version: String?
    public var home: String?
    public var colorSlot: Int

    public init(id: HarnessId, name: String, code: String, supported: Bool, installed: Bool, version: String? = nil, home: String? = nil, colorSlot: Int) {
        self.id = id; self.name = name; self.code = code; self.supported = supported
        self.installed = installed; self.version = version; self.home = home; self.colorSlot = colorSlot
    }

    enum CodingKeys: String, CodingKey { case id, name, code, supported, installed, version, home, colorSlot }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id.capitalized
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? Harness.code(for: name)
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? false
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version)
        home = try c.decodeIfPresent(String.self, forKey: .home)
        colorSlot = try c.decodeIfPresent(Int.self, forKey: .colorSlot) ?? 0
    }

    /// Two-letter code: first letter of each word, or the first two letters of a one-word name.
    public static func code(for name: String) -> String {
        let known = ["claude code": "CC", "codex": "CX", "cursor": "CU", "gemini cli": "GM", "opencode": "OC", "github copilot cli": "CP", "copilot cli": "CP"]
        if let k = known[name.lowercased()] { return k }
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 {
            return String(words.prefix(2).compactMap { $0.first }).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

// MARK: - Services

public enum Health: String, TolerantEnum {
    case connected, needsAuth = "needs-auth", failed, blocked, pending, unknown, absent
    public static let fallback = Health.unknown
}

public enum ProviderKind: String, TolerantEnum {
    case plugin, mcp, connector, claudeAI = "claude.ai", unknown
    public static let fallback = ProviderKind.unknown
}

public enum AuthKind: String, TolerantEnum {
    case oauth, token, none, chatgpt, unknown
    public static let fallback = AuthKind.unknown
}

public enum Parity: String, TolerantEnum {
    case both, onlyClaude = "only-claude", onlyCodex = "only-codex", gap, partial, unknown
    public static let fallback = Parity.unknown
}

public struct LazyAlternative: Codable, Sendable, Hashable {
    public var transport: String
    public var url: String
    public var serverName: String?
    public init(transport: String, url: String, serverName: String? = nil) { self.transport = transport; self.url = url; self.serverName = serverName }
    enum CodingKeys: String, CodingKey { case transport, url, serverName }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? "http"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        serverName = try c.decodeIfPresent(String.self, forKey: .serverName)
    }
}

public struct Provider: Codable, Sendable, Hashable {
    public var kind: ProviderKind
    public var ref: String
    public var serverName: String?
    public var health: Health
    public var detail: String?
    public var auth: AuthKind
    public var canSignIn: Bool
    public var contextTokens: Int?
    public var contextEstimated: Bool
    public var skills: [String]
    public var lazyAlternative: LazyAlternative?

    public init(kind: ProviderKind, ref: String, serverName: String? = nil, health: Health, detail: String? = nil, auth: AuthKind, canSignIn: Bool, contextTokens: Int? = nil, contextEstimated: Bool = false, skills: [String] = [], lazyAlternative: LazyAlternative? = nil) {
        self.kind = kind; self.ref = ref; self.serverName = serverName; self.health = health; self.detail = detail
        self.auth = auth; self.canSignIn = canSignIn; self.contextTokens = contextTokens; self.contextEstimated = contextEstimated; self.skills = skills; self.lazyAlternative = lazyAlternative
    }

    enum CodingKeys: String, CodingKey { case kind, ref, serverName, health, detail, auth, canSignIn, contextTokens, contextEstimated, skills, lazyAlternative }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(ProviderKind.self, forKey: .kind) ?? .unknown
        ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? ""
        serverName = try c.decodeIfPresent(String.self, forKey: .serverName)
        health = try c.decodeIfPresent(Health.self, forKey: .health) ?? .unknown
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        auth = try c.decodeIfPresent(AuthKind.self, forKey: .auth) ?? .unknown
        canSignIn = try c.decodeIfPresent(Bool.self, forKey: .canSignIn) ?? false
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextEstimated = try c.decodeIfPresent(Bool.self, forKey: .contextEstimated) ?? false
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        lazyAlternative = try c.decodeIfPresent(LazyAlternative.self, forKey: .lazyAlternative)
    }
}

public struct Service: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var brandColor: String?
    public var logo: String?
    public var homepage: String?
    public var providers: [HarnessId: Provider]
    public var parity: Parity
    public var gapReason: String?

    public init(id: String, name: String, brandColor: String? = nil, logo: String? = nil, homepage: String? = nil, providers: [HarnessId: Provider], parity: Parity, gapReason: String? = nil) {
        self.id = id; self.name = name; self.brandColor = brandColor; self.logo = logo; self.homepage = homepage
        self.providers = providers; self.parity = parity; self.gapReason = gapReason
    }

    enum CodingKeys: String, CodingKey { case id, name, brandColor, logo, homepage, providers, parity, gapReason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        brandColor = try c.decodeIfPresent(String.self, forKey: .brandColor)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        providers = try c.decodeIfPresent([HarnessId: Provider].self, forKey: .providers) ?? [:]
        parity = try c.decodeIfPresent(Parity.self, forKey: .parity) ?? .unknown
        gapReason = try c.decodeIfPresent(String.self, forKey: .gapReason)
    }

    /// Always-on tokens across all providers (plugins pay up front, MCP is 0).
    public var contextTokens: Int { providers.values.reduce(0) { $0 + ($1.contextTokens ?? 0) } }

    public var needsAttention: Bool {
        providers.values.contains { $0.health == .needsAuth || $0.health == .failed || $0.health == .blocked }
    }

    public var isGap: Bool { parity == .gap || parity == .onlyClaude || parity == .onlyCodex || parity == .partial }
}

// MARK: - Budget

public enum BudgetCategory: String, TolerantEnum {
    case plugins, skillsListing = "skills-listing", instructions, rules, drift, other
    public static let fallback = BudgetCategory.other
}

public enum LeverKind: String, TolerantEnum {
    case plugin, rule, instructions, skills, other
    public static let fallback = LeverKind.other
}

public enum LeverAction: String, TolerantEnum {
    case makeLazy = "make-lazy", rescope, disable, unknown
    public static let fallback = LeverAction.unknown
}

public struct BudgetCategoryTokens: Codable, Sendable, Hashable, Identifiable {
    public var id: BudgetCategory
    public var tokens: Int
    public init(id: BudgetCategory, tokens: Int) { self.id = id; self.tokens = tokens }
}

public struct BudgetLever: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var tokens: Int
    public var kind: LeverKind
    public var action: LeverAction?
    public var serviceId: String?
    public var estimated: Bool

    public init(id: String, label: String, tokens: Int, kind: LeverKind, action: LeverAction? = nil, serviceId: String? = nil, estimated: Bool = false) {
        self.id = id; self.label = label; self.tokens = tokens; self.kind = kind; self.action = action; self.serviceId = serviceId; self.estimated = estimated
    }

    enum CodingKeys: String, CodingKey { case id, label, tokens, kind, action, serviceId, estimated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        kind = try c.decodeIfPresent(LeverKind.self, forKey: .kind) ?? .other
        action = try c.decodeIfPresent(LeverAction.self, forKey: .action)
        serviceId = try c.decodeIfPresent(String.self, forKey: .serviceId)
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
    }
}

public struct HarnessBudget: Codable, Sendable, Hashable {
    public var total: Int
    public var categories: [BudgetCategoryTokens]
    public var levers: [BudgetLever]
    public init(total: Int, categories: [BudgetCategoryTokens], levers: [BudgetLever]) {
        self.total = total; self.categories = categories; self.levers = levers
    }

    enum CodingKeys: String, CodingKey { case total, categories, levers }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        categories = try c.decodeIfPresent([BudgetCategoryTokens].self, forKey: .categories) ?? []
        levers = try c.decodeIfPresent([BudgetLever].self, forKey: .levers) ?? []
    }
}

public struct LoadPreviewFile: Codable, Sendable, Hashable {
    public var path: String
    public var reason: String
    public var tokens: Int
    public init(path: String, reason: String, tokens: Int) { self.path = path; self.reason = reason; self.tokens = tokens }
}

public struct LoadPreviewHarness: Codable, Sendable, Hashable {
    public var files: [LoadPreviewFile]
    public var total: Int
    public init(files: [LoadPreviewFile], total: Int) { self.files = files; self.total = total }
}

public struct LoadPreview: Codable, Sendable, Hashable {
    public var repo: String
    public var harnesses: [HarnessId: LoadPreviewHarness]
    public init(repo: String, harnesses: [HarnessId: LoadPreviewHarness]) { self.repo = repo; self.harnesses = harnesses }
}

public struct Budget: Codable, Sendable, Hashable {
    public var harnesses: [HarnessId: HarnessBudget]
    public var loadPreview: LoadPreview?
    public init(harnesses: [HarnessId: HarnessBudget], loadPreview: LoadPreview? = nil) { self.harnesses = harnesses; self.loadPreview = loadPreview }
}

// MARK: - Status

public enum StatusLevel: String, TolerantEnum {
    case healthy, attention, error, syncing
    public static let fallback = StatusLevel.attention
}

public enum Severity: String, TolerantEnum {
    case error, warn, info
    public static let fallback = Severity.info
}

public enum AttentionKind: String, TolerantEnum {
    case signIn = "sign-in", failed, drift, sync, update, gap, quota, other
    public static let fallback = AttentionKind.other
}

public struct SignInRequest: Codable, Sendable, Hashable {
    public var harness: HarnessId
    public var servers: [String]
    public init(harness: HarnessId, servers: [String]) { self.harness = harness; self.servers = servers }
}

public struct AttentionFix: Codable, Sendable, Hashable {
    public var label: String
    public var actionIds: [String]?
    public var signIn: SignInRequest?
    public init(label: String, actionIds: [String]? = nil, signIn: SignInRequest? = nil) { self.label = label; self.actionIds = actionIds; self.signIn = signIn }
}

public struct AttentionItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var severity: Severity
    public var kind: AttentionKind
    public var title: String
    public var detail: String?
    public var harness: HarnessId?
    public var fix: AttentionFix?

    public init(id: String, severity: Severity, kind: AttentionKind, title: String, detail: String? = nil, harness: HarnessId? = nil, fix: AttentionFix? = nil) {
        self.id = id; self.severity = severity; self.kind = kind; self.title = title; self.detail = detail; self.harness = harness; self.fix = fix
    }

    enum CodingKeys: String, CodingKey { case id, severity, kind, title, detail, harness, fix }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        severity = try c.decodeIfPresent(Severity.self, forKey: .severity) ?? .info
        kind = try c.decodeIfPresent(AttentionKind.self, forKey: .kind) ?? .other
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        harness = try c.decodeIfPresent(String.self, forKey: .harness)
        fix = try c.decodeIfPresent(AttentionFix.self, forKey: .fix)
    }
}

public struct StatusHarness: Codable, Sendable, Hashable, Identifiable {
    public var id: HarnessId
    public var name: String
    public var connected: Int
    public var total: Int
    public var needsSignIn: Int
    public var failed: Int
    public init(id: HarnessId, name: String, connected: Int, total: Int, needsSignIn: Int, failed: Int) {
        self.id = id; self.name = name; self.connected = connected; self.total = total; self.needsSignIn = needsSignIn; self.failed = failed
    }
    enum CodingKeys: String, CodingKey { case id, name, connected, total, needsSignIn, failed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        connected = try c.decodeIfPresent(Int.self, forKey: .connected) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        needsSignIn = try c.decodeIfPresent(Int.self, forKey: .needsSignIn) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    }
}

public enum ProxyAccountState: String, TolerantEnum {
    case active, cooldown, disabled, error
    public static let fallback = ProxyAccountState.error
}

public struct StatusProxyAccount: Codable, Sendable, Hashable {
    public var label: String
    public var state: ProxyAccountState
    public var retryAt: String?
    public init(label: String, state: ProxyAccountState, retryAt: String? = nil) { self.label = label; self.state = state; self.retryAt = retryAt }
}

public struct StatusProxy: Codable, Sendable, Hashable {
    public var accounts: [StatusProxyAccount]
    public init(accounts: [StatusProxyAccount]) { self.accounts = accounts }
}

public struct Status: Codable, Sendable, Hashable {
    public var level: StatusLevel
    public var harnesses: [StatusHarness]
    public var attention: [AttentionItem]
    public var proxy: StatusProxy?
    public var checkedAt: String
    public var stale: Bool

    public init(level: StatusLevel, harnesses: [StatusHarness], attention: [AttentionItem], proxy: StatusProxy? = nil, checkedAt: String, stale: Bool) {
        self.level = level; self.harnesses = harnesses; self.attention = attention; self.proxy = proxy; self.checkedAt = checkedAt; self.stale = stale
    }

    enum CodingKeys: String, CodingKey { case level, harnesses, attention, proxy, checkedAt, stale }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decodeIfPresent(StatusLevel.self, forKey: .level) ?? .attention
        harnesses = try c.decodeIfPresent([StatusHarness].self, forKey: .harnesses) ?? []
        attention = try c.decodeIfPresent([AttentionItem].self, forKey: .attention) ?? []
        proxy = try c.decodeIfPresent(StatusProxy.self, forKey: .proxy)
        checkedAt = try c.decodeIfPresent(String.self, forKey: .checkedAt) ?? ""
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }

    public var checkedDate: Date? { ISO8601.parse(checkedAt) }
}

// MARK: - Plan

public enum PlanGroup: String, TolerantEnum {
    case instructions, skills, services, plugins, proxy, other
    public static let fallback = PlanGroup.other
}

public enum PlanKind: String, TolerantEnum {
    case skillsSync = "skills.sync", skillsResolveConflict = "skills.resolve-conflict"
    case mcpAdd = "mcp.add", mcpRemove = "mcp.remove"
    case pluginInstall = "plugin.install", pluginUninstall = "plugin.uninstall", pluginEnable = "plugin.enable", pluginDisable = "plugin.disable"
    case serviceMakeLazy = "service.make-lazy", ruleRescope = "rule.rescope", instructionsMode = "instructions.mode", proxyUpdate = "proxy.update"
    case other
    public static let fallback = PlanKind.other
}

public struct PlanDiff: Codable, Sendable, Hashable {
    public var path: String
    public var before: String
    public var after: String
    public init(path: String, before: String, after: String) { self.path = path; self.before = before; self.after = after }
}

public struct PlanChoiceOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct PlanChoice: Codable, Sendable, Hashable {
    public var options: [PlanChoiceOption]
    public init(options: [PlanChoiceOption]) { self.options = options }
}

public struct PlanAction: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var harness: String?
    public var group: PlanGroup
    public var kind: PlanKind
    public var title: String
    public var detail: String?
    public var consequence: String?
    public var tokensDelta: Int?
    public var diff: PlanDiff?
    public var requiresChoice: PlanChoice?
    public var reversible: Bool
    public var defaultSelected: Bool

    public init(id: String, harness: String? = nil, group: PlanGroup, kind: PlanKind, title: String, detail: String? = nil, consequence: String? = nil, tokensDelta: Int? = nil, diff: PlanDiff? = nil, requiresChoice: PlanChoice? = nil, reversible: Bool = true, defaultSelected: Bool = true) {
        self.id = id; self.harness = harness; self.group = group; self.kind = kind; self.title = title; self.detail = detail
        self.consequence = consequence; self.tokensDelta = tokensDelta; self.diff = diff; self.requiresChoice = requiresChoice
        self.reversible = reversible; self.defaultSelected = defaultSelected
    }

    enum CodingKeys: String, CodingKey { case id, harness, group, kind, title, detail, consequence, tokensDelta, diff, requiresChoice, reversible, defaultSelected }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        harness = try c.decodeIfPresent(String.self, forKey: .harness)
        group = try c.decodeIfPresent(PlanGroup.self, forKey: .group) ?? .other
        kind = try c.decodeIfPresent(PlanKind.self, forKey: .kind) ?? .other
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        consequence = try c.decodeIfPresent(String.self, forKey: .consequence)
        tokensDelta = try c.decodeIfPresent(Int.self, forKey: .tokensDelta)
        diff = try c.decodeIfPresent(PlanDiff.self, forKey: .diff)
        requiresChoice = try c.decodeIfPresent(PlanChoice.self, forKey: .requiresChoice)
        reversible = try c.decodeIfPresent(Bool.self, forKey: .reversible) ?? false
        defaultSelected = try c.decodeIfPresent(Bool.self, forKey: .defaultSelected) ?? true
    }
}

public struct PlanSummary: Codable, Sendable, Hashable {
    public var count: Int
    public var tokensDelta: [HarnessId: Int]
    public init(count: Int, tokensDelta: [HarnessId: Int]) { self.count = count; self.tokensDelta = tokensDelta }
    enum CodingKeys: String, CodingKey { case count, tokensDelta }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        tokensDelta = try c.decodeIfPresent([HarnessId: Int].self, forKey: .tokensDelta) ?? [:]
    }
}

public struct Plan: Codable, Sendable, Hashable {
    public var manifestPath: String
    public var manifestExists: Bool
    public var manifestErrors: [String]
    public var actions: [PlanAction]
    public var summary: PlanSummary

    public init(manifestPath: String, manifestExists: Bool, manifestErrors: [String] = [], actions: [PlanAction], summary: PlanSummary) {
        self.manifestPath = manifestPath; self.manifestExists = manifestExists; self.manifestErrors = manifestErrors; self.actions = actions; self.summary = summary
    }
    enum CodingKeys: String, CodingKey { case manifestPath, manifestExists, manifestErrors, actions, summary }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifestPath = try c.decodeIfPresent(String.self, forKey: .manifestPath) ?? "~/.config/actl/manifest.toml"
        manifestExists = try c.decodeIfPresent(Bool.self, forKey: .manifestExists) ?? false
        manifestErrors = try c.decodeIfPresent([String].self, forKey: .manifestErrors) ?? []
        actions = try c.decodeIfPresent([PlanAction].self, forKey: .actions) ?? []
        summary = try c.decodeIfPresent(PlanSummary.self, forKey: .summary) ?? PlanSummary(count: actions.count, tokensDelta: [:])
    }
}

// MARK: - Apply / undo / login events (JSONL)

public enum StepState: String, TolerantEnum {
    case running, ok, failed, skipped
    public static let fallback = StepState.running
}

public enum ApplyEvent: Sendable, Hashable {
    case start(runId: String, actions: [String])
    case backup(runId: String, files: [String], dir: String)
    case step(runId: String, actionId: String, state: StepState, message: String?)
    case done(runId: String, ok: Int, failed: Int, tookMs: Int)
    case error(runId: String?, message: String)
    case unknown(type: String)

    public var runId: String? {
        switch self {
        case .start(let r, _), .backup(let r, _, _), .step(let r, _, _, _), .done(let r, _, _, _): return r
        case .error(let r, _): return r
        case .unknown: return nil
        }
    }

    public var isTerminal: Bool {
        if case .done = self { return true }
        if case .error = self { return true }
        return false
    }
}

extension ApplyEvent: Decodable {
    enum CodingKeys: String, CodingKey { case type, runId, actions, files, dir, actionId, state, message, ok, failed, tookMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        let runId = try c.decodeIfPresent(String.self, forKey: .runId)
        switch type {
        case "start":
            self = .start(runId: runId ?? "", actions: try c.decodeIfPresent([String].self, forKey: .actions) ?? [])
        case "backup":
            self = .backup(runId: runId ?? "", files: try c.decodeIfPresent([String].self, forKey: .files) ?? [], dir: try c.decodeIfPresent(String.self, forKey: .dir) ?? "")
        case "step":
            self = .step(runId: runId ?? "", actionId: try c.decodeIfPresent(String.self, forKey: .actionId) ?? "", state: try c.decodeIfPresent(StepState.self, forKey: .state) ?? .running, message: try c.decodeIfPresent(String.self, forKey: .message))
        case "done":
            self = .done(runId: runId ?? "", ok: try c.decodeIfPresent(Int.self, forKey: .ok) ?? 0, failed: try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0, tookMs: try c.decodeIfPresent(Int.self, forKey: .tookMs) ?? 0)
        case "error":
            self = .error(runId: runId, message: try c.decodeIfPresent(String.self, forKey: .message) ?? "Unknown engine error")
        default:
            self = .unknown(type: type)
        }
    }
}

public enum LoginEvent: Sendable, Hashable {
    case opening(harness: HarnessId, server: String)
    case waiting(harness: HarnessId, server: String)
    case done(harness: HarnessId, server: String, ok: Bool, message: String?)
    case unknown(type: String)
}

extension LoginEvent: Decodable {
    enum CodingKeys: String, CodingKey { case type, harness, server, ok, message }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        let harness = try c.decodeIfPresent(String.self, forKey: .harness) ?? ""
        let server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        switch type {
        case "opening": self = .opening(harness: harness, server: server)
        case "waiting": self = .waiting(harness: harness, server: server)
        case "done": self = .done(harness: harness, server: server, ok: try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false, message: try c.decodeIfPresent(String.self, forKey: .message))
        default: self = .unknown(type: type)
        }
    }
}

// MARK: - Activity

public enum ActivitySource: String, TolerantEnum {
    case user, watch, auto
    public static let fallback = ActivitySource.auto
}

public struct ActivityAction: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var state: StepState
    public init(id: String, title: String, state: StepState) { self.id = id; self.title = title; self.state = state }
    enum CodingKeys: String, CodingKey { case id, title, state }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        state = try c.decodeIfPresent(StepState.self, forKey: .state) ?? .ok
    }
}

public struct ActivityEntry: Codable, Sendable, Hashable, Identifiable {
    public var runId: String
    public var at: String
    public var source: ActivitySource
    public var actions: [ActivityAction]
    public var undoable: Bool
    public var undoneAt: String?
    public var undoOf: String?
    public var id: String { runId }

    public init(runId: String, at: String, source: ActivitySource, actions: [ActivityAction], undoable: Bool, undoneAt: String? = nil, undoOf: String? = nil) {
        self.runId = runId; self.at = at; self.source = source; self.actions = actions; self.undoable = undoable; self.undoneAt = undoneAt; self.undoOf = undoOf
    }
    enum CodingKeys: String, CodingKey { case runId, at, source, actions, undoable, undoneAt, undoOf }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(String.self, forKey: .runId)
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        source = try c.decodeIfPresent(ActivitySource.self, forKey: .source) ?? .auto
        actions = try c.decodeIfPresent([ActivityAction].self, forKey: .actions) ?? []
        undoable = try c.decodeIfPresent(Bool.self, forKey: .undoable) ?? false
        undoneAt = try c.decodeIfPresent(String.self, forKey: .undoneAt)
        undoOf = try c.decodeIfPresent(String.self, forKey: .undoOf)
    }
    public var date: Date? { ISO8601.parse(at) }
}

// MARK: - Manifest

public struct ManifestInfo: Codable, Sendable, Hashable {
    public var path: String
    public var exists: Bool
    public var created: Bool?
    public var errors: [String]
    public init(path: String, exists: Bool, created: Bool? = nil, errors: [String] = []) { self.path = path; self.exists = exists; self.created = created; self.errors = errors }
    enum CodingKeys: String, CodingKey { case path, exists, created, errors }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "~/.config/actl/manifest.toml"
        created = try c.decodeIfPresent(Bool.self, forKey: .created)
        exists = try c.decodeIfPresent(Bool.self, forKey: .exists) ?? (created != nil)
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
    }
}

// MARK: - Inventory (the collect.ts shape, decoded loosely)

public struct Repo: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var kind: String
    public var branch: String?
    public var remote: String?
    public var id: String { path }
    public init(name: String, path: String, kind: String, branch: String? = nil, remote: String? = nil) { self.name = name; self.path = path; self.kind = kind; self.branch = branch; self.remote = remote }
    enum CodingKeys: String, CodingKey { case name, path, kind, branch, remote }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "repo"
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        remote = try c.decodeIfPresent(String.self, forKey: .remote)
    }
}

public struct InstructionFile: Codable, Sendable, Hashable, Identifiable {
    public var scope: String
    public var owner: String
    public var path: String
    public var rel: String
    public var name: String
    public var bytes: Int
    public var lines: Int
    public var tracked: Bool
    public var pathScoped: Bool
    public var imports: [String]
    public var loadedBy: [HarnessId]
    public var preview: String
    public var id: String { path }

    public init(scope: String, owner: String, path: String, rel: String, name: String, bytes: Int, lines: Int, tracked: Bool, pathScoped: Bool = false, imports: [String] = [], loadedBy: [HarnessId], preview: String = "") {
        self.scope = scope; self.owner = owner; self.path = path; self.rel = rel; self.name = name; self.bytes = bytes; self.lines = lines
        self.tracked = tracked; self.pathScoped = pathScoped; self.imports = imports; self.loadedBy = loadedBy; self.preview = preview
    }
    enum CodingKeys: String, CodingKey { case scope, owner, path, rel, name, bytes, lines, tracked, pathScoped, imports, loadedBy, preview }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "global"
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        rel = try c.decodeIfPresent(String.self, forKey: .rel) ?? name
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? 0
        tracked = try c.decodeIfPresent(Bool.self, forKey: .tracked) ?? false
        pathScoped = try c.decodeIfPresent(Bool.self, forKey: .pathScoped) ?? false
        imports = try c.decodeIfPresent([String].self, forKey: .imports) ?? []
        loadedBy = try c.decodeIfPresent([String].self, forKey: .loadedBy) ?? []
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
    }
    /// ~4 chars per token.
    public var estimatedTokens: Int { max(0, bytes / 4) }
}

public struct SkillVisibility: Codable, Sendable, Hashable {
    public var claude: Bool
    public var codex: Bool
    public init(claude: Bool, codex: Bool) { self.claude = claude; self.codex = codex }
    enum CodingKeys: String, CodingKey { case claude, codex }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = try c.decodeIfPresent(Bool.self, forKey: .claude) ?? false
        codex = try c.decodeIfPresent(Bool.self, forKey: .codex) ?? false
    }
}

public struct Skill: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var dirName: String
    public var description: String
    public var source: String
    public var owner: String
    public var path: String
    public var broken: Bool
    public var codexDisabled: Bool
    public var visibleIn: SkillVisibility
    /// Sync state from the hash manifest when the engine reports it (`in-sync`, `pending`, `conflict`, `only-here`).
    public var syncState: String?
    public var id: String { path }

    public init(name: String, dirName: String? = nil, description: String = "", source: String, owner: String = "", path: String, broken: Bool = false, codexDisabled: Bool = false, visibleIn: SkillVisibility, syncState: String? = nil) {
        self.name = name; self.dirName = dirName ?? name; self.description = description; self.source = source; self.owner = owner; self.path = path
        self.broken = broken; self.codexDisabled = codexDisabled; self.visibleIn = visibleIn; self.syncState = syncState
    }
    enum CodingKeys: String, CodingKey { case name, dirName, description, source, owner, path, broken, codexDisabled, visibleIn, syncState }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        dirName = try c.decodeIfPresent(String.self, forKey: .dirName) ?? name
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "agents-user"
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        broken = try c.decodeIfPresent(Bool.self, forKey: .broken) ?? false
        codexDisabled = try c.decodeIfPresent(Bool.self, forKey: .codexDisabled) ?? false
        visibleIn = try c.decodeIfPresent(SkillVisibility.self, forKey: .visibleIn) ?? SkillVisibility(claude: false, codex: false)
        syncState = try c.decodeIfPresent(String.self, forKey: .syncState)
    }
}

public struct ClaudePlugin: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var version: String?
    public var hasMcp: Bool
    public var hasSkills: Bool
    public init(id: String, enabled: Bool, version: String? = nil, hasMcp: Bool, hasSkills: Bool) { self.id = id; self.enabled = enabled; self.version = version; self.hasMcp = hasMcp; self.hasSkills = hasSkills }
    enum CodingKeys: String, CodingKey { case id, enabled, version, hasMcp, hasSkills }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        version = try c.decodeIfPresent(String.self, forKey: .version)
        hasMcp = try c.decodeIfPresent(Bool.self, forKey: .hasMcp) ?? false
        hasSkills = try c.decodeIfPresent(Bool.self, forKey: .hasSkills) ?? false
    }
}

public struct CodexPlugin: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var version: String?
    public var connector: Bool
    public init(id: String, enabled: Bool, version: String? = nil, connector: Bool) { self.id = id; self.enabled = enabled; self.version = version; self.connector = connector }
    enum CodingKeys: String, CodingKey { case id, enabled, version, connector }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        version = try c.decodeIfPresent(String.self, forKey: .version)
        connector = try c.decodeIfPresent(Bool.self, forKey: .connector) ?? false
    }
}

public struct Plugins: Codable, Sendable, Hashable {
    public var claude: [ClaudePlugin]
    public var codex: [CodexPlugin]
    public init(claude: [ClaudePlugin], codex: [CodexPlugin]) { self.claude = claude; self.codex = codex }
    enum CodingKeys: String, CodingKey { case claude, codex }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claude = try c.decodeIfPresent([ClaudePlugin].self, forKey: .claude) ?? []
        codex = try c.decodeIfPresent([CodexPlugin].self, forKey: .codex) ?? []
    }
}

public struct Finding: Codable, Sendable, Hashable {
    public var severity: Severity
    public var area: String
    public var title: String
    public var detail: String
    public var fix: String?
    public var items: [String]?
    public init(severity: Severity, area: String, title: String, detail: String, fix: String? = nil, items: [String]? = nil) { self.severity = severity; self.area = area; self.title = title; self.detail = detail; self.fix = fix; self.items = items }
    enum CodingKeys: String, CodingKey { case severity, area, title, detail, fix, items }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        severity = try c.decodeIfPresent(Severity.self, forKey: .severity) ?? .info
        area = try c.decodeIfPresent(String.self, forKey: .area) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        fix = try c.decodeIfPresent(String.self, forKey: .fix)
        items = try c.decodeIfPresent([String].self, forKey: .items)
    }
}

public struct InventoryConfig: Codable, Sendable, Hashable {
    public var path: String
    public var exists: Bool
    public var scanRoots: [String]
    public var workspaces: [String]
    public init(path: String, exists: Bool, scanRoots: [String], workspaces: [String]) { self.path = path; self.exists = exists; self.scanRoots = scanRoots; self.workspaces = workspaces }
    enum CodingKeys: String, CodingKey { case path, exists, scanRoots, workspaces }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "~/.config/actl/config.toml"
        exists = try c.decodeIfPresent(Bool.self, forKey: .exists) ?? false
        scanRoots = try c.decodeIfPresent([String].self, forKey: .scanRoots) ?? []
        workspaces = try c.decodeIfPresent([String].self, forKey: .workspaces) ?? []
    }
}

public struct Inventory: Codable, Sendable, Hashable {
    public var generatedAt: String?
    public var harnesses: [Harness]
    public var config: InventoryConfig?
    public var repos: [Repo]
    public var instructions: [InstructionFile]
    public var skills: [Skill]
    public var plugins: Plugins
    public var findings: [Finding]
    public var services: [Service]?
    public var budget: Budget?

    public init(generatedAt: String? = nil, harnesses: [Harness], config: InventoryConfig? = nil, repos: [Repo], instructions: [InstructionFile], skills: [Skill], plugins: Plugins, findings: [Finding], services: [Service]? = nil, budget: Budget? = nil) {
        self.generatedAt = generatedAt; self.harnesses = harnesses; self.config = config; self.repos = repos; self.instructions = instructions
        self.skills = skills; self.plugins = plugins; self.findings = findings; self.services = services; self.budget = budget
    }
    enum CodingKeys: String, CodingKey { case generatedAt, harnesses, config, repos, instructions, skills, plugins, findings, services, budget }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt)
        harnesses = try c.decodeIfPresent([Harness].self, forKey: .harnesses) ?? []
        config = try c.decodeIfPresent(InventoryConfig.self, forKey: .config)
        repos = try c.decodeIfPresent([Repo].self, forKey: .repos) ?? []
        instructions = try c.decodeIfPresent([InstructionFile].self, forKey: .instructions) ?? []
        skills = try c.decodeIfPresent([Skill].self, forKey: .skills) ?? []
        plugins = try c.decodeIfPresent(Plugins.self, forKey: .plugins) ?? Plugins(claude: [], codex: [])
        findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        services = try c.decodeIfPresent([Service].self, forKey: .services)
        budget = try c.decodeIfPresent(Budget.self, forKey: .budget)
    }
}

// MARK: - Proxy (CliproxySnapshot)

public struct ProxyBucket: Codable, Sendable, Hashable {
    public var time: String?
    public var success: Int
    public var failed: Int
    public init(time: String? = nil, success: Int, failed: Int) { self.time = time; self.success = success; self.failed = failed }
    enum CodingKeys: String, CodingKey { case time, success, failed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        success = try c.decodeIfPresent(Int.self, forKey: .success) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    }
}

public struct ProxyAccount: Codable, Sendable, Hashable, Identifiable {
    public var ref: String?
    public var provider: String?
    public var email: String?
    public var label: String?
    public var accountType: String?
    public var status: String?
    public var statusMessage: String?
    public var disabled: Bool
    public var unavailable: Bool
    public var lastRefresh: String?
    public var nextRetryAfter: String?
    public var success: Int
    public var failed: Int
    public var recent: [ProxyBucket]
    public var id: String { ref ?? "\(provider ?? "")|\(email ?? label ?? "")" }

    public init(ref: String? = nil, provider: String? = nil, email: String? = nil, label: String? = nil, accountType: String? = nil, status: String? = nil, statusMessage: String? = nil, disabled: Bool = false, unavailable: Bool = false, lastRefresh: String? = nil, nextRetryAfter: String? = nil, success: Int = 0, failed: Int = 0, recent: [ProxyBucket] = []) {
        self.ref = ref; self.provider = provider; self.email = email; self.label = label; self.accountType = accountType; self.status = status; self.statusMessage = statusMessage
        self.disabled = disabled; self.unavailable = unavailable; self.lastRefresh = lastRefresh; self.nextRetryAfter = nextRetryAfter; self.success = success; self.failed = failed; self.recent = recent
    }
    enum CodingKeys: String, CodingKey { case ref, provider, email, label, accountType, status, statusMessage, disabled, unavailable, lastRefresh, nextRetryAfter, success, failed, recent }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        accountType = try c.decodeIfPresent(String.self, forKey: .accountType)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        unavailable = try c.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        lastRefresh = try c.decodeIfPresent(String.self, forKey: .lastRefresh)
        nextRetryAfter = try c.decodeIfPresent(String.self, forKey: .nextRetryAfter)
        success = try c.decodeIfPresent(Int.self, forKey: .success) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        recent = try c.decodeIfPresent([ProxyBucket].self, forKey: .recent) ?? []
    }

    public var displayLabel: String { email ?? label ?? ref ?? "account" }

    public var state: ProxyAccountState {
        if disabled { return .disabled }
        if unavailable || nextRetryAfter != nil { return .cooldown }
        if let status, status.lowercased().contains("error") { return .error }
        return .active
    }
}

public struct ProxyErrorLog: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var size: Int
    public var modified: String?
    public var id: String { name }
    public init(name: String, size: Int, modified: String? = nil) { self.name = name; self.size = size; self.modified = modified }
    enum CodingKeys: String, CodingKey { case name, size, modified }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        modified = try c.decodeIfPresent(String.self, forKey: .modified)
    }
}

/// The proxy's config is CLIProxyAPI's own (pickConfig in cliproxy.ts): keys vary by version, so every
/// field is read leniently and scalars of any JSON type are accepted.
public struct ProxyConfig: Codable, Sendable, Hashable {
    public var strategy: String?
    /// "24h" when affinity is on with a TTL, "on"/"off" otherwise.
    public var sessionAffinity: String?
    public var retry: Int?
    public init(strategy: String? = nil, sessionAffinity: String? = nil, retry: Int? = nil) { self.strategy = strategy; self.sessionAffinity = sessionAffinity; self.retry = retry }
    enum CodingKeys: String, CodingKey { case strategy, routingStrategy, sessionAffinity, sessionAffinityTtl, retry, requestRetry }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strategy = LenientScalar.string(c, .routingStrategy) ?? LenientScalar.string(c, .strategy)
        let affinity = LenientScalar.string(c, .sessionAffinity)
        let ttl = LenientScalar.string(c, .sessionAffinityTtl)
        if affinity == "false" { sessionAffinity = "off" } else if let ttl { sessionAffinity = ttl } else if affinity == "true" { sessionAffinity = "on" } else { sessionAffinity = affinity }
        retry = LenientScalar.int(c, .requestRetry) ?? LenientScalar.int(c, .retry)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(strategy, forKey: .strategy)
        try c.encodeIfPresent(sessionAffinity, forKey: .sessionAffinity)
        try c.encodeIfPresent(retry, forKey: .retry)
    }
}

/// Reads a JSON scalar of any type as a string or int.
enum LenientScalar {
    static func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b ? "true" : "false" }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }
    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s) }
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b ? 1 : 0 }
        return nil
    }
}

public struct ProxySnapshot: Codable, Sendable, Hashable {
    public var endpoint: String
    public var listening: Bool
    public var keyConfigured: Bool
    public var installedVersion: String?
    public var latestVersion: String?
    public var config: ProxyConfig?
    public var accounts: [ProxyAccount]
    public var errorLogs: [ProxyErrorLog]
    public var errors: [String: String]

    public init(endpoint: String, listening: Bool, keyConfigured: Bool, installedVersion: String? = nil, latestVersion: String? = nil, config: ProxyConfig? = nil, accounts: [ProxyAccount] = [], errorLogs: [ProxyErrorLog] = [], errors: [String: String] = [:]) {
        self.endpoint = endpoint; self.listening = listening; self.keyConfigured = keyConfigured; self.installedVersion = installedVersion; self.latestVersion = latestVersion
        self.config = config; self.accounts = accounts; self.errorLogs = errorLogs; self.errors = errors
    }
    enum CodingKeys: String, CodingKey { case endpoint, listening, keyConfigured, installedVersion, latestVersion, config, accounts, errorLogs, errors }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? "127.0.0.1:8317"
        listening = try c.decodeIfPresent(Bool.self, forKey: .listening) ?? false
        keyConfigured = try c.decodeIfPresent(Bool.self, forKey: .keyConfigured) ?? false
        installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion)
        latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        config = try c.decodeIfPresent(ProxyConfig.self, forKey: .config)
        accounts = try c.decodeIfPresent([ProxyAccount].self, forKey: .accounts) ?? []
        errorLogs = try c.decodeIfPresent([ProxyErrorLog].self, forKey: .errorLogs) ?? []
        errors = try c.decodeIfPresent([String: String].self, forKey: .errors) ?? [:]
    }

    /// The proxy is "configured" when it is running, or installed with a key, or has any accounts.
    public var isConfigured: Bool { listening || keyConfigured || !accounts.isEmpty }
    public var updateAvailable: Bool {
        guard let i = installedVersion, let l = latestVersion else { return false }
        return i != l
    }
}
