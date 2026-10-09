import SwiftUI

struct Toast: Equatable {
  let id = UUID()
  let text: String
  let isError: Bool
}

@MainActor
final class Store: ObservableObject {
  let queue: String
  @Published var options: [PPDOption] = []
  @Published var values: [String: String] = [:]
  @Published var saved: [String: String] = [:]
  @Published var status: PrinterStatus = .unknown
  @Published var toast: Toast?
  @Published var busy: Set<String> = []
  @Published var loaded = false

  init(queue: String = "RP425") { self.queue = queue }

  var dirtyKeys: [String] { options.map(\.key).filter { values[$0] != saved[$0] } }
  var hasTool: Bool { PrinterAction.tool != nil }

  func option(_ key: String) -> PPDOption? { options.first { $0.key == key } }

  func value(_ key: String) -> String { values[key] ?? option(key)?.def ?? "" }

  func binding(_ key: String) -> Binding<String> {
    Binding(get: { self.value(key) }, set: { self.values[key] = $0 })
  }

  func load() async {
    options = PPD.load(queue: queue)
    let current = await CUPS.values(queue: queue)
    var v: [String: String] = [:]
    for o in options { v[o.key] = current[o.key] ?? o.def }
    saved = v
    values = v
    loaded = true
    await refreshStatus()
  }

  func refreshStatus() async { status = await CUPS.status(queue: queue) }

  func revert() { values = saved }

  func save() async {
    let changes = Dictionary(uniqueKeysWithValues: dirtyKeys.map { ($0, value($0)) })
    guard !changes.isEmpty else { return }
    let r = await CUPS.save(queue: queue, changes)
    show(r.ok ? "Saved \(changes.count) setting\(changes.count == 1 ? "" : "s") as your defaults" : r.output, error: !r.ok)
    if r.ok { saved = values }
  }

  func resetToDriverDefaults() async {
    let r = await CUPS.reset(queue: queue, keys: options.map(\.key))
    show(r.ok ? "Back to driver defaults" : r.output, error: !r.ok)
    if r.ok { await load() }
  }

  func run(_ action: PrinterAction) async {
    guard let tool = PrinterAction.tool else { return show("rp425 tool not found — run make native", error: true) }
    busy.insert(action.id)
    defer { busy.remove(action.id) }
    let r = await runTool(tool, [action.rawValue])
    show(r.ok ? "\(action.title) sent" : r.output, error: !r.ok)
  }

  func print(file: URL, copies: Int) async {
    busy.insert("print")
    defer { busy.remove("print") }
    let r = await CUPS.print(queue: queue, file: file, copies: copies, options: values)
    show(r.ok ? "Sent \(file.lastPathComponent)" : r.output, error: !r.ok)
    await refreshStatus()
  }

  func printTestLabel() async {
    let (w, h) = pageSizePoints(value("PageSize")) ?? (288, 432)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ember-test.pdf")
    TestLabel.write(to: url, width: w, height: h, size: label(of: "PageSize"), settings: values)
    await print(file: url, copies: 1)
  }

  func sendZPL(_ zpl: String) async {
    busy.insert("zpl")
    defer { busy.remove("zpl") }
    let r = await CUPS.printRaw(queue: queue, zpl: zpl)
    show(r.ok ? "ZPL sent" : r.output, error: !r.ok)
  }

  func label(of key: String) -> String {
    let v = value(key)
    return option(key)?.choices.first { $0.value == v }?.label ?? v
  }

  func show(_ text: String, error: Bool = false) {
    let t = Toast(text: text, isError: error)
    toast = t
    Task {
      try? await Task.sleep(nanoseconds: error ? 6_000_000_000 : 2_800_000_000)
      if toast?.id == t.id { toast = nil }
    }
  }
}
