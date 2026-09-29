// Design tokens from the Paper file (light values verbatim; dark values derived from the
// iconography board: ink #F2F3F5 on #1B1E24, status hues lifted one step, harness hues at L 0.68).

import ActlCore
import AppKit
import SwiftUI

enum Palette {
    private static func dyn(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(hex: dark, alpha: alpha) : NSColor(hex: light, alpha: alpha)
        })
    }

    static let bg = dyn(0xFFFFFF, 0x1B1E24)
    static let bgSidebar = dyn(0xF4F5F7, 0x202329)
    static let bgSunken = dyn(0xEEF0F3, 0x262930)
    static let bgHover = dyn(0xF0F2F5, 0x2A2E35)
    static let bgSelected = dyn(0xE8EEF9, 0x263246)
    static let fg = dyn(0x1B1E24, 0xF2F3F5)
    static let fgSecondary = dyn(0x5B6270, 0xA6ACB8)
    static let fgTertiary = dyn(0x8B929E, 0x7A8190)
    static let border = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(hex: 0xFFFFFF, alpha: 0.10) : NSColor(hex: 0x1B1E24, alpha: 0.10) })
    static let borderStrong = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(hex: 0xFFFFFF, alpha: 0.18) : NSColor(hex: 0x1B1E24, alpha: 0.18) })
    static let accent = dyn(0x0F6FE0, 0x4A96F0)
    static let accentSoft = dyn(0x0F6FE0, 0x4A96F0, alpha: 0.10)
    static let ok = dyn(0x2E8B57, 0x47A56E)
    static let okSoft = dyn(0x2E8B57, 0x47A56E, alpha: 0.12)
    static let warn = dyn(0xB7791F, 0xD3963A)
    static let warnSoft = dyn(0xB7791F, 0xD3963A, alpha: 0.14)
    static let error = dyn(0xC93B3B, 0xE25B5B)
    static let errorSoft = dyn(0xC93B3B, 0xE25B5B, alpha: 0.12)
    static let diffRemoved = dyn(0xC93B3B, 0xE25B5B, alpha: 0.10)
    static let diffAdded = dyn(0x2E8B57, 0x47A56E, alpha: 0.12)

    /// Harness hue for a colour slot: equal OKLCH lightness and chroma, so no harness shouts.
    static func harness(_ slot: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = HarnessPalette.color(slot: slot, dark: appearance.isDark)
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        })
    }

    static func harnessSoft(_ slot: Int) -> Color { harness(slot).opacity(0.12) }

    static func monogramBackground(_ name: String) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let rgb = Monogram.background(for: name, dark: a.isDark)
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        })
    }

    static func monogramForeground(_ name: String) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let rgb = Monogram.foreground(for: name, dark: a.isDark)
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        })
    }

    static func health(_ h: Health) -> Color {
        switch h {
        case .connected: return ok
        case .needsAuth, .pending: return warn
        case .failed: return error
        case .blocked, .unknown, .absent: return fgTertiary
        }
    }

    static func severity(_ s: Severity) -> Color {
        switch s {
        case .error: return error
        case .warn: return warn
        case .info: return fgSecondary
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The type scale: 11 / 12 / 13 / 15 / 20 / 28, always with tabular figures.
enum Type {
    static func xs(_ w: Font.Weight = .regular) -> Font { .system(size: 11, weight: w).monospacedDigit() }
    static func sm(_ w: Font.Weight = .regular) -> Font { .system(size: 12, weight: w).monospacedDigit() }
    static func base(_ w: Font.Weight = .regular) -> Font { .system(size: 13, weight: w).monospacedDigit() }
    static func md(_ w: Font.Weight = .semibold) -> Font { .system(size: 15, weight: w).monospacedDigit() }
    static func lg(_ w: Font.Weight = .semibold) -> Font { .system(size: 20, weight: w).monospacedDigit() }
    static func xl(_ w: Font.Weight = .semibold) -> Font { .system(size: 28, weight: w).monospacedDigit() }
    static func mono(_ size: CGFloat = 12) -> Font { .system(size: size, design: .monospaced).monospacedDigit() }
}

enum Radius {
    static let sm: CGFloat = 5
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
}

// MARK: - Icons (the 20-unit family from design/glyphs/icons-20.svg, rendered as templates)

enum IconName: String {
    case home, services, skills, instructions, proxy, contextBudget = "context-budget", reviewChanges = "review-changes", activity
    case connected = "status-connected", needsSignIn = "status-needs-sign-in", failed = "status-failed", blocked = "status-blocked"
    case syncing = "status-syncing", drift = "status-drift", update = "status-update", warn = "status-warn", gap = "status-gap", quota = "status-quota"
    case signIn = "action-sign-in", apply = "action-apply", review = "action-review", terminal = "action-terminal", copy = "action-copy", reveal = "action-reveal"
    case more = "action-more", search = "action-search", undo = "action-undo", settings = "action-settings"

    static func forHealth(_ h: Health) -> IconName {
        switch h {
        case .connected: return .connected
        case .needsAuth: return .needsSignIn
        case .failed: return .failed
        case .blocked, .absent: return .blocked
        case .pending: return .syncing
        case .unknown: return .blocked
        }
    }

    static func forAttention(_ k: AttentionKind, severity: Severity) -> IconName {
        switch k {
        case .failed: return .failed
        case .signIn: return .needsSignIn
        case .drift: return .drift
        case .sync: return .syncing
        case .update: return .update
        case .gap: return .gap
        case .quota: return .quota
        case .other: return severity == .error ? .failed : .warn
        }
    }
}

@MainActor
enum IconCache {
    private static var images: [String: NSImage] = [:]

    static func image(_ name: String, subdirectory: String = "icons") -> NSImage? {
        let key = subdirectory + "/" + name
        if let i = images[key] { return i }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources/\(subdirectory)") ?? Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: subdirectory),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        images[key] = img
        return img
    }
}

struct Icon: View {
    var name: IconName
    var size: CGFloat = 16
    var color: Color = Palette.fgSecondary

    init(_ name: IconName, size: CGFloat = 16, color: Color = Palette.fgSecondary) {
        self.name = name; self.size = size; self.color = color
    }

    var body: some View {
        Group {
            if let img = IconCache.image(name.rawValue) {
                Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high)
            } else {
                Image(systemName: "questionmark.circle").resizable()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }
}

// MARK: - Small shared views

/// Section label: caps, 11 semibold, +0.04em tracking, tertiary.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(Type.xs(.semibold))
            .tracking(0.44)
            .foregroundStyle(Palette.fgTertiary)
            .lineLimit(1)
    }
}

/// The 8 pt filled square used inline beside a harness name.
struct HarnessDot: View {
    var slot: Int
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Palette.harness(slot))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// The two-letter code chip (18 pt, or 14 pt in grids). Colour is never the only cue: the code is always drawn.
struct HarnessChip: View {
    var harness: Harness
    var slot: Int
    var size: CGFloat = 18
    var body: some View {
        RoundedRectangle(cornerRadius: size >= 18 ? 4 : 3, style: .continuous)
            .fill(Palette.harness(slot))
            .frame(width: size, height: size)
            .overlay {
                Text(harness.code)
                    .font(.system(size: size >= 18 ? 8 : 7, weight: .bold))
                    .tracking(0.16)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(harness.name)
    }
}

/// Status: icon plus word, always.
struct StatusLabel: View {
    var icon: IconName
    var word: String
    var color: Color
    var font: Font = Type.sm(.medium)
    var iconSize: CGFloat = 14

    init(icon: IconName, word: String, color: Color, font: Font = Type.sm(.medium), iconSize: CGFloat = 14) {
        self.icon = icon; self.word = word; self.color = color; self.font = font; self.iconSize = iconSize
    }

    init(health: Health, short: Bool = false, font: Font = Type.sm(.medium), iconSize: CGFloat = 14) {
        self.init(icon: .forHealth(health), word: short ? health.shortWord : health.word, color: Palette.health(health), font: font, iconSize: iconSize)
    }

    var body: some View {
        HStack(spacing: 5) {
            Icon(icon, size: iconSize, color: color)
            Text(word).font(font).foregroundStyle(color).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(word)
    }
}

/// A soft pill with icon and word (e.g. "Needs attention" in the popover header).
struct StatusPill: View {
    var level: StatusLevel
    var body: some View {
        let (icon, color, soft): (IconName, Color, Color) = switch level {
        case .healthy: (.connected, Palette.ok, Palette.okSoft)
        case .attention: (.warn, Palette.warn, Palette.warnSoft)
        case .error: (.failed, Palette.error, Palette.errorSoft)
        case .syncing: (.syncing, Palette.accent, Palette.accentSoft)
        }
        HStack(spacing: 6) {
            Icon(icon, size: 12, color: color)
            Text(level.word).font(Type.xs(.semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(soft, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Translucent hairline, never solid grey.
struct Hairline: View {
    var strong = false
    var body: some View {
        Rectangle().fill(strong ? Palette.borderStrong : Palette.border).frame(height: 1)
    }
}

struct VHairline: View {
    var body: some View { Rectangle().fill(Palette.border).frame(width: 1) }
}

/// One card style: white surface, 1 px translucent border, radius 8/10/12. Elevation declared once.
struct CardBackground: ViewModifier {
    var radius: CGFloat = Radius.md
    var fill: Color = Palette.bg
    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }
}

extension View {
    func card(radius: CGFloat = Radius.md, fill: Color = Palette.bg) -> some View { modifier(CardBackground(radius: radius, fill: fill)) }
}

/// Status chip anatomy shared by rows ("Failed", "Sign-in", "Drift"…): icon + word in the status colour.
struct KindChip: View {
    var kind: AttentionKind
    var severity: Severity
    var body: some View {
        let color: Color = switch kind {
        case .failed: Palette.error
        case .signIn, .drift, .quota: Palette.warn
        case .sync: Palette.accent
        case .update, .gap, .other: Palette.fgSecondary
        }
        StatusLabel(icon: .forAttention(kind, severity: severity), word: kind.word, color: color, font: Type.sm(.medium), iconSize: 14)
    }
}

/// Segmented bar for harness parity: connected / needs sign-in / failed / remainder.
struct ParityBar: View {
    var connected: Int
    var needsSignIn: Int
    var failed: Int
    var total: Int
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let denom = max(total, 1)
            let w = geo.size.width
            let gap: CGFloat = 2
            let segs: [(Int, Color)] = [(connected, Palette.ok), (needsSignIn, Palette.warn), (failed, Palette.error), (max(0, total - connected - needsSignIn - failed), Palette.bgSunken)]
            let visible = segs.filter { $0.0 > 0 }
            HStack(spacing: gap) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.1).frame(width: max(2, (w - gap * CGFloat(visible.count - 1)) * CGFloat(s.0) / CGFloat(denom)))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityLabel("\(connected) of \(total) connected, \(needsSignIn) need sign-in, \(failed) failed")
    }
}

/// Stacked context-budget bar: category tints from the harness hue, drift painted as the warn colour.
struct StackedBar: View {
    var slot: Int
    var categories: [BudgetCategoryTokens]
    var scale: Int   // the token count that fills the full width
    var height: CGFloat = 12

    static func tint(_ c: BudgetCategory, slot: Int) -> Color {
        switch c {
        case .plugins: return Palette.harness(slot)
        case .drift: return Palette.warn
        case .skillsListing: return Palette.harness(slot).opacity(0.55)
        case .instructions, .rules: return Palette.harness(slot).opacity(0.30)
        case .other: return Palette.harness(slot).opacity(0.2)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let denom = CGFloat(max(scale, 1))
            let gap: CGFloat = 2
            HStack(spacing: gap) {
                ForEach(categories.filter { $0.tokens > 0 }) { c in
                    Rectangle().fill(Self.tint(c.id, slot: slot)).frame(width: max(2, w * CGFloat(c.tokens) / denom - gap))
                }
                Spacer(minLength: 0)
            }
            .background(Palette.bgSunken)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// A single-colour sparkline (proxy traffic).
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var dashed = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(values.max() ?? 1, 1)
            Path { p in
                guard values.count > 1 else {
                    p.move(to: CGPoint(x: 0, y: h - 1)); p.addLine(to: CGPoint(x: w, y: h - 1)); return
                }
                for (i, v) in values.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(values.count - 1)
                    let y = (h - 1) - (h - 2) * CGFloat(v / maxV)
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: dashed ? [2, 3] : []))
        }
        .accessibilityHidden(true)
    }
}

/// Column-chart traffic (Proxy screen): successes on top of failures.
struct TrafficBars: View {
    var buckets: [ProxyBucket]
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let maxV = max(buckets.map { $0.success + $0.failed }.max() ?? 1, 1)
            let n = max(buckets.count, 1)
            let bw = max(2, (geo.size.width - CGFloat(n - 1) * 2) / CGFloat(n))
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                    let total = b.success + b.failed
                    VStack(spacing: 0) {
                        Rectangle().fill(color).frame(height: max(0, geo.size.height * CGFloat(b.success) / CGFloat(maxV)))
                        Rectangle().fill(Palette.error).frame(height: max(0, geo.size.height * CGFloat(b.failed) / CGFloat(maxV)))
                    }
                    .frame(width: bw, height: geo.size.height, alignment: .bottom)
                    .overlay(alignment: .bottom) {
                        if total == 0 { Rectangle().fill(Palette.borderStrong).frame(height: 1) }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Keyboard shortcut hint drawn beside a button label.
struct KeyHint: View {
    var text: String
    var body: some View {
        Text(text).font(Type.xs(.medium)).foregroundStyle(Palette.fgTertiary)
    }
}

/// Copyable command line: mono text in a sunken well.
struct CommandWell: View {
    var command: String
    var body: some View {
        HStack(spacing: 8) {
            Text(command).font(Type.mono(12)).foregroundStyle(Palette.fg).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Icon(.copy, size: 14, color: Palette.fgSecondary)
            }
            .buttonStyle(.plain)
            .help("Copy command")
            .accessibilityLabel("Copy command")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Palette.bgSunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}

/// Keeps layout geometry during loading: a text-shaped placeholder.
struct SkeletonLine: View {
    var width: CGFloat = 120
    var height: CGFloat = 12
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Palette.bgSunken)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

/// Calm inline error state with the engine's message and a retry.
struct InlineError: View {
    var message: String
    var retry: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(.failed, size: 16, color: Palette.error)
            VStack(alignment: .leading, spacing: 3) {
                Text("actl could not read this").font(Type.base(.medium)).foregroundStyle(Palette.fg)
                Text(message).font(Type.sm()).foregroundStyle(Palette.fgSecondary).textSelection(.enabled)
            }
            Spacer()
            if let retry { Button("Retry", action: retry).controlSize(.small) }
        }
        .padding(12)
        .background(Palette.errorSoft, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

/// Quiet note well used for "Parity: equal once you sign in" and similar explanations.
struct NoteWell: View {
    var icon: IconName = .connected
    var tint: Color = Palette.ok
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(icon, size: 14, color: tint).padding(.top, 2)
            Text(text).font(Type.base()).foregroundStyle(Palette.fg).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

extension View {
    /// Row hover highlight in lists (macOS-style, subtle).
    func hoverHighlight(_ radius: CGFloat = 6) -> some View { modifier(HoverHighlight(radius: radius)) }
}

private struct HoverHighlight: ViewModifier {
    var radius: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(hovering ? Palette.bgHover : .clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
    }
}
