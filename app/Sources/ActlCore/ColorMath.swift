// OKLCH → sRGB, the harness palette, and the deterministic monogram hue.
// The design specifies colours in OKLCH so all harness hues share one perceived lightness.

import Foundation

public struct RGB: Sendable, Hashable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

public enum OKLCH {
    /// Converts OKLCH (L 0–1, C, hue degrees) to gamma-encoded sRGB, clamped to gamut.
    public static func toSRGB(l: Double, c: Double, h: Double) -> RGB {
        let hr = h * .pi / 180
        let a = c * cos(hr), b = c * sin(hr)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_
        let r = +4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        return RGB(r: gamma(r), g: gamma(g), b: gamma(bl))
    }

    private static func gamma(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

/// The six harness hues from the design (`--harness-1…6`). Light: L 0.56 C 0.11. Dark lifts to L 0.68.
public enum HarnessPalette {
    public static let hues: [Double] = [45, 165, 255, 310, 340, 210]
    public static let names = ["clay", "spruce", "slate blue", "heather", "rose", "teal"]

    public static func color(slot: Int, dark: Bool) -> RGB {
        let h = hues[((slot % hues.count) + hues.count) % hues.count]
        return OKLCH.toSRGB(l: dark ? 0.68 : 0.56, c: 0.11, h: h)
    }
}

/// Deterministic monogram: hue = (Σ char codes × 37) mod 360.
/// Light: background oklch(0.95 0.035 h), letter oklch(0.50 0.14 h). Dark: 0.30/0.05 and 0.85/0.10.
public enum Monogram {
    public static func hue(for name: String) -> Double {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double((sum * 37) % 360)
    }

    /// One letter for one-word names, two (first letters) for multi-word names.
    public static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
        if words.count >= 2 {
            return String(words.prefix(2).compactMap { $0.first }).capitalizedFirstOnly
        }
        return String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    public static func background(for name: String, dark: Bool) -> RGB {
        let h = hue(for: name)
        return dark ? OKLCH.toSRGB(l: 0.30, c: 0.05, h: h) : OKLCH.toSRGB(l: 0.95, c: 0.035, h: h)
    }

    public static func foreground(for name: String, dark: Bool) -> RGB {
        let h = hue(for: name)
        return dark ? OKLCH.toSRGB(l: 0.85, c: 0.10, h: h) : OKLCH.toSRGB(l: 0.50, c: 0.14, h: h)
    }
}

private extension String {
    /// Two-letter codes: first letter uppercase, second from the next word or letter (e.g. "Acme Pulse" → "AP").
    var capitalizedFirstOnly: String { uppercased() }
}
