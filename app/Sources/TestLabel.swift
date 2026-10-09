import CoreGraphics
import CoreText
import Foundation

/// A calibration label: edge ruler in millimetres (to dial in the offsets), a flame, text, barcode-ish bars
/// and a gray ramp (to judge darkness and dithering). Everything is black on white — it's a print test.
enum TestLabel {
  static func write(to url: URL, width: Double, height: Double, size: String, settings: [String: String]) {
    var box = CGRect(x: 0, y: 0, width: width, height: height)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(box)
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.setStrokeColor(gray: 0, alpha: 1)

    let mm = 72 / 25.4
    // Outer frame and millimetre rulers along the left and top edges.
    ctx.setLineWidth(1.5)
    ctx.stroke(box.insetBy(dx: 5, dy: 5))
    ctx.setLineWidth(0.5)
    var i = 0
    while Double(i) * mm < min(height - 24, 120 * mm) {
      let tick = i % 10 == 0 ? 12.0 : (i % 5 == 0 ? 8.0 : 4.0)
      let y = height - 10 - Double(i) * mm
      ctx.move(to: CGPoint(x: 5, y: y)); ctx.addLine(to: CGPoint(x: 5 + tick, y: y)); ctx.strokePath()
      i += 1
    }
    i = 0
    while Double(i) * mm < width - 24 {
      let tick = i % 10 == 0 ? 12.0 : (i % 5 == 0 ? 8.0 : 4.0)
      let x = 10 + Double(i) * mm
      ctx.move(to: CGPoint(x: x, y: height - 5)); ctx.addLine(to: CGPoint(x: x, y: height - 5 - tick)); ctx.strokePath()
      i += 1
    }

    let compact = height < 150
    let mark = compact ? 34.0 : 64.0
    let left = 22.0
    var top = height - 22

    // Flame mark
    for d in Flame.dots() {
      let cell = mark / 17
      let r = d.r * cell
      ctx.fillEllipse(in: CGRect(x: left + d.x * 13 * cell - r, y: top - mark + d.y * 17 * cell - r, width: r * 2, height: r * 2))
    }
    text(ctx, "EMBER", compact ? 20 : 34, left + mark + 8, top - mark * 0.48, weight: "Helvetica-Bold")
    text(ctx, "RP425 test label", compact ? 8 : 11, left + mark + 9, top - mark * 0.48 - (compact ? 11 : 16))
    top -= mark + 12

    let summary = ["PageSize": size, "Darkness": settings["Darkness"], "PrintSpeed": settings["PrintSpeed"],
                   "Dither": settings["Dither"], "Threshold": settings["Threshold"]]
      .compactMap { k, v in v.map { "\(k) \($0)" } }.sorted()
    if !compact {
      for line in summary.prefix(5) {
        text(ctx, line, 8, left, top - 8, font: "Menlo")
        top -= 11
      }
      top -= 8
      // Bars
      let bars = min(60, Int((width - left * 2) / 4))
      for n in 0..<bars where n % 3 != 1 {
        ctx.fill(CGRect(x: left + Double(n) * 4, y: top - 54, width: Double(1 + n % 3), height: 54))
      }
      top -= 66
      // Gray ramp — 16 steps, the quickest way to see darkness and threshold at work
      let steps = 16, rampW = width - left * 2
      for s in 0..<steps {
        ctx.setFillColor(gray: 1 - CGFloat(s) / CGFloat(steps - 1), alpha: 1)
        ctx.fill(CGRect(x: left + rampW * Double(s) / Double(steps), y: top - 30, width: rampW / Double(steps) + 0.5, height: 30))
      }
      ctx.setFillColor(gray: 0, alpha: 1)
      ctx.stroke(CGRect(x: left, y: top - 30, width: rampW, height: 30))
      top -= 44
      // Gradient dot field
      let remaining = top - 24
      if remaining > 40 {
        let cell = 6.0, cols = Int(rampW / cell), rows = Int(min(remaining, 150) / cell)
        for cy in 0..<rows { for cx in 0..<cols {
          let dx = Double(cx) / Double(cols) - 0.5, dy = Double(cy) / Double(rows) - 0.5
          let r = max(0, 1 - sqrt(dx * dx + dy * dy) * 2) * cell * 0.5
          ctx.fillEllipse(in: CGRect(x: left + Double(cx) * cell + cell / 2 - r, y: top - Double(cy + 1) * cell + cell / 2 - r, width: r * 2, height: r * 2))
        } }
      }
    } else {
      text(ctx, summary.prefix(2).joined(separator: " · "), 7, left, top - 6, font: "Menlo")
    }
    ctx.endPDFPage()
    ctx.closePDF()
  }

  private static func text(_ ctx: CGContext, _ s: String, _ size: Double, _ x: Double, _ y: Double,
                           font: String = "Helvetica", weight: String? = nil) {
    let f = CTFontCreateWithName((weight ?? font) as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.init(kCTFontAttributeName as String): f]))
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
  }
}
