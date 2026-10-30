// Generates app/Resources/AppIcon.icns, the icon of the app (Dock-less menu-bar app: the icon is what macOS shows in
// notifications, System Settings > Notifications / Privacy & Security, and Finder).
//
// Design: a rounded square on the macOS icon grid with a rich gradient, a soft light from the top left, a glass sheen, an inner rim and a gentle
// drop shadow, and a glyph on it. Two families, chosen with --variant:
//   D1  a clipboard with written lines and a pen (the shipped icon)      D2  a speech bubble with lines of text and a small pen
//   D3  a notebook page with a handwriting scribble and a small recording dot
//   A   deep indigo glass, white waveform      B  bright blue, clean      C  graphite with a blue waveform     (the former waveform icons, still available)
// The notes-and-pen family (D1 to D3) replaced the waveform: a waveform on a rounded square comes close to the look of Apple's Voice Memos icon. The menu-bar symbols
// (pencil.and.list.clipboard and friends, StatusMenu.swift) follow the same idea.
// Every size is drawn directly at its own pixel size (not scaled down from one big bitmap). The two small sizes (16 and 32 px) are a compact variant:
// whole-pixel body edges, whole-pixel paper, bars and lines, a thick pen, a bigger dot, and none of the soft effects (shadow, glow, halo, sheen, rim),
// which would only turn into mud at that size.
//
// Only CoreGraphics + ImageIO + the iconutil that ships with macOS: no third-party tool, no window server, no network, no
// files outside the output paths and a temporary directory. The output is deterministic (same bytes on every run).
//
//   swiftc -O scripts/make_icon.swift -o /tmp/make_icon && /tmp/make_icon app/Resources/AppIcon.icns
//   swift scripts/make_icon.swift app/Resources/AppIcon.icns                # same thing through the interpreter
//   ... --variant D1|D2|D3|A|B|C   the design (default D1; the committed AppIcon.icns is D1)
//   ... --keep-iconset DIR      also keep the ten PNGs of the .iconset in DIR (to look at them)
//   ... --png FILE [--size N]   write one PNG (default 512 px) of the chosen variant, e.g. to compare the variants; the .icns is then optional
//
// Exit codes: 0 ok, 1 rendering / iconutil failure, 2 usage.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Moods

private func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    return CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

private struct Variant {
    var name: String
    /// The body gradient, from the top left to the bottom right: (location 0...1, colour).
    var body: [(CGFloat, CGColor)]
    var light: CGFloat                  // alpha of the white light from the top left
    var sheen: CGFloat                  // alpha at the top of the glass sheen (0 = none)
    var rimTop: CGFloat                 // alpha of the white hairline rim at the top ... at the bottom
    var rimBottom: CGFloat
    var edgeShade: CGFloat              // alpha of the dark inner edge at the bottom (volume)
    var barTop: CGColor                 // the waveform gradient, top ... bottom (faint white-to-ice)
    var barBottom: CGColor
    var glow: CGColor                   // the soft glow around the waveform
    var compactBar: CGColor             // the waveform at 16 / 32 px (flat: a gradient is invisible there)
    var shadow: CGFloat                 // alpha of the drop shadow
    // The notes-and-pen family (D1 ... D3); the waveform variants leave these at their defaults and never read them.
    var glyph: Glyph = .waveform
    var paperTop: CGColor = rgb(0xFFFFFF)       // the board / page: white at the top ...
    var paperBottom: CGColor = rgb(0xD4E2FF)    // ... to ice at the bottom
    var ink: CGColor = rgb(0x3B4CD0)            // the written lines
    var penBody: [(CGFloat, CGColor)] = [(0, rgb(0xFFD56B)), (1, rgb(0xFF9A1F))]    // the pen: light side to shade side
    var clip: [(CGFloat, CGColor)] = [(0, rgb(0x9AA8D4)), (1, rgb(0x56668F))]       // the metal clip of the clipboard
}

private enum Glyph { case waveform, clipboard, bubble, notebook }

private let variants: [String: Variant] = [
    // A: deep indigo glass
    "A": Variant(name: "A",
                 body: [(0, rgb(0x6A98FF)), (0.40, rgb(0x4458EA)), (1, rgb(0x241780))],
                 light: 0.34, sheen: 0.20, rimTop: 0.62, rimBottom: 0.08, edgeShade: 0.30,
                 barTop: rgb(0xFFFFFF), barBottom: rgb(0xCADBFF), glow: rgb(0xB9CEFF, 0.78),
                 compactBar: rgb(0xFFFFFF), shadow: 0.34),
    // B: bright blue, clean (no sheen; lighter and more saturated)
    "B": Variant(name: "B",
                 body: [(0, rgb(0x6FD0FF)), (0.50, rgb(0x2E80FF)), (1, rgb(0x3050E6))],
                 light: 0.30, sheen: 0, rimTop: 0.55, rimBottom: 0.14, edgeShade: 0.16,
                 barTop: rgb(0xFFFFFF), barBottom: rgb(0xDCEBFF), glow: rgb(0xFFFFFF, 0.62),
                 compactBar: rgb(0xFFFFFF), shadow: 0.30),
    // C: graphite with a blue waveform
    "C": Variant(name: "C",
                 body: [(0, rgb(0x555B69)), (0.45, rgb(0x2D313B)), (1, rgb(0x14161C))],
                 light: 0.16, sheen: 0.10, rimTop: 0.34, rimBottom: 0.05, edgeShade: 0.34,
                 barTop: rgb(0xB4DBFF), barBottom: rgb(0x3C8CFF), glow: rgb(0x4C9BFF, 0.78),
                 compactBar: rgb(0x5BA6FF), shadow: 0.40),
    // D1: a clipboard with written lines and a pen on deep indigo glass (the shipped icon)
    "D1": Variant(name: "D1",
                  body: [(0, rgb(0x6A98FF)), (0.40, rgb(0x4458EA)), (1, rgb(0x241780))],
                  light: 0.34, sheen: 0.20, rimTop: 0.62, rimBottom: 0.08, edgeShade: 0.30,
                  barTop: rgb(0xFFFFFF), barBottom: rgb(0xCADBFF), glow: rgb(0xB9CEFF, 0.78),
                  compactBar: rgb(0xFFFFFF), shadow: 0.34, glyph: .clipboard),
    // D2: a speech bubble with lines of text and a small pen on teal-to-blue glass
    "D2": Variant(name: "D2",
                  body: [(0, rgb(0x5EE0D2)), (0.45, rgb(0x1E8FE6)), (1, rgb(0x1B3FA8))],
                  light: 0.32, sheen: 0.18, rimTop: 0.60, rimBottom: 0.10, edgeShade: 0.28,
                  barTop: rgb(0xFFFFFF), barBottom: rgb(0xCADBFF), glow: rgb(0xB9CEFF, 0.78),
                  compactBar: rgb(0xFFFFFF), shadow: 0.34, glyph: .bubble, ink: rgb(0x1F6FD0)),
    // D3: a notebook page with a handwriting scribble and a small recording dot on violet glass
    "D3": Variant(name: "D3",
                  body: [(0, rgb(0xB59BFF)), (0.45, rgb(0x6A47E0)), (1, rgb(0x2E1B86))],
                  light: 0.34, sheen: 0.20, rimTop: 0.62, rimBottom: 0.08, edgeShade: 0.30,
                  barTop: rgb(0xFFFFFF), barBottom: rgb(0xCADBFF), glow: rgb(0xB9CEFF, 0.78),
                  compactBar: rgb(0xFFFFFF), shadow: 0.34, glyph: .notebook, ink: rgb(0x4A32C8)),
]

// MARK: - Geometry

private struct Layout {
    let pixels: Int
    var s: CGFloat { CGFloat(pixels) }
    /// Tiny sizes (16 and 32 px): fewer bars, thicker, on the pixel grid, no soft effects, bigger dot.
    var compact: Bool { pixels <= 32 }
    /// The macOS icon grid leaves ~10% around the rounded square (824 of 1024 px); tiny sizes use less so the glyph keeps its pixels.
    /// A whole number of pixels, so the edge of the shape is crisp at every size.
    var margin: CGFloat { compact ? max(1, (s * 0.04).rounded()) : (s * 0.098).rounded() }
    var body: CGRect { CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin) }
    var cornerRadius: CGFloat { body.width * 0.2237 }       // the radius ratio of the macOS app-icon shape

    // Bars: fractions of the body.
    var barHeights: [CGFloat] { compact ? [0.36, 0.64, 0.40, 0.26] : [0.22, 0.42, 0.64, 0.45, 0.26] }
    var barWidth: CGFloat { compact ? 0.13 : 0.080 }
    var barGap: CGFloat { compact ? 0.075 : 0.050 }
    var barCenterY: CGFloat { compact ? 0.40 : 0.45 }       // of the body height, measured from the bottom

    var dotCenter: CGPoint { compact ? CGPoint(x: 0.78, y: 0.78) : CGPoint(x: 0.80, y: 0.80) }    // fractions of the body
    var dotRadius: CGFloat { compact ? 0.12 : 0.086 }
    var dotRim: CGFloat { compact ? 0.035 : 0.021 }
}

// MARK: - Drawing

private func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Light (or shade) that bleeds into the shape from its edge: the shape's own outline is cut out of a big frame, the frame casts a
/// shadow, and the clip keeps only the part of that shadow that falls inside the shape. The offset decides which edge gets more of it.
private func innerShadow(_ ctx: CGContext, shape: CGPath, bounds: CGRect, color: CGColor, offset: CGSize, blur: CGFloat) {
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let frame = CGMutablePath()
    frame.addRect(bounds.insetBy(dx: -bounds.width, dy: -bounds.height))
    frame.addPath(shape)
    ctx.setShadow(offset: offset, blur: blur, color: color)
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))      // never seen: the frame lies outside the clip
    ctx.addPath(frame)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

private func render(pixels: Int, variant V: Variant) -> CGImage? {
    let L = Layout(pixels: pixels)
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: L.s, height: L.s))

    let s = L.s
    let body = L.body
    let w = body.width, h = body.height
    let shape = roundedRect(body, L.cornerRadius)
    func bx(_ u: CGFloat) -> CGFloat { return body.minX + u * w }       // body fractions -> pixels (from the left / from the bottom)
    func by(_ v: CGFloat) -> CGFloat { return body.minY + v * h }
    func white(_ a: CGFloat) -> CGColor { return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
    func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
        return CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations)
    }

    // 1. drop shadow under the shape: a wide soft one and a tight one (not at tiny sizes: it would only blur the edge).
    //    At 1024 px the wide one reaches 34 px beyond the body, inside the 100 px margin of the icon grid.
    if !L.compact {
        for (dy, blur, alpha) in [(0.0125, 0.026, V.shadow), (0.004, 0.008, V.shadow * 0.7)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -s * dy), blur: s * blur, color: CGColor(srgbRed: 0.04, green: 0.03, blue: 0.16, alpha: alpha))
            ctx.setFillColor(V.body[V.body.count - 1].1)
            ctx.addPath(shape)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    // 2. the body: gradient, light from the top left, glass sheen, inner rim; all clipped to the shape
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    if let g = gradient(V.body.map { $0.1 }, V.body.map { $0.0 }) {
        ctx.drawLinearGradient(g, start: CGPoint(x: bx(0.18), y: body.maxY), end: CGPoint(x: bx(0.84), y: body.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    if !L.compact {
        // light from the top left
        if let g = gradient([white(V.light), white(V.light * 0.35), white(0)], [0, 0.45, 1]) {
            let c = CGPoint(x: bx(0.20), y: by(0.90))
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 0.95 * w, options: [])
        }
        // glass sheen: the top of the shape under a big ellipse, fading downward
        if V.sheen > 0, let g = gradient([white(V.sheen), white(V.sheen * 0.12)], [0, 1]) {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: bx(-0.25), y: by(0.66), width: 1.5 * w, height: 1.2 * h))
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: by(0.66)), options: [])
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()

    if !L.compact {
        // volume: a dark inner edge at the bottom, a soft white inner highlight along the top, then a hairline rim that fades downward
        innerShadow(ctx, shape: shape, bounds: body, color: CGColor(srgbRed: 0.03, green: 0.02, blue: 0.20, alpha: V.edgeShade), offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.030)
        innerShadow(ctx, shape: shape, bounds: body, color: white(0.40), offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.020)
        let rim = max(1, (s * 0.0045).rounded())
        ctx.saveGState()
        ctx.addPath(roundedRect(body.insetBy(dx: rim / 2, dy: rim / 2), L.cornerRadius - rim / 2))
        ctx.setLineWidth(rim)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        if let g = gradient([white(V.rimTop), white(V.rimBottom)], [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
        }
        ctx.restoreGState()
    }

    // 3.-5. the glyph. The waveform of the variants A to C is drawn exactly as it always was; the notes-and-pen family has its own drawing (drawNotes).
    func drawWaveformGlyph() {
        // 3. the red halo of the recording dot sits behind the waveform and inside the shape
        let red = rgb(0xFF3B30)
        var c = CGPoint(x: bx(L.dotCenter.x), y: by(L.dotCenter.y))
        var r = L.dotRadius * w
        let rim = L.compact ? max(1, (L.dotRim * w).rounded()) : max(1, L.dotRim * w)
        if L.compact {                                      // a whole number of pixels across, centred so that its edge is symmetric
            r = max(1.5, (r * 2).rounded(.down) / 2)
            let off: CGFloat = Int(r * 2) % 2 == 0 ? 0 : 0.5
            c = CGPoint(x: (c.x - off).rounded() + off, y: (c.y - off).rounded() + off)
        }
        if !L.compact, let g = gradient([rgb(0xFF3B30, 0.55), rgb(0xFF3B30, 0.18), rgb(0xFF3B30, 0)], [0, 0.45, 1]) {
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.drawRadialGradient(g, startCenter: c, startRadius: r * 0.6, endCenter: c, endRadius: r * 2.5, options: [])
            ctx.restoreGState()
        }

        // 4. the waveform: rounded bars, centred on the body. Layers: tight dark shadow, soft glow, then the gradient (flat when compact).
        let n = L.barHeights.count
        let barW = L.barWidth * w
        let gap = L.barGap * w
        let total = CGFloat(n) * barW + CGFloat(n - 1) * gap
        var centerY = by(L.barCenterY)
        var x = bx(0.5) - total / 2
        if L.compact {                                                         // bars start on a pixel boundary, centred on a pixel row
            x = x.rounded(.down)
            centerY = (centerY - 0.5).rounded() + 0.5
        }
        var bars: [CGPath] = []
        for hFrac in L.barHeights {
            var bw = barW, height = hFrac * h
            var originY = centerY - height / 2
            if L.compact {                                                     // snap to whole pixels: crisp 2-4 px bars, an odd height so they share one centre line
                bw = max(1, barW.rounded())
                height = max(3, 2 * ((height - 1) / 2).rounded() + 1)
                originY = centerY - height / 2
            }
            bars.append(roundedRect(CGRect(x: x, y: originY, width: bw, height: height), min(bw, height) / 2))
            x += bw + (L.compact ? max(1, gap.rounded()) : gap)
        }
        if L.compact {
            ctx.setFillColor(V.compactBar)
            for p in bars { ctx.addPath(p); ctx.fillPath() }
        } else {
            for (dy, blur, color) in [(0.007, 0.014, CGColor(srgbRed: 0.02, green: 0.02, blue: 0.20, alpha: 0.38)),
                                      (0.0, 0.050, V.glow)] as [(CGFloat, CGFloat, CGColor)] {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -s * dy), blur: s * blur, color: color)
                ctx.setFillColor(V.barBottom)
                for p in bars { ctx.addPath(p) }
                ctx.fillPath()
                ctx.restoreGState()
            }
            let top = centerY + L.barHeights.max()! * h / 2, bottom = centerY - L.barHeights.max()! * h / 2
            if let g = gradient([V.barTop, V.barBottom], [0, 1]) {
                ctx.saveGState()
                for p in bars { ctx.addPath(p) }
                ctx.clip()
                ctx.drawLinearGradient(g, start: CGPoint(x: bx(0.5), y: top), end: CGPoint(x: bx(0.5), y: bottom), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                ctx.restoreGState()
            }
        }

        // 5. the red recording dot: white rim, glossy red
        ctx.saveGState()
        if !L.compact {
            ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.005), blur: s * 0.012, color: CGColor(srgbRed: 0.1, green: 0, blue: 0.1, alpha: 0.35))
        }
        ctx.setFillColor(white(1))
        ctx.fillEllipse(in: CGRect(x: c.x - r - rim, y: c.y - r - rim, width: 2 * (r + rim), height: 2 * (r + rim)))
        ctx.restoreGState()
        let dot = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(red)
        ctx.fillEllipse(in: dot)
        if !L.compact {
            ctx.saveGState()
            ctx.addEllipse(in: dot)
            ctx.clip()
            if let g = gradient([rgb(0xFF7B6E), rgb(0xFF3B30), rgb(0xD81C13)], [0, 0.5, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: c.y - r), options: [])
            }
            if let g = gradient([white(0.55), white(0)], [0, 1]) {                    // a small specular highlight, upper left
                let hl = CGPoint(x: c.x - r * 0.28, y: c.y + r * 0.34)
                ctx.drawRadialGradient(g, startCenter: hl, startRadius: 0, endCenter: hl, endRadius: r * 0.55, options: [])
            }
            ctx.restoreGState()
        }
    }
    switch V.glyph {
    case .waveform: drawWaveformGlyph()
    case .clipboard, .bubble, .notebook: drawNotes(ctx: ctx, cs: cs, L: L, V: V, shape: shape, body: body)
    }

    return ctx.makeImage()
}

private func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

// MARK: - The notes-and-pen glyphs (D1 to D3)

private func gradientOf(_ cs: CGColorSpace, _ stops: [(CGFloat, CGColor)]) -> CGGradient? {
    return CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })
}

/// Fills `path` with a vertical gradient (top ... bottom of `rect`), clipped to the path.
private func fillVertical(_ ctx: CGContext, _ cs: CGColorSpace, path: CGPath, rect: CGRect, stops: [(CGFloat, CGColor)]) {
    guard let g = gradientOf(cs, stops) else { return }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// A shape with a soft drop shadow under it (filled once with the shadow, then the caller paints the real fill on top).
private func shadowed(_ ctx: CGContext, path: CGPath, color: CGColor, dy: CGFloat, blur: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: color)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()
}

/// A pencil with its tip at `tip`; `angle` (radians) is the direction from the tip to the other end. `soft` = shadow, highlight, gradient; otherwise flat.
private func drawPencil(_ ctx: CGContext, _ cs: CGColorSpace, tip: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat, V: Variant, soft: Bool, shadow: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: tip.x, y: tip.y)
    ctx.rotate(by: angle)
    let half = width / 2
    let coneEnd = 0.21 * length, bodyEnd = 0.86 * length, ferruleEnd = 0.91 * length
    let cone = CGMutablePath()
    cone.move(to: .zero)
    cone.addLine(to: CGPoint(x: coneEnd, y: -half))
    cone.addLine(to: CGPoint(x: coneEnd, y: half))
    cone.closeSubpath()
    let bodyRect = CGRect(x: coneEnd, y: -half, width: bodyEnd - coneEnd, height: width)
    let ferruleRect = CGRect(x: bodyEnd, y: -half, width: ferruleEnd - bodyEnd, height: width)
    let eraserRect = CGRect(x: ferruleEnd, y: -half, width: length - ferruleEnd, height: width)
    let eraser = CGPath(roundedRect: eraserRect, cornerWidth: min(width * 0.35, eraserRect.width / 2), cornerHeight: min(width * 0.35, eraserRect.height / 2), transform: nil)
    if soft {
        let silhouette = CGMutablePath()
        silhouette.addPath(cone); silhouette.addRect(bodyRect); silhouette.addRect(ferruleRect); silhouette.addPath(eraser)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -width * 0.22), blur: width * 0.55, color: CGColor(srgbRed: 0.03, green: 0.02, blue: 0.2, alpha: shadow))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(silhouette)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.84, blue: 0.66, alpha: 1))        // the wood of the cone
    ctx.addPath(cone)
    ctx.fillPath()
    ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.20, blue: 0.27, alpha: 1))        // the graphite point
    let point = CGMutablePath()
    point.move(to: .zero)
    point.addLine(to: CGPoint(x: 0.075 * length, y: -half * 0.34))
    point.addLine(to: CGPoint(x: 0.075 * length, y: half * 0.34))
    point.closeSubpath()
    ctx.addPath(point)
    ctx.fillPath()
    if soft, let g = gradientOf(cs, V.penBody) {
        ctx.saveGState()
        ctx.clip(to: bodyRect)
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: half), end: CGPoint(x: 0, y: -half), options: [])
        ctx.restoreGState()
    } else {
        ctx.setFillColor(V.penBody[V.penBody.count / 2].1)
        ctx.fill(bodyRect)
    }
    ctx.setFillColor(CGColor(srgbRed: 0.80, green: 0.83, blue: 0.90, alpha: 1))        // the metal ring
    ctx.fill(ferruleRect)
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.42, blue: 0.50, alpha: 1))         // the eraser
    ctx.addPath(eraser)
    ctx.fillPath()
    if soft {                                                                           // a thin highlight along the lit side
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
        ctx.fill(CGRect(x: coneEnd + width * 0.1, y: half * 0.38, width: bodyEnd - coneEnd - width * 0.2, height: max(1, width * 0.10)))
    }
    ctx.restoreGState()
}

/// Centre and radius of the recording dot of D3 (the same as the former icon's; whole pixels at the compact sizes).
private func dotGeometry(L: Layout, body: CGRect) -> (c: CGPoint, r: CGFloat, rim: CGFloat) {
    let w = body.width
    var c = CGPoint(x: body.minX + L.dotCenter.x * w, y: body.minY + L.dotCenter.y * w)
    var r = L.dotRadius * w
    let rim = L.compact ? max(1, (L.dotRim * w).rounded()) : max(1, L.dotRim * w)
    if L.compact {
        r = max(1.5, (r * 2).rounded(.down) / 2)
        let off: CGFloat = Int(r * 2) % 2 == 0 ? 0 : 0.5
        c = CGPoint(x: (c.x - off).rounded() + off, y: (c.y - off).rounded() + off)
    }
    return (c, r, rim)
}

/// The soft red halo behind the page (drawn first, so that it does not tint the paper).
private func drawRecordingHalo(_ ctx: CGContext, _ cs: CGColorSpace, L: Layout, body: CGRect, shape: CGPath) {
    guard !L.compact else { return }
    let (c, r, _) = dotGeometry(L: L, body: body)
    guard let g = gradientOf(cs, [(0, rgb(0xFF3B30, 0.55)), (0.45, rgb(0xFF3B30, 0.18)), (1, rgb(0xFF3B30, 0))]) else { return }
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawRadialGradient(g, startCenter: c, startRadius: r * 0.6, endCenter: c, endRadius: r * 2.5, options: [])
    ctx.restoreGState()
}

/// The recording dot of D3: white rim, glossy red.
private func drawRecordingDot(_ ctx: CGContext, _ cs: CGColorSpace, L: Layout, body: CGRect, shape: CGPath) {
    let s = L.s
    let red = rgb(0xFF3B30)
    let (c, r, rim) = dotGeometry(L: L, body: body)
    func white(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
    ctx.saveGState()
    if !L.compact { ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.005), blur: s * 0.012, color: CGColor(srgbRed: 0.1, green: 0, blue: 0.1, alpha: 0.35)) }
    ctx.setFillColor(white(1))
    ctx.fillEllipse(in: CGRect(x: c.x - r - rim, y: c.y - r - rim, width: 2 * (r + rim), height: 2 * (r + rim)))
    ctx.restoreGState()
    let dot = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    ctx.setFillColor(red)
    ctx.fillEllipse(in: dot)
    if !L.compact {
        ctx.saveGState()
        ctx.addEllipse(in: dot)
        ctx.clip()
        if let g = gradientOf(cs, [(0, rgb(0xFF7B6E)), (0.5, rgb(0xFF3B30)), (1, rgb(0xD81C13))]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: c.y - r), options: [])
        }
        if let g = gradientOf(cs, [(0, white(0.55)), (1, white(0))]) {
            let hl = CGPoint(x: c.x - r * 0.28, y: c.y + r * 0.34)
            ctx.drawRadialGradient(g, startCenter: hl, startRadius: 0, endCenter: hl, endRadius: r * 0.55, options: [])
        }
        ctx.restoreGState()
    }
}

private func drawNotes(ctx: CGContext, cs: CGColorSpace, L: Layout, V: Variant, shape: CGPath, body: CGRect) {
    let s = L.s, w = body.width
    let soft = !L.compact
    func R(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat) -> CGRect {
        return CGRect(x: body.minX + u0 * w, y: body.minY + v0 * w, width: (u1 - u0) * w, height: (v1 - v0) * w)
    }
    func P(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: body.minX + u * w, y: body.minY + v * w) }
    /// Compact sizes: the rectangle snapped to whole pixels (at least `minSize` wide and high), so that every edge is crisp.
    func snapped(_ r: CGRect, minSize: CGFloat = 1) -> CGRect {
        let x0 = r.minX.rounded(), y0 = r.minY.rounded()
        return CGRect(x: x0, y: y0, width: max(minSize, r.maxX.rounded() - x0), height: max(minSize, r.maxY.rounded() - y0))
    }
    func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil) }
    let shadowColor = CGColor(srgbRed: 0.04, green: 0.03, blue: 0.18, alpha: 0.38)
    let paperStops: [(CGFloat, CGColor)] = [(0, V.paperTop), (1, V.paperBottom)]
    /// Compact sizes: `count` horizontal lines on the pixel grid inside `paper`, every second pixel row at 16 px (1 px lines), every fourth at 32 px (2 px lines);
    /// each is `shorten` pixel columns shorter than the one above.
    func compactLines(in paper: CGRect, count: Int, inset: CGFloat, shorten: CGFloat, color: CGColor) {
        let tiny = L.pixels <= 16
        let thickness: CGFloat = tiny ? 1 : 2, pitch: CGFloat = tiny ? 2 : 4
        let top = paper.maxY - inset - thickness
        ctx.setFillColor(color)
        for i in 0..<count {
            let y = top - CGFloat(i) * pitch
            if y < paper.minY + 1 { break }
            let right = paper.maxX - inset - CGFloat(i) * shorten
            ctx.fill(CGRect(x: paper.minX + inset, y: y, width: max(2, right - paper.minX - inset), height: thickness))
        }
    }
    func line(_ u0: CGFloat, _ u1: CGFloat, v: CGFloat, thickness: CGFloat, color: CGColor) {
        var rect = CGRect(x: body.minX + u0 * w, y: body.minY + v * w - thickness * w / 2, width: (u1 - u0) * w, height: thickness * w)
        if !soft { rect = snapped(rect, minSize: 1) }
        ctx.setFillColor(color)
        ctx.addPath(rr(rect, rect.height / 2))
        ctx.fillPath()
    }

    switch V.glyph {
    case .clipboard:
        if soft {
            let board = R(0.24, 0.13, 0.72, 0.80)
            let boardPath = rr(board, 0.07 * w)
            shadowed(ctx, path: boardPath, color: shadowColor, dy: s * 0.012, blur: s * 0.030)
            fillVertical(ctx, cs, path: boardPath, rect: board, stops: [(0, rgb(0xE6EEFF)), (1, rgb(0xB5C8F5))])
            let sheet = R(0.285, 0.175, 0.675, 0.725)
            let sheetPath = rr(sheet, 0.03 * w)
            shadowed(ctx, path: sheetPath, color: CGColor(srgbRed: 0.1, green: 0.12, blue: 0.4, alpha: 0.22), dy: s * 0.004, blur: s * 0.010)
            fillVertical(ctx, cs, path: sheetPath, rect: sheet, stops: paperStops)
            for (v, end) in [(0.62, 0.63), (0.52, 0.64), (0.42, 0.57), (0.32, 0.49)] as [(CGFloat, CGFloat)] { line(0.335, end, v: v, thickness: 0.030, color: V.ink) }
            let clipRect = R(0.395, 0.745, 0.565, 0.865)
            let clipPath = rr(clipRect, 0.035 * w)
            shadowed(ctx, path: clipPath, color: shadowColor, dy: s * 0.006, blur: s * 0.014)
            fillVertical(ctx, cs, path: clipPath, rect: clipRect, stops: V.clip)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
            let hole = 0.02 * w
            ctx.fillEllipse(in: CGRect(x: clipRect.midX - hole, y: clipRect.midY - hole, width: 2 * hole, height: 2 * hole))
            drawPencil(ctx, cs, tip: P(0.50, 0.185), angle: .pi / 4, length: 0.42 * w, width: 0.088 * w, V: V, soft: true, shadow: V.shadow)
        } else {
            let paper = snapped(R(0.22, 0.12, 0.70, 0.88), minSize: 4)
            ctx.setFillColor(V.paperTop)
            ctx.addPath(rr(paper, max(1, (0.06 * w).rounded())))
            ctx.fillPath()
            compactLines(in: paper, count: 3, inset: L.pixels <= 16 ? 2 : 4, shorten: 0, color: V.ink)
            drawPencil(ctx, cs, tip: P(0.50, 0.14), angle: .pi / 4, length: 0.50 * w, width: max(3, (0.15 * w).rounded()), V: V, soft: false, shadow: 0)
        }

    case .bubble:
        if soft {
            let rect = R(0.17, 0.32, 0.79, 0.80)
            let outline = CGMutablePath()
            outline.addPath(rr(rect, 0.14 * w))
            outline.move(to: P(0.25, 0.345))
            outline.addLine(to: P(0.215, 0.17))
            outline.addLine(to: P(0.44, 0.345))
            outline.closeSubpath()
            shadowed(ctx, path: outline, color: shadowColor, dy: s * 0.012, blur: s * 0.030)
            fillVertical(ctx, cs, path: outline, rect: CGRect(x: rect.minX, y: body.minY + 0.17 * w, width: rect.width, height: rect.maxY - body.minY - 0.17 * w), stops: paperStops)
            for (v, end) in [(0.675, 0.69), (0.575, 0.65), (0.475, 0.52)] as [(CGFloat, CGFloat)] { line(0.265, end, v: v, thickness: 0.032, color: V.ink) }
            drawPencil(ctx, cs, tip: P(0.55, 0.235), angle: .pi / 4, length: 0.36 * w, width: 0.078 * w, V: V, soft: true, shadow: V.shadow)
        } else {
            let rect = snapped(R(0.14, 0.34, 0.84, 0.88), minSize: 4)
            let outline = CGMutablePath()
            outline.addPath(rr(rect, max(1.5, (0.14 * w).rounded())))
            outline.move(to: CGPoint(x: rect.minX + 1.5, y: rect.minY + 1))
            outline.addLine(to: CGPoint(x: rect.minX + 0.5, y: rect.minY - max(2, (0.14 * w).rounded())))
            outline.addLine(to: CGPoint(x: rect.minX + max(4, 0.34 * w), y: rect.minY + 1))
            outline.closeSubpath()
            ctx.setFillColor(V.paperTop)
            ctx.addPath(outline)
            ctx.fillPath()
            compactLines(in: rect, count: 2, inset: L.pixels <= 16 ? 2 : 4, shorten: L.pixels <= 16 ? 2 : 4, color: V.ink)
            drawPencil(ctx, cs, tip: P(0.50, 0.16), angle: .pi / 4, length: 0.42 * w, width: max(3, (0.14 * w).rounded()), V: V, soft: false, shadow: 0)
        }

    case .notebook:
        drawRecordingHalo(ctx, cs, L: L, body: body, shape: shape)
        if soft {
            let page = R(0.25, 0.13, 0.73, 0.80)
            let pagePath = rr(page, 0.05 * w)
            shadowed(ctx, path: pagePath, color: shadowColor, dy: s * 0.012, blur: s * 0.030)
            fillVertical(ctx, cs, path: pagePath, rect: page, stops: paperStops)
            for i in 0..<5 { line(0.31, 0.69, v: 0.63 - CGFloat(i) * 0.10, thickness: 0.008, color: rgb(0xB9C8F2)) }       // the ruled lines
            let scribble = CGMutablePath()
            /// Cursive-looking loops: a prolate cycloid (x = c*t - r*sin t, y = r*cos t) along a line.
            func loops(_ u0: CGFloat, _ span: CGFloat, _ y0: CGFloat, _ turns: CGFloat, radius: CGFloat) {
                let n = Int(turns * 36)
                let c = span / (2 * .pi * turns)
                for i in 0...n {
                    let t = 2 * .pi * turns * CGFloat(i) / CGFloat(n)
                    let p = P(u0 + c * t - radius * 0.62 * sin(t), y0 + radius * cos(t) * (0.80 + 0.20 * sin(t * 0.37)))
                    if i == 0 { scribble.move(to: p) } else { scribble.addLine(to: p) }
                }
            }
            loops(0.335, 0.31, 0.575, 4, radius: 0.027)
            loops(0.335, 0.20, 0.425, 3, radius: 0.027)
            ctx.saveGState()
            ctx.setStrokeColor(V.ink)
            ctx.setLineWidth(0.021 * w)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(scribble)
            ctx.strokePath()
            ctx.restoreGState()
            for i in 0..<5 {                                                          // the spiral binding: rings through the left edge
                let v = 0.65 - CGFloat(i) * 0.115
                let ring = R(0.205, v - 0.017, 0.30, v + 0.017)
                shadowed(ctx, path: rr(ring, ring.height / 2), color: shadowColor, dy: s * 0.003, blur: s * 0.006)
                fillVertical(ctx, cs, path: rr(ring, ring.height / 2), rect: ring, stops: V.clip)
            }
        } else {
            let page = snapped(R(0.20, 0.12, 0.72, 0.84), minSize: 4)
            ctx.setFillColor(V.paperTop)
            ctx.addPath(rr(page, max(1, (0.06 * w).rounded())))
            ctx.fillPath()
            if L.pixels <= 16 {                                                       // 16 px: two short pixel lines say "written" and keep the dot clear
                compactLines(in: page, count: 2, inset: 2, shorten: 1, color: V.ink)
                drawRecordingDot(ctx, cs, L: L, body: body, shape: shape)
                return
            }
            // a zigzag scribble, two pixels thick at 32 px
            let zig = CGMutablePath()
            let x0 = page.minX + max(2, 0.08 * w), x1 = page.maxX - max(2, 0.08 * w)
            zig.move(to: CGPoint(x: x0, y: page.minY + page.height * 0.28))
            let steps = 4
            for i in 1...steps {
                let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(steps)
                zig.addLine(to: CGPoint(x: x, y: page.minY + page.height * (i % 2 == 1 ? 0.62 : 0.30)))
            }
            ctx.saveGState()
            ctx.setStrokeColor(V.ink)
            ctx.setLineWidth(max(1.5, (0.075 * w).rounded()))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(zig)
            ctx.strokePath()
            ctx.restoreGState()
        }
        drawRecordingDot(ctx, cs, L: L, body: body, shape: shape)

    case .waveform:
        break
    }
}

// MARK: - Main

private let usage = "usage: make_icon [<output.icns>] [--variant D1|D2|D3|A|B|C] [--keep-iconset DIR] [--png FILE [--size N]]   (an .icns or a --png is required)"

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("make_icon: \(message)\n".utf8))
    exit(code)
}

private let iconsetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

private func main() {
    var output: String?
    var keepDir: String?
    var pngPath: String?
    var pngSize = 512
    var variantName = "D1"
    var args = Array(CommandLine.arguments.dropFirst())
    func value(of option: String) -> String {
        guard !args.isEmpty else { fail("\(option) needs a value\n\(usage)", code: 2) }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--keep-iconset": keepDir = value(of: a)
        case "--png": pngPath = value(of: a)
        case "--variant": variantName = value(of: a).uppercased()
        case "--size":
            guard let n = Int(value(of: a)), (16...2048).contains(n) else { fail("--size must be a whole number from 16 to 2048", code: 2) }
            pngSize = n
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)\n\(usage)", code: 2) }
            guard output == nil else { fail("only one output path is accepted\n\(usage)", code: 2) }
            output = a
        }
    }
    guard let variant = variants[variantName] else { fail("--variant must be D1, D2, D3, A, B or C\n\(usage)", code: 2) }
    if let out = output, !out.hasSuffix(".icns") { fail(usage, code: 2) }
    if output == nil && pngPath == nil { fail(usage, code: 2) }
    if keepDir != nil && output == nil { fail("--keep-iconset needs an .icns output\n\(usage)", code: 2) }

    let fm = FileManager.default
    if let path = pngPath {
        guard let image = render(pixels: pngSize, variant: variant), let data = pngData(image) else { fail("cannot render \(pngSize) px") }
        let url = URL(fileURLWithPath: path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: url) } catch { fail("cannot write \(path): \(error)") }
        print("wrote \(url.path) (variant \(variant.name), \(pngSize) px, \(data.count) bytes)")
    }
    guard let out = output else { return }

    let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("mcap-make-icon-\(getpid())", isDirectory: true)
    let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try? fm.removeItem(at: work)
    do { try fm.createDirectory(at: iconset, withIntermediateDirectories: true) } catch { fail("cannot create \(iconset.path): \(error)") }
    defer { try? fm.removeItem(at: work) }

    var cache: [Int: Data] = [:]
    for entry in iconsetEntries {
        if cache[entry.pixels] == nil {
            guard let image = render(pixels: entry.pixels, variant: variant), let data = pngData(image) else { fail("cannot render \(entry.pixels) px") }
            cache[entry.pixels] = data
        }
        do { try cache[entry.pixels]!.write(to: iconset.appendingPathComponent(entry.name)) } catch { fail("cannot write \(entry.name): \(error)") }
    }

    let outURL = URL(fileURLWithPath: out)
    try? fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tool = Process()
    tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    tool.arguments = ["-c", "icns", "-o", outURL.path, iconset.path]
    do { try tool.run() } catch { fail("cannot run /usr/bin/iconutil: \(error)") }
    tool.waitUntilExit()
    guard tool.terminationStatus == 0 else { fail("iconutil failed with status \(tool.terminationStatus)") }

    if let keep = keepDir {
        let dest = URL(fileURLWithPath: keep, isDirectory: true)
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: iconset, to: dest) } catch { fail("cannot keep the iconset in \(keep): \(error)") }
    }
    let size = (try? fm.attributesOfItem(atPath: outURL.path))?[.size] as? NSNumber
    print("wrote \(outURL.path) (variant \(variant.name), \(size?.intValue ?? 0) bytes, \(iconsetEntries.count) images)")
}

main()
