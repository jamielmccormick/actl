// One container for every service logo: squircle tile at 16/20/28/40, hairline edge inside,
// full-bleed app icons vs inset glyphs, low-res sources rendered smaller (never upscaled),
// and a deterministic monogram when there is no usable file.

import ActlCore
import AppKit
import SwiftUI

@MainActor
enum LogoCache {
    private static var images: [String: NSImage?] = [:]

    static func image(for path: String) -> NSImage? {
        if let cached = images[path] { return cached }
        let expanded = (path as NSString).expandingTildeInPath
        let img = NSImage(contentsOfFile: expanded)
        // ICO files sometimes load as empty reps; treat them as unusable.
        let usable = img.flatMap { $0.representations.isEmpty || $0.size.width < 8 ? nil : $0 }
        images[path] = usable
        return usable
    }

    /// Pixel width of the best representation (used for the never-upscale rule).
    static func pixelWidth(_ img: NSImage) -> Int {
        img.representations.map(\.pixelsWide).max() ?? Int(img.size.width)
    }

    /// True when the image has transparent corners (a glyph on a transparent ground) rather than a full-bleed icon.
    static func isGlyph(_ img: NSImage) -> Bool {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return false }
        let w = cg.width, h = cg.height, bpr = cg.bytesPerRow, bpp = max(cg.bitsPerPixel / 8, 1)
        guard w > 2, h > 2, bpp == 4 else { return false }
        let alphaFirst = cg.alphaInfo == .premultipliedFirst || cg.alphaInfo == .first
        let alphaLast = cg.alphaInfo == .premultipliedLast || cg.alphaInfo == .last
        guard alphaFirst || alphaLast else { return false }
        let ai = alphaFirst ? 0 : 3
        func alpha(_ x: Int, _ y: Int) -> UInt8 { ptr[y * bpr + x * bpp + ai] }
        let corners = [alpha(0, 0), alpha(w - 1, 0), alpha(0, h - 1), alpha(w - 1, h - 1)]
        return corners.filter { $0 < 24 }.count >= 3
    }
}

struct ServiceMark: View {
    var name: String
    var logo: String?
    var size: CGFloat = 28

    init(_ service: Service, size: CGFloat = 28) {
        self.name = service.name; self.logo = service.logo; self.size = size
    }

    init(name: String, logo: String? = nil, size: CGFloat = 28) {
        self.name = name; self.logo = logo; self.size = size
    }

    private var radius: CGFloat { size * 0.25 }

    var body: some View {
        ZStack {
            if let logo, let img = LogoCache.image(for: logo) {
                logoTile(img)
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityLabel("\(name) logo")
    }

    @ViewBuilder
    private func logoTile(_ img: NSImage) -> some View {
        let px = LogoCache.pixelWidth(img)
        let glyph = LogoCache.isGlyph(img)
        // Never render above 1× at 2× density: a 32 px source is at most 16 pt.
        let cap = CGFloat(px) / 2
        if glyph {
            // Glyph inset 20% each side (60% of the tile), rounded down to the 10/12/16/24 scale when the source is small.
            let natural = size * 0.6
            let side = min(natural, cap)
            Palette.bg
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: side, height: side)
        } else if cap < size {
            // Low-res full-bleed source: shown smaller on a white well instead of stretched.
            let side = max(10, min(cap, size * 0.6))
            Palette.bg
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.25, style: .continuous))
        } else {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        }
    }

    private var monogram: some View {
        ZStack {
            Palette.monogramBackground(name)
            Text(Monogram.initials(for: name))
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Palette.monogramForeground(name))
                .offset(y: size * 0.01)
        }
    }
}
