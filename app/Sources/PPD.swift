import Foundation

struct PPDChoice: Hashable {
  let value: String
  let label: String
}

struct PPDOption: Identifiable {
  let key: String
  let label: String
  let isBoolean: Bool
  var choices: [PPDChoice]
  var def: String
  var id: String { key }
}

/// Reads the option list out of the queue's PPD so the app can't drift from the driver.
enum PPD {
  static let hidden: Set<String> = ["ColorModel", "Resolution"]  // single-choice, nothing to change

  static func load(queue: String) -> [PPDOption] {
    let candidates = ["/etc/cups/ppd/\(queue).ppd", Bundle.main.path(forResource: "RP425", ofType: "ppd")]
    for path in candidates.compactMap({ $0 }) {
      if let data = FileManager.default.contents(atPath: path) {
        let opts = parse(String(decoding: data, as: UTF8.self))
        if !opts.isEmpty { return opts }
      }
    }
    return []
  }

  static func parse(_ text: String) -> [PPDOption] {
    var options: [PPDOption] = []
    var defaults: [String: String] = [:]
    var current: PPDOption?
    for line in text.split(whereSeparator: \.isNewline) {
      if line.hasPrefix("*Default") {
        let rest = line.dropFirst("*Default".count)
        if let colon = rest.firstIndex(of: ":") {
          defaults[String(rest[..<colon])] = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
      } else if line.hasPrefix("*OpenUI *") {
        // *OpenUI *Key/Label: Type
        let rest = line.dropFirst("*OpenUI *".count)
        guard let slash = rest.firstIndex(of: "/"), let colon = rest.firstIndex(of: ":") else { continue }
        let type = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        current = PPDOption(key: String(rest[..<slash]), label: String(rest[rest.index(after: slash)..<colon]),
                            isBoolean: type == "Boolean", choices: [], def: "")
      } else if line.hasPrefix("*CloseUI") {
        if let c = current, !hidden.contains(c.key) { options.append(c) }
        current = nil
      } else if var c = current, line.hasPrefix("*\(c.key) ") {
        // *Key value/label: "..."
        let rest = line.dropFirst(c.key.count + 2)
        guard let colon = rest.firstIndex(of: ":") else { continue }
        let head = rest[..<colon]
        let (value, label) = head.firstIndex(of: "/").map { (head[..<$0], head[head.index(after: $0)...]) } ?? (head, head)
        c.choices.append(PPDChoice(value: String(value), label: String(label)))
        current = c
      }
    }
    return options.map { var o = $0; o.def = defaults[o.key] ?? o.choices.first?.value ?? ""; return o }
  }
}

/// `Custom.4x6in`-style page size, within the limits the PPD declares (36–295 pt wide, 36–7200 pt tall).
struct CustomSize: Equatable {
  var width = 4.0
  var height = 6.0
  var unit = "in"

  static let units = ["in", "mm", "cm", "pt"]
  private static let perPoint: [String: Double] = ["in": 1 / 72, "mm": 25.4 / 72, "cm": 2.54 / 72, "pt": 1]

  var value: String { "Custom.\(Self.fmt(width))x\(Self.fmt(height))\(unit)" }
  var points: (w: Double, h: Double) { (width / Self.perPoint[unit]!, height / Self.perPoint[unit]!) }
  var inRange: Bool { (36...295).contains(points.w.rounded()) && (36...7200).contains(points.h.rounded()) }

  init() {}
  init?(value: String) {
    guard value.hasPrefix("Custom."),
          let m = value.dropFirst(7).wholeMatch(of: /([0-9.]+)x([0-9.]+)(in|mm|cm|pt|)/),
          let w = Double(m.1), let h = Double(m.2) else { return nil }
    width = w; height = h; unit = m.3.isEmpty ? "pt" : String(m.3)
  }

  private static func fmt(_ d: Double) -> String {
    let s = String(format: "%.2f", d)
    return s.contains(".") ? s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) : s
  }
}

/// Label dimensions in points for a PageSize value (`w288h432` or `Custom.…`).
func pageSizePoints(_ value: String) -> (w: Double, h: Double)? {
  if let c = CustomSize(value: value) { let p = c.points; return (p.w, p.h) }
  if let m = value.wholeMatch(of: /w(\d+)h(\d+)/), let w = Double(m.1), let h = Double(m.2) { return (w, h) }
  return nil
}
