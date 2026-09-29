// Proxy accounts: the account table, traffic bars, version, and the error log.
// Writes (pause, re-auth, retry, update) are designed but deferred: shown disabled with "coming soon".

import ActlCore
import SwiftUI

struct ProxyScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(Navigation.self) private var nav
    @State private var now = Date()

    private var proxy: ProxySnapshot? { store.proxy.value }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Proxy accounts", count: nil, subtitle: subtitle) {
                if let p = proxy, p.updateAvailable {
                    HStack(spacing: 6) {
                        Icon(.update, size: 12, color: Palette.warn)
                        Text("\(p.installedVersion ?? "?") installed · \(p.latestVersion ?? "?") available").font(Type.sm(.medium)).foregroundStyle(Palette.warn)
                    }
                    .padding(.horizontal, 10).frame(height: 28).background(Palette.warnSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button("Update proxy") { nav.go(.review) }.buttonStyle(.borderedProminent)
                        .help(store.plan.value?.actions.contains { $0.kind == .proxyUpdate } == true ? "Planned in Review" : "Proxy writes are coming soon")
                        .disabled(!(store.plan.value?.actions.contains { $0.kind == .proxyUpdate } ?? false))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let p = proxy {
                        if !p.listening { notRunning(p) }
                        table(p)
                        errorLog(p)
                        gatedWrites
                    } else if let e = store.proxy.error {
                        InlineError(message: e, retry: { Task { await store.refreshProxy() } })
                    } else {
                        VStack(spacing: 12) { ForEach(0..<4, id: \.self) { _ in HStack { SkeletonLine(width: 160); SkeletonLine(width: 60); Spacer(); SkeletonLine(width: 180, height: 40); SkeletonLine(width: 70) }.frame(height: 72) } }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var subtitle: String? {
        guard let p = proxy else { return store.proxy.isLoading ? "connecting…" : nil }
        var parts = ["CLIProxyAPI on \(p.endpoint)", p.listening ? "listening" : "not running"]
        if let c = p.config {
            if let s = c.strategy { parts.append(s) }
            if let a = c.sessionAffinity { parts.append("session affinity \(a)") }
            if let r = c.retry { parts.append("retry \(r)") }
        }
        return parts.joined(separator: " · ")
    }

    private func notRunning(_ p: ProxySnapshot) -> some View {
        NoteWell(icon: .blocked, tint: Palette.fgSecondary, text: "CLIProxyAPI is not listening on \(p.endpoint). Accounts and traffic show the last known state" + (p.keyConfigured ? "." : "; no management key was found at ~/.cli-proxy-api/management-key."))
    }

    private func table(_ p: ProxySnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SectionLabel(text: "Account").frame(width: 210, alignment: .leading)
                SectionLabel(text: "Status").frame(width: 100, alignment: .leading)
                SectionLabel(text: "Requests · last 3 h").frame(maxWidth: .infinity, alignment: .leading)
                SectionLabel(text: "Lifetime").frame(width: 100, alignment: .trailing)
                SectionLabel(text: "Refreshed").frame(width: 100, alignment: .trailing)
                Color.clear.frame(width: 140, height: 1)
            }
            .frame(height: 32)
            Hairline()
            if p.accounts.isEmpty {
                Text("No accounts in the pool yet.").font(Type.sm()).foregroundStyle(Palette.fgTertiary).frame(height: 48)
                Hairline()
            }
            ForEach(p.accounts) { a in
                accountRow(a)
                Hairline()
            }
        }
    }

    private func accountRow(_ a: ProxyAccount) -> some View {
        let slot = store.colorSlot(for: a.provider ?? "")
        let color = Palette.harness(slot)
        let cooldown = a.state == .cooldown
        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                HarnessDot(slot: slot).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.displayLabel).font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                    Text([store.harness(a.provider ?? "")?.name ?? a.provider?.capitalized, "OAuth", a.accountType].compactMap { $0 }.joined(separator: " · ") + (a.statusMessage.map { cooldown ? "" : " · \($0)" } ?? "")).font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(1)
                }
            }
            .frame(width: 210, alignment: .leading)
            stateLabel(a).frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if cooldown {
                    Text("Usage limit reached · retrying \(a.nextRetryAfter.flatMap(ISO8601.parse).map(Fmt.monthDayTime) ?? "later")").font(Type.sm(.medium)).foregroundStyle(Palette.fg).lineLimit(1)
                    cooldownBar(a)
                    if let m = a.statusMessage { Text(m).font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                } else {
                    TrafficBars(buckets: a.recent, color: color).frame(height: 48)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Fmt.int(a.success)) ok").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                let rate = a.success + a.failed > 0 ? Double(a.failed) / Double(a.success + a.failed) * 100 : 0
                Text("\(a.failed) failed · \(String(format: "%.1f", rate))%").font(Type.xs()).foregroundStyle(rate > 1 ? Palette.warn : Palette.fgTertiary)
            }
            .frame(width: 100, alignment: .trailing)
            Text(a.lastRefresh.flatMap(ISO8601.parse).map { refreshedWord($0) } ?? "—").font(Type.sm()).foregroundStyle(Palette.fgSecondary).frame(width: 100, alignment: .trailing)
            HStack(spacing: 6) {
                Button(cooldown ? "Retry now" : (a.disabled ? "Resume" : "Pause")) {}.controlSize(.small).disabled(true).help("Coming soon: gated writes ship after v1")
                Button("Re-auth") {}.controlSize(.small).disabled(true).help("Coming soon: gated writes ship after v1")
            }
            .frame(width: 140, alignment: .trailing)
        }
        .frame(minHeight: 84)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(a.displayLabel), \(stateWord(a.state)), \(a.success) ok, \(a.failed) failed")
    }

    private func cooldownBar(_ a: ProxyAccount) -> some View {
        let retry = a.nextRetryAfter.flatMap(ISO8601.parse)
        let total: TimeInterval = 5 * 86400
        let remaining = retry.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        let frac = 1 - min(1, remaining / total)
        return HStack(spacing: 8) {
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 2).fill(Palette.bgSunken)
                    .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Palette.warn).frame(width: max(4, g.size.width * frac)) }
            }
            .frame(width: 180, height: 6)
            if remaining > 0 {
                let d = Int(remaining) / 86400, h = (Int(remaining) % 86400) / 3600, m = (Int(remaining) % 3600) / 60
                Text("\(d) d \(h) h \(String(format: "%02d", m)) m left").font(Type.xs()).foregroundStyle(Palette.fgTertiary).lineLimit(1).fixedSize()
            }
        }
    }

    private func refreshedWord(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "\(Fmt.time(d)) today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday \(Fmt.time(d))" }
        return Fmt.monthDayTime(d)
    }

    private func stateLabel(_ a: ProxyAccount) -> some View {
        StatusLabel(icon: a.state == .active ? .connected : (a.state == .cooldown ? .quota : (a.state == .disabled ? .blocked : .failed)), word: stateWord(a.state), color: stateColor(a.state))
    }
    private func stateWord(_ s: ProxyAccountState) -> String { switch s { case .active: "Active"; case .cooldown: "Cooldown"; case .disabled: "Paused"; case .error: "Error" } }
    private func stateColor(_ s: ProxyAccountState) -> Color { switch s { case .active: Palette.ok; case .cooldown: Palette.warn; case .disabled: Palette.fgTertiary; case .error: Palette.error } }

    private func errorLog(_ p: ProxySnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Error log").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                if !p.errorLogs.isEmpty { Text("· \(p.errorLogs.count) file\(p.errorLogs.count == 1 ? "" : "s")").font(Type.base(.semibold)).foregroundStyle(Palette.fg) }
                Text(p.errorLogs.isEmpty ? "nothing logged" : "~/.cli-proxy-api/logs").font(Type.sm()).foregroundStyle(Palette.fgTertiary)
                Spacer()
                Button("Reveal in Finder") { External.revealInFinder("~/.cli-proxy-api/logs") }.buttonStyle(.plain).font(Type.xs(.medium)).foregroundStyle(Palette.accent)
            }
            .frame(height: 36)
            ForEach(p.errorLogs.prefix(8)) { f in
                Hairline()
                HStack(spacing: 12) {
                    Text(f.modified.flatMap(ISO8601.parse).map { Fmt.time($0) } ?? "").font(Type.sm()).foregroundStyle(Palette.fgSecondary).frame(width: 60, alignment: .leading)
                    Text(f.name).font(Type.mono(12)).foregroundStyle(Palette.fg).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(f.name.contains("hello") ? "health probe" : "request").font(Type.xs()).foregroundStyle(Palette.fgTertiary)
                    Text("\(f.size) B").font(Type.xs()).foregroundStyle(Palette.fgTertiary).frame(width: 56, alignment: .trailing)
                }
                .frame(height: 30)
            }
            Hairline()
        }
    }

    private var gatedWrites: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Gated writes · each asks once and states the consequence · coming soon")
            Text("Re-login — opens the provider's OAuth in the browser; the account is paused until the new token lands.")
            Text("Pause / Resume — traffic moves to the other accounts of that provider; every tool using the proxy switches with it.")
            Text("Reset cooldown — retries now; if the quota is still exhausted the provider will refuse and the cooldown is re-armed.")
            Text("Update proxy — restarts CLIProxyAPI for ~3 s; in-flight requests retry once.")
        }
        .font(Type.sm()).foregroundStyle(Palette.fgSecondary)
    }
}
