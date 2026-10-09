import SwiftUI

/// Ember's identity: a thermal print head heating up — ink-dark surfaces, amber → ember → magenta heat,
/// and halftone dots everywhere a plain rectangle would have been.
enum Brand {
  static let ink = Color(red: 0.050, green: 0.035, blue: 0.070)
  static let ink2 = Color(red: 0.085, green: 0.060, blue: 0.110)
  static let amber = Color(red: 1.00, green: 0.74, blue: 0.27)
  static let ember = Color(red: 1.00, green: 0.36, blue: 0.20)
  static let magenta = Color(red: 0.86, green: 0.17, blue: 0.47)
  static let violet = Color(red: 0.43, green: 0.22, blue: 0.78)
  static let paper = Color(red: 0.965, green: 0.945, blue: 0.905)
  static let mute = Color.white.opacity(0.52)

  static let heat = LinearGradient(colors: [amber, ember, magenta], startPoint: .leading, endPoint: .trailing)
  static let heatDiagonal = LinearGradient(colors: [amber, ember, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)

  static func heat(at t: Double) -> Color {
    let stops: [(Double, (Double, Double, Double))] = [(0, (1.00, 0.74, 0.27)), (0.5, (1.00, 0.36, 0.20)), (1, (0.86, 0.17, 0.47))]
    let t = min(max(t, 0), 1)
    let (a, b) = t < 0.5 ? (stops[0], stops[1]) : (stops[1], stops[2])
    let u = (t - a.0) / (b.0 - a.0)
    return Color(red: a.1.0 + (b.1.0 - a.1.0) * u, green: a.1.1 + (b.1.1 - a.1.1) * u, blue: a.1.2 + (b.1.2 - a.1.2) * u)
  }

  static let wordmark = Font.system(size: 30, weight: .black, design: .rounded)
  static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
  static let sectionTitle = Font.system(size: 11, weight: .bold, design: .monospaced)
}

/// The mark: a flame built from halftone dots, large and hot in the middle, tiny at the edges —
/// the same dots a thermal head burns onto a label.
enum Flame {
  struct Dot { let x: Double, y: Double, r: Double, heat: Double }  // x,y in 0…1, y up; r as fraction of the cell

  static func dots(cols: Int = 13, rows: Int = 17) -> [Dot] {
    var out: [Dot] = []
    for row in 0..<rows {
      let y = (Double(row) + 0.5) / Double(rows)
      let (cx, hw) = outline(y)
      guard hw > 0.015 else { continue }
      for col in 0..<cols {
        let x = (Double(col) + 0.5) / Double(cols)
        let d = abs(x - cx) / hw
        guard d < 1 else { continue }
        let r = (1 - d * d * 0.85) * (0.64 - 0.14 * y)
        if r > 0.09 { out.append(Dot(x: x, y: y, r: r, heat: y)) }
      }
    }
    return out
  }

  /// Teardrop: round belly low down, tip that leans right. Returns (centre x, half-width) at height y.
  static func outline(_ y: Double) -> (Double, Double) {
    let belly = 0.30
    if y < belly {
      let u = (y - belly) / belly
      return (0.5, 0.45 * (1 - u * u).squareRoot())
    }
    let u = (y - belly) / (1 - belly)
    return (0.5 + 0.20 * pow(u, 1.7), 0.45 * pow(1 - u, 1.35))
  }
}

struct FlameMark: View {
  var body: some View {
    Canvas { ctx, size in
      let cols = 13, rows = 17
      let cell = min(size.width / Double(cols), size.height / Double(rows))
      let w = cell * Double(cols), h = cell * Double(rows)
      let ox = (size.width - w) / 2, oy = (size.height - h) / 2
      for d in Flame.dots(cols: cols, rows: rows) {
        let rad = d.r * cell
        let rect = CGRect(x: ox + d.x * w - rad, y: oy + (1 - d.y) * h - rad, width: rad * 2, height: rad * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(Brand.heat(at: d.heat)))
      }
    }
  }
}

/// App icon-ish tile for the header.
struct LogoTile: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.07, blue: 0.19), Brand.ink], startPoint: .top, endPoint: .bottom))
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .strokeBorder(Brand.heatDiagonal.opacity(0.55), lineWidth: 1)
      FlameMark().padding(8)
    }
    .frame(width: 44, height: 44)
    .shadow(color: Brand.ember.opacity(0.35), radius: 10, y: 2)
  }
}

/// Page backdrop: ink with a slow ember glow bleeding up from the bottom and a faint print-head dot grid.
struct Backdrop: View {
  var body: some View {
    ZStack {
      Brand.ink
      RadialGradient(colors: [Brand.ember.opacity(0.20), Brand.magenta.opacity(0.08), .clear],
                     center: .bottomTrailing, startRadius: 20, endRadius: 760)
      RadialGradient(colors: [Brand.violet.opacity(0.16), .clear], center: .topLeading, startRadius: 10, endRadius: 520)
      Canvas { ctx, size in
        let step = 18.0
        for x in stride(from: step / 2, to: size.width, by: step) {
          for y in stride(from: step / 2, to: size.height, by: step) {
            ctx.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(.white.opacity(0.035)))
          }
        }
      }
    }
    .ignoresSafeArea()
  }
}

struct Card<Content: View>: View {
  let title: String
  var symbol: String?
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 7) {
        Circle().fill(Brand.heat).frame(width: 6, height: 6)
        Text(title.uppercased()).font(Brand.sectionTitle).tracking(1.6).foregroundStyle(Brand.mute)
        Spacer()
        if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Brand.mute) }
      }
      content
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.045))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    )
  }
}

struct HeatButtonStyle: ButtonStyle {
  var prominent = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold, design: .rounded))
      .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white)
      .padding(.horizontal, 14).padding(.vertical, 8)
      .background(
        Capsule().fill(prominent ? AnyShapeStyle(Brand.heat) : AnyShapeStyle(Color.white.opacity(0.09)))
          .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : 0.10), lineWidth: 1))
      )
      .shadow(color: prominent ? Brand.ember.opacity(0.45) : .clear, radius: 10, y: 2)
      .opacity(configuration.isPressed ? 0.75 : 1)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

/// Segmented control with a heat-filled selection.
struct HeatPicker: View {
  let items: [(value: String, label: String)]
  @Binding var selection: String

  var body: some View {
    HStack(spacing: 3) {
      ForEach(items, id: \.value) { item in
        let on = item.value == selection
        Button { withAnimation(.snappy(duration: 0.18)) { selection = item.value } } label: {
          Text(item.label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(on ? Color.black.opacity(0.85) : .white.opacity(0.75))
            .frame(maxWidth: .infinity).padding(.vertical, 6).padding(.horizontal, 6)
            .background(Capsule().fill(on ? AnyShapeStyle(Brand.heat) : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
    .background(Capsule().fill(Color.black.opacity(0.32)).overlay(Capsule().strokeBorder(.white.opacity(0.08))))
  }
}
