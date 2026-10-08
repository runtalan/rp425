import CoreGraphics; import Foundation; import CoreText
var box = CGRect(x: 0, y: 0, width: 288, height: 432)
let ctx = CGContext(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
ctx.setLineWidth(2); ctx.stroke(box.insetBy(dx: 6, dy: 6))
func text(_ s: String, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat) {
  let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.init(kCTFontAttributeName as String): font]))
  ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
}
text("cinemoo", 40, 18, 380)
text("RP425 driver test - 4x6 in, 203 dpi", 12, 18, 355)
for i in 0..<60 where i % 3 != 1 { ctx.fill(CGRect(x: 18 + CGFloat(i) * 4, y: 270, width: CGFloat(1 + i % 3), height: 70)) }
let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray, locations: nil)!
ctx.saveGState(); ctx.clip(to: CGRect(x: 18, y: 200, width: 252, height: 55))
ctx.drawLinearGradient(g, start: CGPoint(x: 18, y: 0), end: CGPoint(x: 270, y: 0), options: []); ctx.restoreGState()
ctx.fillEllipse(in: CGRect(x: 100, y: 60, width: 90, height: 90))
text("The quick brown fox jumps over the lazy dog 0123456789", 7, 18, 30)
ctx.endPDFPage(); ctx.closePDF()
