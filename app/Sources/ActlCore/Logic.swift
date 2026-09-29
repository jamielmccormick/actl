// Small, pure logic that the UI and tests share: status level mapping, plan selection, formatting.

import Foundation

// MARK: - Status level

public extension StatusLevel {
    /// Derives a level from a status payload when the engine's level is missing or when the app is syncing.
    static func derive(from status: Status, syncing: Bool = false) -> StatusLevel {
        if syncing { return .syncing }
        if status.attention.contains(where: { $0.severity == .error }) { return .error }
        if status.harnesses.contains(where: { $0.failed > 0 }) { return .error }
        if !status.attention.isEmpty || status.harnesses.contains(where: { $0.needsSignIn > 0 }) { return .attention }
        return .healthy
    }

    /// Ordering used to pick the worst of several sources.
    var rank: Int {
        switch self {
        case .healthy: return 0
        case .syncing: return 1
        case .attention: return 2
        case .error: return 3
        }
    }

    public var word: String {
        switch self {
        case .healthy: return "Healthy"
        case .attention: return "Needs attention"
        case .error: return "Error"
        case .syncing: return "Checking…"
        }
    }
}

public extension Health {
    var word: String {
        switch self {
        case .connected: return "Connected"
        case .needsAuth: return "Needs sign-in"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .pending: return "Pending"
        case .unknown: return "Unknown"
        case .absent: return "Not available"
        }
    }
    /// Short form used in dense lists ("Sign in" instead of "Needs sign-in").
    var shortWord: String {
        self == .needsAuth ? "Sign in" : word
    }
}

/// The attention queue is ordered by what blocks work first: failures, then sign-ins, then drift, quota, sync, updates, gaps.
public extension AttentionKind {
    var blockingRank: Int {
        switch self {
        case .failed: return 0
        case .signIn: return 1
        case .drift: return 2
        case .quota: return 3
        case .sync: return 4
        case .update: return 5
        case .gap: return 6
        case .other: return 7
        }
    }
    var word: String {
        switch self {
        case .failed: return "Failed"
        case .signIn: return "Sign-in"
        case .drift: return "Drift"
        case .quota: return "Quota"
        case .sync: return "Sync"
        case .update: return "Update"
        case .gap: return "Gap"
        case .other: return "Note"
        }
    }
}

public extension Array where Element == AttentionItem {
    func orderedByBlocking() -> [AttentionItem] {
        enumerated().sorted { a, b in
            let ra = (a.element.severity.rank, a.element.kind.blockingRank, a.offset)
            let rb = (b.element.severity.rank, b.element.kind.blockingRank, b.offset)
            return ra < rb
        }.map(\.element)
    }
}

public extension Severity {
    var rank: Int { self == .error ? 0 : (self == .warn ? 1 : 2) }
}

// MARK: - Plan selection

/// Which plan actions are selected, and which option was picked for actions that require a choice.
/// An action that requires a choice cannot be selected until a choice exists.
public struct PlanSelection: Sendable, Hashable {
    public private(set) var selected: Set<String>
    public private(set) var choices: [String: String]

    public init(plan: Plan) {
        selected = Set(plan.actions.filter { $0.defaultSelected && $0.requiresChoice == nil }.map(\.id))
        choices = [:]
    }

    public init(selected: Set<String> = [], choices: [String: String] = [:]) {
        self.selected = selected
        self.choices = choices
    }

    public func isSelected(_ action: PlanAction) -> Bool { selected.contains(action.id) }

    public func canSelect(_ action: PlanAction) -> Bool {
        action.requiresChoice == nil || choices[action.id] != nil
    }

    public mutating func toggle(_ action: PlanAction) {
        if selected.contains(action.id) {
            selected.remove(action.id)
        } else if canSelect(action) {
            selected.insert(action.id)
        }
    }

    public mutating func set(_ action: PlanAction, selected on: Bool) {
        if on, canSelect(action) { selected.insert(action.id) } else if !on { selected.remove(action.id) }
    }

    /// Choosing an option also selects the action.
    public mutating func choose(_ optionId: String, for action: PlanAction) {
        choices[action.id] = optionId
        selected.insert(action.id)
    }

    public func choice(for action: PlanAction) -> String? { choices[action.id] }

    /// Actions to send to `actl apply`, in plan order.
    public func actionIds(in plan: Plan) -> [String] {
        plan.actions.filter { selected.contains($0.id) }.map(\.id)
    }

    public func count(in plan: Plan) -> Int { actionIds(in: plan).count }

    /// Arguments for `actl apply`: `<id>` or `<id>=<optionId>` for actions that required a choice.
    public func applyArgs(in plan: Plan) -> [String] {
        plan.actions.filter { selected.contains($0.id) }.map { a in
            if let c = choices[a.id] { return "\(a.id)=\(c)" }
            return a.id
        }
    }

    /// Token delta per harness for the selected actions (negative = saves tokens).
    public func tokensDelta(in plan: Plan) -> [HarnessId: Int] {
        var out: [HarnessId: Int] = [:]
        for a in plan.actions where selected.contains(a.id) {
            guard let d = a.tokensDelta, let h = a.harness else { continue }
            out[h, default: 0] += d
        }
        return out
    }

    /// Drop selections for actions that no longer exist after a re-plan; keep the rest.
    public mutating func reconcile(with plan: Plan) {
        let ids = Set(plan.actions.map(\.id))
        selected = selected.intersection(ids)
        choices = choices.filter { ids.contains($0.key) }
        // Newly appearing default-selected actions join the selection.
        for a in plan.actions where a.defaultSelected && a.requiresChoice == nil && !choices.keys.contains(a.id) {
            selected.insert(a.id)
        }
    }
}

public extension Plan {
    /// Actions grouped by harness (claude, codex, proxy, …) then by group, preserving first-seen order.
    func groupedByHarness() -> [(harness: String, actions: [PlanAction])] {
        var order: [String] = []
        var map: [String: [PlanAction]] = [:]
        for a in actions {
            let key = a.harness ?? "other"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(a)
        }
        return order.map { ($0, map[$0]!) }
    }
}

// MARK: - Formatting

public enum Fmt {
    /// Thin-space thousands: 4039 → "4 039". Negative uses a true minus sign.
    public static func int(_ n: Int) -> String {
        let s = String(abs(n))
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append("\u{2009}") }
            out.append(ch)
        }
        return (n < 0 ? "\u{2212}" : "") + String(out.reversed())
    }

    /// Compact: 52145 → "52.1k", 980 → "980", 1_200_000 → "1.2M".
    public static func compact(_ n: Int) -> String {
        let sign = n < 0 ? "\u{2212}" : ""
        let a = abs(n)
        if a >= 1_000_000 { return sign + trim(Double(a) / 1_000_000) + "M" }
        if a >= 1_000 { return sign + trim(Double(a) / 1_000) + "k" }
        return sign + String(a)
    }

    private static func trim(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    /// Signed token delta: −17350 → "−17 350 tokens/session".
    public static func tokensDelta(_ n: Int) -> String {
        (n > 0 ? "+" : "") + int(n) + " tokens/session"
    }

    public static func percent(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.0f%%", Double(part) / Double(total) * 100)
    }

    /// "2 min ago", "just now", "3 h ago", "yesterday".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 45 { return "just now" }
        if s < 90 { return "1 min ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 7200 { return "1 h ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        if s < 172_800 { return "yesterday" }
        return "\(s / 86400) d ago"
    }

    nonisolated(unsafe) private static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    nonisolated(unsafe) private static let dayHM: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
    }()
    nonisolated(unsafe) private static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f
    }()
    nonisolated(unsafe) private static let longDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"; return f
    }()

    public static func time(_ d: Date) -> String { hm.string(from: d) }
    /// "21:40" today, "Sun 23:04" this week, "Oct 3, 09:00" otherwise.
    public static func timeOrDay(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return hm.string(from: d) }
        if abs(now.timeIntervalSince(d)) < 6 * 86400 { return dayHM.string(from: d) }
        return monthDay.string(from: d)
    }
    public static func longDate(_ d: Date) -> String { longDay.string(from: d) }
    public static func monthDayTime(_ d: Date) -> String { monthDay.string(from: d) }

    /// Middle-truncates a path: "~/.claude/plugins/…/.mcp.json".
    public static func middleTruncate(_ s: String, max: Int) -> String {
        guard s.count > max, max > 5 else { return s }
        let head = (max - 1) / 2, tail = max - 1 - head
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }
}
