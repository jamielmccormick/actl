// The sign-in queue: runs `login --json` per server in order, shows "waiting for browser",
// auto-continues per the setting, and supports Continue, Skip and Stop.

import ActlCore
import SwiftUI

struct SignInQueueView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let q = store.signIn {
                card(q)
            } else {
                emptyState
            }
        }
        .padding(16)
        .frame(width: 420)
        .background(Palette.bg)
        .onChange(of: store.signIn == nil) { _, gone in if gone { dismiss() } }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing to sign in to").font(Type.base(.semibold)).foregroundStyle(Palette.fg)
            Text("Every service that can sign in is connected.").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
            Button("Close") { dismiss() }
        }
    }

    @ViewBuilder
    private func card(_ q: SignInQueue) -> some View {
        if let item = q.current {
            let service = store.services.value?.first { $0.id == item.serviceId }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    ServiceMark(name: item.serviceName, logo: service?.logo, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(item)).font(Type.base(.semibold)).foregroundStyle(Palette.fg)
                        Text("\(store.harness(item.harness)?.name ?? item.harness) · \(q.index + 1) of \(q.items.count)").font(Type.xs()).foregroundStyle(Palette.fgTertiary)
                    }
                    Spacer()
                    trailingIcon(item.state)
                }
                Text(body(item, q)).font(Type.sm()).foregroundStyle(Palette.fgSecondary).fixedSize(horizontal: false, vertical: true)
                controls(item, q)
                progressDots(q)
                Toggle(isOn: Binding(get: { q.autoContinue }, set: { store.setSignInAutoContinue($0) })) {
                    Text("Continue to the next sign-in automatically").font(Type.sm()).foregroundStyle(Palette.fg)
                }
                .toggleStyle(.switch).controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                StatusLabel(icon: .connected, word: "Signed in to \(q.doneCount) of \(q.items.count)", color: Palette.ok, font: Type.base(.semibold), iconSize: 16)
                Button("Done") { store.stopSignIn() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func title(_ item: SignInItem) -> String {
        switch item.state {
        case .queued, .opening: return "Opening \(item.serviceName)…"
        case .waiting: return "Signing in to \(item.serviceName)"
        case .done: return "\(item.serviceName) connected in \(store.harness(item.harness)?.name ?? item.harness)"
        case .failed: return "\(item.serviceName) did not connect"
        case .skipped: return "Skipped \(item.serviceName)"
        }
    }

    private func body(_ item: SignInItem, _ q: SignInQueue) -> String {
        switch item.state {
        case .queued, .opening: return "Starting \(item.harness) mcp login \(item.server)."
        case .waiting:
            let secs = Int(Date().timeIntervalSince(q.startedAt))
            return "Waiting for the browser. Finish the sign-in there and this sheet moves on by itself." + (secs > 60 ? " Started \(secs / 60) min ago." : "")
        case .done: return q.autoContinue ? "Moving on to the next one." : (q.next.map { "Next: \($0.serviceName) · \(q.index + 2) of \(q.items.count)" } ?? "That was the last one.")
        case .failed(let m): return m ?? "The harness reported an error. You can retry, or skip and come back later."
        case .skipped: return ""
        }
    }

    @ViewBuilder
    private func trailingIcon(_ s: SignInItem.State) -> some View {
        switch s {
        case .queued, .opening, .waiting: ProgressView().controlSize(.small)
        case .done: Icon(.connected, size: 18, color: Palette.ok)
        case .failed: Icon(.failed, size: 18, color: Palette.error)
        case .skipped: Icon(.blocked, size: 18, color: Palette.fgTertiary)
        }
    }

    @ViewBuilder
    private func controls(_ item: SignInItem, _ q: SignInQueue) -> some View {
        HStack(spacing: 8) {
            switch item.state {
            case .waiting, .opening, .queued:
                Button("Reopen browser") { store.retrySignIn() }
                Button("Skip") { store.skipSignIn() }
            case .done:
                if q.awaitingContinue {
                    HStack(spacing: 8) {
                        Text(q.next.map { "Next: \($0.serviceName)" } ?? "All done").font(Type.sm()).foregroundStyle(Palette.fgSecondary)
                        Spacer()
                        Button { store.continueSignIn() } label: { HStack(spacing: 6) { Text(q.next == nil ? "Done" : "Continue"); KeyHint(text: "↩").foregroundStyle(.white.opacity(0.7)) } }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [])
                    }
                    .padding(10).frame(maxWidth: .infinity).background(Palette.bgSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            case .failed:
                Button("Retry") { store.retrySignIn() }.buttonStyle(.borderedProminent)
                Button("Skip") { store.skipSignIn() }
            case .skipped:
                Button("Continue") { store.continueSignIn() }
            }
            if item.state != .done || !q.awaitingContinue {
                Spacer()
                Button("Stop queue") { store.stopSignIn() }.buttonStyle(.plain).font(Type.sm()).foregroundStyle(Palette.fgTertiary)
            }
        }
    }

    private func progressDots(_ q: SignInQueue) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(q.items.enumerated()), id: \.offset) { i, it in
                RoundedRectangle(cornerRadius: 1.5).fill(color(it.state, isCurrent: i == q.index)).frame(height: 3).frame(maxWidth: .infinity)
            }
        }
        .accessibilityLabel("\(q.doneCount) of \(q.items.count) signed in")
    }

    private func color(_ s: SignInItem.State, isCurrent: Bool) -> Color {
        switch s {
        case .done: return Palette.ok
        case .failed: return Palette.error
        case .skipped: return Palette.fgTertiary
        default: return isCurrent ? Palette.accent : Palette.bgSunken
        }
    }
}
