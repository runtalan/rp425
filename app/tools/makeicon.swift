// Draws Ember's app icon (halftone flame on an ink tile with an ember glow) and writes an .icns.
//   swiftc -o build/makeicon app/tools/makeicon.swift && build/makeicon build/Ember.icns
import AppKit

func outline(_ y: Double) -> (Double, Double) {   // same teardrop as Flame.outline in Brand.swift
  let belly = 0.30
  if y < belly { let u = (y - belly) / belly; return (0.5, 0.45 * (1 - u * u).squareRoot()) }
  let u = (y - belly) / (1 - belly)
  return (0.5 + 0.20 * pow(u, 1.7), 0.45 * pow(1 - u, 1.35))
}
func heat(_ t: Double) -> NSColor {
  let a: [(Double, Double, Double)] = [(1.00, 0.74, 0.27), (1.00, 0.36, 0.20), (0.86, 0.17, 0.47)]
  let t = min(max(t, 0), 1), (p, q) = t < 0.5 ? (a[0], a[1]) : (a[1], a[2]), u = (t < 0.5 ? t : t - 0.5) / 0.5
  return NSColor(red: p.0 + (q.0 - p.0) * u, green: p.1 + (q.1 - p.1) * u, blue: p.2 + (q.2 - p.2) * u, alpha: 1)
}

func render(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let S = Double(px), inset = S * 0.055, tile = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
  let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
  NSGraphicsContext.current!.cgContext.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: NSColor.black.withAlphaComponent(0.5).cgColor)
  NSColor(red: 0.05, green: 0.035, blue: 0.07, alpha: 1).setFill(); path.fill()
  NSGraphicsContext.current!.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
  path.addClip()
  NSGradient(colors: [NSColor(red: 0.16, green: 0.08, blue: 0.22, alpha: 1), NSColor(red: 0.05, green: 0.035, blue: 0.07, alpha: 1)])!.draw(in: tile, angle: -90)
  NSGradient(colors: [NSColor(red: 1, green: 0.36, blue: 0.2, alpha: 0.55), NSColor(red: 0.86, green: 0.17, blue: 0.47, alpha: 0.18), .clear])!
    .draw(fromCenter: NSPoint(x: S * 0.5, y: S * 0.2), radius: 0, toCenter: NSPoint(x: S * 0.5, y: S * 0.2), radius: S * 0.62, options: [])
  // faint print-head dot grid
  let step = S / 28
  NSColor.white.withAlphaComponent(0.05).setFill()
  for gx in 0..<28 { for gy in 0..<28 { let r = S * 0.0035
    NSBezierPath(ovalIn: NSRect(x: (Double(gx) + 0.5) * step - r, y: (Double(gy) + 0.5) * step - r, width: r * 2, height: r * 2)).fill() } }
  // flame
  let cols = 15, rows = 19, h = S * 0.62, cell = h / Double(rows), w = cell * Double(cols)
  let ox = (S - w) / 2, oy = S * 0.19
  for row in 0..<rows {
    let y = (Double(row) + 0.5) / Double(rows), (cx, hw) = outline(y)
    guard hw > 0.015 else { continue }
    for col in 0..<cols {
      let x = (Double(col) + 0.5) / Double(cols), d = abs(x - cx) / hw
      guard d < 1 else { continue }
      let r = (1 - d * d * 0.85) * (0.64 - 0.14 * y) * cell
      guard r > 0.09 * cell else { continue }
      heat(y).setFill()
      NSBezierPath(ovalIn: NSRect(x: ox + x * w - r, y: oy + y * h - r, width: r * 2, height: r * 2)).fill()
    }
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
let set = (out as NSString).deletingPathExtension + ".iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
  try! render(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set, "-o", out]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
