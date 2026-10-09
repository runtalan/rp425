import SwiftUI

/// What the preview needs to know; derived from the current (unsaved) settings.
struct PreviewSpec {
  var widthPt: Double
  var heightPt: Double
  var darkness: Double?      // 0…30, nil = printer's own setting
  var threshold: Double      // 64…192
  var dithered: Bool
  var rotated: Bool
  var topDots: Double
  var leftDots: Double
  var tracking: String       // Default / Gap / Mark / Continuous
  var speed: String

  @MainActor init(_ s: Store) {
    let size = pageSizePoints(s.value("PageSize")) ?? (288, 432)
    widthPt = size.w
    heightPt = size.h
    darkness = Double(s.value("Darkness"))
    threshold = Double(s.value("Threshold")) ?? 128
    dithered = s.value("Dither") == "FloydSteinberg"
    rotated = s.value("Rotate180") == "True"
    topDots = Double(s.value("TopOffset")) ?? 0
    leftDots = Double(s.value("LeftOffset")) ?? 0
    tracking = s.value("MediaTracking")
    speed = s.value("PrintSpeed")
  }
}

/// A label on the roll, drawn to scale, printed the way the settings say it will come out:
/// ink tone follows darkness, the halftone block switches between hard threshold and ordered dither,
/// offsets shift the artwork in real millimetres, and 180° rotation flips it.
struct LabelPreview: View {
  let spec: PreviewSpec
  private static let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

  var body: some View {
    Canvas { ctx, size in
      let margin = 46.0
      let avail = CGSize(width: size.width - margin * 2, height: size.height - margin * 2)
      let s = min(avail.width / spec.widthPt, avail.height / spec.heightPt)
      let w = spec.widthPt * s, h = spec.heightPt * s
      let label = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
      let corner = min(w, h) * 0.045
      let gap = max(10, h * 0.05)

      drawLiner(&ctx, label: label, gap: gap, size: size)

      // Paper
      let paperPath = Path(roundedRect: label, cornerRadius: corner, style: .continuous)
      ctx.drawLayer { l in
        l.addFilter(.shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 8))
        l.fill(paperPath, with: .color(Brand.paper))
      }
      ctx.fill(paperPath, with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .clear]),
                                                startPoint: CGPoint(x: label.minX, y: label.minY), endPoint: CGPoint(x: label.maxX, y: label.maxY)))

      // Artwork, clipped to the paper
      ctx.drawLayer { l in
        l.clip(to: paperPath)
        let mmPx = s * 72 / 25.4
        let dotToMM = 1.0 / 8.0
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: spec.leftDots * dotToMM * mmPx, y: spec.topDots * dotToMM * mmPx)
        if spec.rotated {
          t = t.translatedBy(x: label.midX, y: label.midY).rotated(by: .pi).translatedBy(x: -label.midX, y: -label.midY)
        }
        l.concatenate(t)
        drawArtwork(&l, in: label, scale: s)
      }

      // Nominal artwork margin guide, so offsets read against a fixed reference
      ctx.stroke(Path(roundedRect: label.insetBy(dx: w * 0.06, dy: w * 0.06), cornerRadius: 3),
                 with: .color(Brand.ember.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

      // Feed direction
      let ax = label.maxX + 22
      var arrow = Path()
      arrow.move(to: CGPoint(x: ax, y: label.midY - 22)); arrow.addLine(to: CGPoint(x: ax, y: label.midY + 22))
      arrow.move(to: CGPoint(x: ax - 5, y: label.midY + 16)); arrow.addLine(to: CGPoint(x: ax, y: label.midY + 22)); arrow.addLine(to: CGPoint(x: ax + 5, y: label.midY + 16))
      ctx.stroke(arrow, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
    .animation(.smooth(duration: 0.35), value: spec.widthPt)
  }

  private func ink(_ boost: Double = 1) -> Color {
    let d = (spec.darkness ?? 18) / 30                      // 0…1
    let g = 0.62 - 0.57 * d                                  // light gray → near-black
    return Color(white: max(0.03, g), opacity: min(1, (0.78 + 0.22 * d) * boost))
  }

  private func drawLiner(_ ctx: inout GraphicsContext, label: CGRect, gap: Double, size: CGSize) {
    let liner = CGRect(x: label.minX - 14, y: 0, width: label.width + 28, height: size.height)
    switch spec.tracking {
    case "Continuous":
      ctx.fill(Path(liner), with: .color(.white.opacity(0.03)))
      var tear = Path()
      tear.move(to: CGPoint(x: liner.minX, y: label.maxY + gap / 2)); tear.addLine(to: CGPoint(x: liner.maxX, y: label.maxY + gap / 2))
      ctx.stroke(tear, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
    default:
      ctx.fill(Path(liner), with: .color(.white.opacity(0.05)))
      // the next label peeking in below the gap
      let next = CGRect(x: label.minX, y: label.maxY + gap, width: label.width, height: size.height)
      ctx.fill(Path(roundedRect: next, cornerRadius: 8, style: .continuous), with: .color(Brand.paper.opacity(0.14)))
      if spec.tracking == "Mark" {
        ctx.fill(Path(CGRect(x: liner.maxX - 10, y: label.maxY + gap * 0.25, width: 10, height: gap * 0.5)), with: .color(.black.opacity(0.9)))
      }
    }
    // sprocket-free roll edge hints
    for x in [liner.minX, liner.maxX] {
      var edge = Path(); edge.move(to: CGPoint(x: x, y: 0)); edge.addLine(to: CGPoint(x: x, y: size.height))
      ctx.stroke(edge, with: .color(.white.opacity(0.07)), lineWidth: 1)
    }
  }

  private func drawArtwork(_ ctx: inout GraphicsContext, in label: CGRect, scale s: Double) {
    let pad = label.width * 0.06
    let box = label.insetBy(dx: pad, dy: pad)
    let compact = box.height < box.width * 0.55
    let ink = ink()

    // Flame mark + wordmark
    let markH = compact ? box.height * 0.62 : min(box.height * 0.2, box.width * 0.30)
    let markW = markH * 0.82
    let cell = markH / 17
    for d in Flame.dots() {
      let r = d.r * cell
      let x = box.minX + d.x * 13 * cell, y = box.minY + (1 - d.y) * 17 * cell
      ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(ink))
    }
    let titleSize = markH * 0.52
    ctx.draw(Text("EMBER").font(.system(size: titleSize, weight: .black, design: .rounded)).foregroundColor(ink),
             at: CGPoint(x: box.minX + markW + markH * 0.2, y: box.minY + markH * 0.34), anchor: .leading)
    ctx.draw(Text("RP425 · thermal").font(.system(size: max(7, titleSize * 0.3), weight: .medium, design: .monospaced)).foregroundColor(ink.opacity(0.85)),
             at: CGPoint(x: box.minX + markW + markH * 0.22, y: box.minY + markH * 0.72), anchor: .leading)

    var y = box.minY + markH + box.height * 0.04

    // text rules
    if !compact {
      for (i, f) in [0.92, 0.7, 0.82].enumerated() {
        let rect = CGRect(x: box.minX, y: y + Double(i) * box.height * 0.032, width: box.width * f, height: max(2, box.height * 0.012))
        ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(ink))
      }
      y += box.height * 0.11
    }

    // barcode
    let barH = compact ? box.height * 0.28 : box.height * 0.14
    let barY = compact ? box.maxY - barH : y
    let barW = compact ? box.width : box.width
    var x = box.minX
    var n = 0
    while x < box.minX + barW {
      let wbar = max(1, s * (n % 3 == 0 ? 1.7 : (n % 3 == 1 ? 0.9 : 1.3)))
      if n % 2 == 0 { ctx.fill(Path(CGRect(x: x, y: barY, width: wbar, height: barH)), with: .color(ink)) }
      x += wbar; n += 1
    }
    y = barY + barH + box.height * 0.04

    // halftone / threshold photo block
    if !compact {
      let block = CGRect(x: box.minX, y: y, width: box.width, height: max(0, box.maxY - y))
      if block.height > 24 { drawPhoto(&ctx, in: block, ink: ink, scale: s) }
    }
  }

  private func drawPhoto(_ ctx: inout GraphicsContext, in block: CGRect, ink: Color, scale s: Double) {
    let cell = max(2.2, min(4.5, s * 1.9))
    let cols = Int(block.width / cell), rows = Int(block.height / cell)
    let thr = spec.threshold / 255
    ctx.stroke(Path(roundedRect: block, cornerRadius: 4), with: .color(ink.opacity(0.5)), lineWidth: 1)
    for cy in 0..<rows {
      for cx in 0..<cols {
        let u = Double(cx) / Double(max(cols - 1, 1)), v = Double(cy) / Double(max(rows - 1, 1))
        // a soft "sunrise": bright disc over a left→right ramp
        let ramp = 0.06 + 0.5 * u
        let dx = u - 0.68, dy = (v - 0.45) * Double(rows) / Double(max(cols, 1)) * 1.6
        let sun = max(0, 1 - sqrt(dx * dx + dy * dy) * 3.2)
        let lum = min(1, ramp + sun * 0.9)                 // 0 black … 1 white
        let on: Bool
        if spec.dithered {
          on = lum < (LabelPreview.bayer[cy % 4][cx % 4] + 0.5) / 16
        } else {
          on = lum < thr
        }
        if on {
          let r = cell * 0.46
          ctx.fill(Path(ellipseIn: CGRect(x: block.minX + Double(cx) * cell + cell / 2 - r, y: block.minY + Double(cy) * cell + cell / 2 - r, width: r * 2, height: r * 2)), with: .color(ink))
        }
      }
    }
  }
}
