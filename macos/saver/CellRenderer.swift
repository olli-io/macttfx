import AppKit
import CoreText

/// Draws a grid of cells with CoreText.
final class CellRenderer {
    static let defaultForeground: UInt32 = 0xE6E6E6
    static let defaultBackground: UInt32 = 0x000000

    let cellSize: CGSize

    /// Index: bit 0 = bold, bit 1 = italic.
    private let fonts: [CTFont]
    private let baseline: CGFloat
    private let lineThickness: CGFloat
    private var glyphs: [UInt64: (glyph: CGGlyph, font: CTFont)?] = [:]

    /// `scale` is the backing scale factor. The cell size is a whole number
    /// of device pixels, thus adjacent backgrounds have no gaps.
    init(fontName: String, fontSize: CGFloat, scale: CGFloat) {
        let size = max(fontSize, 1)
        let nsFont =
            NSFont(name: fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let base = nsFont as CTFont
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
        }
        fonts = [base, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]

        var character: UniChar = 0x4D  // "M"
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(base, &character, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        }
        let ascent = CTFontGetAscent(base)
        let descent = CTFontGetDescent(base)
        let leading = CTFontGetLeading(base)
        let scale = max(scale, 1)
        let width = max((advance.width * scale).rounded(), 1) / scale
        let height = max(((ascent + descent + leading) * scale).rounded(.up), 1) / scale
        cellSize = CGSize(width: width, height: height)
        baseline = (height - (ascent + descent)) / 2 + descent
        lineThickness = max((size / 14 * scale).rounded(), 1) / scale
    }

    /// The number of cells that fit in `size`.
    func gridSize(for size: CGSize) -> (cols: Int, rows: Int) {
        (max(Int(size.width / cellSize.width), 1), max(Int(size.height / cellSize.height), 1))
    }

    func draw(
        cells: UnsafeBufferPointer<TtfxCell>, cols: Int, rows: Int, in context: CGContext,
        bounds: CGRect
    ) {
        guard cells.count >= cols * rows else { return }
        let width = cellSize.width
        let height = cellSize.height
        // The grid is in the centre of the view.
        let originX = bounds.minX + ((bounds.width - CGFloat(cols) * width) / 2).rounded(.down)
        let originY = bounds.minY + ((bounds.height - CGFloat(rows) * height) / 2).rounded(.down)

        for row in 0..<rows {
            let y = originY + CGFloat(rows - 1 - row) * height
            for col in 0..<cols {
                let cell = cells[row * cols + col]
                let attrs = UInt32(cell.attrs)
                let flags = UInt32(cell.flags)
                var foreground = flags & TTFX_FLAG_FG != 0 ? cell.fg : Self.defaultForeground
                var background: UInt32? = flags & TTFX_FLAG_BG != 0 ? cell.bg : nil
                if attrs & TTFX_ATTR_REVERSE != 0 {
                    (foreground, background) = (background ?? Self.defaultBackground, foreground)
                }
                let rect = CGRect(x: originX + CGFloat(col) * width, y: y, width: width, height: height)
                if let background {
                    setFill(context, background, alpha: 1)
                    context.fill(rect)
                }
                if cell.codepoint == 0x20 || attrs & TTFX_ATTR_HIDDEN != 0 {
                    continue
                }
                let alpha: CGFloat = attrs & TTFX_ATTR_DIM != 0 ? 0.5 : 1
                setFill(context, foreground, alpha: alpha)
                if !drawBlock(cell.codepoint, rect, foreground, alpha, context) {
                    drawGlyph(cell.codepoint, attrs, rect, context)
                }
                if attrs & TTFX_ATTR_UNDERLINE != 0 {
                    context.fill(
                        CGRect(
                            x: rect.minX, y: rect.minY + baseline - 2 * lineThickness,
                            width: width, height: lineThickness))
                }
                if attrs & TTFX_ATTR_STRIKE != 0 {
                    context.fill(
                        CGRect(
                            x: rect.minX, y: rect.minY + baseline + height * 0.22,
                            width: width, height: lineThickness))
                }
            }
        }
    }

    private func setFill(_ context: CGContext, _ rgb: UInt32, alpha: CGFloat) {
        context.setFillColor(
            red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    private func drawGlyph(_ codepoint: UInt32, _ attrs: UInt32, _ rect: CGRect, _ context: CGContext) {
        var style = 0
        if attrs & TTFX_ATTR_BOLD != 0 { style |= 1 }
        if attrs & TTFX_ATTR_ITALIC != 0 { style |= 2 }
        guard let entry = glyph(for: codepoint, style: style) else { return }
        var glyph = entry.glyph
        var position = CGPoint(x: rect.minX, y: rect.minY + baseline)
        CTFontDrawGlyphs(entry.font, &glyph, &position, 1, context)
    }

    /// The glyph and its font. If the selected font does not have the
    /// character, the system gives a fallback font.
    private func glyph(for codepoint: UInt32, style: Int) -> (glyph: CGGlyph, font: CTFont)? {
        let key = UInt64(codepoint) | UInt64(style) << 32
        if let cached = glyphs[key] {
            return cached
        }
        var result: (glyph: CGGlyph, font: CTFont)?
        if let scalar = Unicode.Scalar(codepoint) {
            let units = Array(String(Character(scalar)).utf16)
            var found = [CGGlyph](repeating: 0, count: units.count)
            let font = fonts[style]
            if CTFontGetGlyphsForCharacters(font, units, &found, units.count) {
                result = (found[0], font)
            } else {
                let string = String(Character(scalar)) as CFString
                let fallback = CTFontCreateForString(font, string, CFRange(location: 0, length: units.count))
                if CTFontGetGlyphsForCharacters(fallback, units, &found, units.count) {
                    result = (found[0], fallback)
                }
            }
        }
        glyphs[key] = .some(result)
        return result
    }

    /// Draws the Unicode block elements (U+2580 to U+259F) as rectangles.
    /// Font glyphs for these characters can leave gaps between cells.
    private func drawBlock(
        _ codepoint: UInt32, _ rect: CGRect, _ rgb: UInt32, _ alpha: CGFloat, _ context: CGContext
    ) -> Bool {
        guard (0x2580...0x259F).contains(codepoint) else { return false }
        let w = rect.width
        let h = rect.height
        func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            context.fill(
                CGRect(x: rect.minX + x * w, y: rect.minY + y * h, width: width * w, height: height * h))
        }
        switch codepoint {
        case 0x2580: fill(0, 0.5, 1, 0.5)
        case 0x2581...0x2588: fill(0, 0, 1, CGFloat(codepoint - 0x2580) / 8)
        case 0x2589...0x258F: fill(0, 0, CGFloat(0x2590 - codepoint) / 8, 1)
        case 0x2590: fill(0.5, 0, 0.5, 1)
        case 0x2591...0x2593:
            setFill(context, rgb, alpha: alpha * CGFloat(codepoint - 0x2590) / 4)
            fill(0, 0, 1, 1)
        case 0x2594: fill(0, 0.875, 1, 0.125)
        case 0x2595: fill(0.875, 0, 0.125, 1)
        default:
            // Quadrants. Bits: 1 = upper left, 2 = upper right, 4 = lower
            // left, 8 = lower right.
            let masks: [UInt32] = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14]
            let mask = masks[Int(codepoint - 0x2596)]
            if mask & 1 != 0 { fill(0, 0.5, 0.5, 0.5) }
            if mask & 2 != 0 { fill(0.5, 0.5, 0.5, 0.5) }
            if mask & 4 != 0 { fill(0, 0, 0.5, 0.5) }
            if mask & 8 != 0 { fill(0.5, 0, 0.5, 0.5) }
        }
        return true
    }
}
