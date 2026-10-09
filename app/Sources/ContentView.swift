import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject var store: Store
  @State private var customSize = CustomSize()
  @State private var confirmReset = false
  @State private var copies = 1
  @State private var dropping = false
  @State private var showZPL = false
  @State private var zpl = "^XA\n^FO40,40^A0N,60,60^FDHello, Ember^FS\n^XZ"

  var body: some View {
    ZStack {
      Backdrop()
      HStack(spacing: 0) {
        controls.frame(width: 408)
        stage
      }
      .overlay(alignment: .bottom) { toast }
    }
    .frame(minWidth: 980, minHeight: 700)
    .preferredColorScheme(.dark)
    .task { if !store.loaded { await store.load() }; syncCustom() }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        await store.refreshStatus()
      }
    }
    .confirmationDialog("Remove all your saved RP425 defaults?", isPresented: $confirmReset) {
      Button("Restore driver defaults", role: .destructive) { Task { await store.resetToDriverDefaults(); syncCustom() } }
    }
  }

  // MARK: Left column

  private var controls: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        VStack(spacing: 14) {
          Card(title: "Label", symbol: "tag") {
            sizeRow
            row("Media tracking", hint: "Gap, black mark or continuous roll") { picker("MediaTracking") }
            toggleRow("Rotate 180°", key: "Rotate180", hint: "Print upside down")
          }
          Card(title: "Print quality", symbol: "flame") {
            darknessRow
            row("Speed", hint: "Inches per second") { picker("PrintSpeed") }
            row("Halftoning", hint: "Sharp for text and barcodes, dithered for photos") { ditherPicker }
            thresholdRow
            row("Compression", hint: "ZPL run-length shrinks the upload") { picker("Compression") }
          }
          Card(title: "Position", symbol: "arrow.up.and.down.and.arrow.left.and.right") {
            offsetRow("Vertical offset", key: "TopOffset")
            offsetRow("Horizontal offset", key: "LeftOffset")
          }
          let rest = store.options.filter { !Self.known.contains($0.key) }
          if !rest.isEmpty {
            Card(title: "More") { ForEach(rest) { o in row(o.label) { picker(o.key) } } }
          }
        }
        .padding(.horizontal, 18).padding(.bottom, 14)
      }
      .scrollIndicators(.hidden)
      saveBar
    }
  }

  private static let known: Set<String> = ["PageSize", "MediaTracking", "Rotate180", "Darkness", "PrintSpeed", "Dither", "Threshold", "Compression", "TopOffset", "LeftOffset"]

  private var header: some View {
    HStack(spacing: 12) {
      LogoTile()
      VStack(alignment: .leading, spacing: 0) {
        Text("ember").font(Brand.wordmark).foregroundStyle(Brand.heat).kerning(-0.5)
        Text("RP425 · THERMAL LABEL CONTROL").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(Brand.mute)
      }
      Spacer()
      statusChip
    }
    .padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 16)
  }

  private var statusChip: some View {
    let c: Color = switch store.status {
    case .ready: .green
    case .printing: Brand.amber
    case .paused, .missing: Brand.magenta
    case .unknown: .gray
    }
    return HStack(spacing: 6) {
      Circle().fill(c).frame(width: 7, height: 7).shadow(color: c, radius: 4)
      Text(store.status.label).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(Capsule().fill(.white.opacity(0.07)))
    .help("CUPS queue “\(store.queue)”")
  }

  private var saveBar: some View {
    let n = store.dirtyKeys.count
    return HStack(spacing: 10) {
      Menu {
        Button("Restore driver defaults…") { confirmReset = true }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).frame(width: 26)
      Text(n == 0 ? "All saved" : "\(n) unsaved")
        .font(Brand.mono).foregroundStyle(n == 0 ? Brand.mute : Brand.amber)
      Spacer()
      Button("Revert") { store.revert(); syncCustom() }.buttonStyle(HeatButtonStyle()).disabled(n == 0).opacity(n == 0 ? 0.4 : 1)
      Button("Save as defaults") { Task { await store.save() } }
        .buttonStyle(HeatButtonStyle(prominent: true)).disabled(n == 0).opacity(n == 0 ? 0.4 : 1)
        .keyboardShortcut("s")
    }
    .padding(.horizontal, 18).padding(.vertical, 14)
    .background(.black.opacity(0.35))
    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
  }

  // MARK: Rows

  private func row<C: View>(_ title: String, hint: String? = nil, @ViewBuilder _ control: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
        if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Brand.mute).lineLimit(1) }
      }
      control()
    }
  }

  private func toggleRow(_ title: String, key: String, hint: String) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
        Text(hint).font(.system(size: 11)).foregroundStyle(Brand.mute)
      }
      Spacer()
      Toggle("", isOn: Binding(get: { store.value(key) == "True" }, set: { store.values[key] = $0 ? "True" : "False" }))
        .toggleStyle(.switch).tint(Brand.ember).labelsHidden()
    }
  }

  private func pickerItems(_ key: String) -> [(value: String, label: String)] {
    (store.option(key)?.choices ?? []).map { c in
      (c.value, c.value == "Default" ? "Auto" : c.label.replacingOccurrences(of: " in/s", with: ""))
    }
  }

  @ViewBuilder private func picker(_ key: String) -> some View {
    let items = pickerItems(key)
    if items.count <= 5 {
      HeatPicker(items: items, selection: store.binding(key))
    } else {
      Picker("", selection: store.binding(key)) { ForEach(items, id: \.value) { Text($0.label).tag($0.value) } }
        .labelsHidden().pickerStyle(.menu)
    }
  }

  private var ditherPicker: some View {
    HeatPicker(items: (store.option("Dither")?.choices ?? []).map { ($0.value, $0.value == "Threshold" ? "Sharp" : "Dithered") },
               selection: store.binding("Dither"))
  }

  private var sizeRow: some View {
    let choices = store.option("PageSize")?.choices ?? []
    let isCustom = store.value("PageSize").hasPrefix("Custom.")
    return row("Label size", hint: "Up to 4.1″ wide, 100″ tall") {
      VStack(alignment: .leading, spacing: 8) {
        Picker("", selection: Binding(get: { isCustom ? "Custom" : store.value("PageSize") }, set: { v in
          if v == "Custom" { store.values["PageSize"] = customSize.value } else { store.values["PageSize"] = v }
        })) {
          ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
          Divider()
          Text("Custom size…").tag("Custom")
        }.labelsHidden().pickerStyle(.menu)
        if isCustom {
          HStack(spacing: 6) {
            numberField($customSize.width)
            Text("×").foregroundStyle(Brand.mute)
            numberField($customSize.height)
            Picker("", selection: $customSize.unit) { ForEach(CustomSize.units, id: \.self) { Text($0).tag($0) } }
              .labelsHidden().frame(width: 64)
          }
          if !customSize.inRange {
            Text("Outside what the printer accepts (36–295 pt wide, 36–7200 pt tall)").font(.system(size: 11)).foregroundStyle(Brand.magenta)
          }
        }
      }
    }
    .onChange(of: customSize) { c in if store.value("PageSize").hasPrefix("Custom.") && c.inRange { store.values["PageSize"] = c.value } }
  }

  private func numberField(_ v: Binding<Double>) -> some View {
    TextField("", value: v, format: .number.precision(.fractionLength(0...2)))
      .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
  }

  private var darknessRow: some View {
    let auto = store.value("Darkness") == "Default"
    let level = Double(store.value("Darkness")) ?? 15
    return row("Darkness", hint: "Heat applied to the paper") {
      HStack(spacing: 12) {
        Slider(value: Binding(get: { level }, set: { store.values["Darkness"] = String(Int(($0 / 2).rounded() * 2)) }), in: 0...30, step: 2)
          .tint(Brand.ember).disabled(auto).opacity(auto ? 0.35 : 1)
        Text(auto ? "—" : "\(Int(level))").font(Brand.mono).frame(width: 24, alignment: .trailing)
        Toggle("Auto", isOn: Binding(get: { auto }, set: { store.values["Darkness"] = $0 ? "Default" : "15" }))
          .toggleStyle(.checkbox).font(.system(size: 12))
      }
    }
  }

  private var thresholdRow: some View {
    let choices = (store.option("Threshold")?.choices ?? [])
    let idx = Double(choices.firstIndex { $0.value == store.value("Threshold") } ?? 2)
    return row("Black threshold", hint: "What counts as black in sharp mode") {
      HStack(spacing: 12) {
        Slider(value: Binding(get: { idx }, set: { i in
          if let c = choices[safe: Int(i.rounded())] { store.values["Threshold"] = c.value }
        }), in: 0...Double(max(choices.count - 1, 1)), step: 1).tint(Brand.ember)
        Text(store.label(of: "Threshold")).font(Brand.mono).frame(width: 96, alignment: .trailing).lineLimit(1)
      }
    }
    .opacity(store.value("Dither") == "Threshold" ? 1 : 0.4)
  }

  private func offsetRow(_ title: String, key: String) -> some View {
    let choices = store.option(key)?.choices ?? []
    let dots = Double(store.value(key)) ?? 0
    let lo = Double(choices.first?.value ?? "-24") ?? -24, hi = Double(choices.last?.value ?? "24") ?? 24
    return row(title) {
      HStack(spacing: 12) {
        Slider(value: Binding(get: { dots }, set: { store.values[key] = String(Int(($0 / 8).rounded() * 8)) }), in: lo...hi, step: 8).tint(Brand.ember)
        Text(String(format: "%+d mm", Int(dots / 8))).font(Brand.mono).frame(width: 56, alignment: .trailing)
        Button { store.values[key] = "0" } label: { Image(systemName: "arrow.counterclockwise") }
          .buttonStyle(.plain).foregroundStyle(Brand.mute).opacity(dots == 0 ? 0.25 : 1).disabled(dots == 0).help("Zero")
      }
    }
  }

  // MARK: Right column

  private var stage: some View {
    let spec = PreviewSpec(store)
    return VStack(spacing: 14) {
      ZStack(alignment: .topLeading) {
        LabelPreview(spec: spec)
        VStack(alignment: .leading, spacing: 2) {
          Text("LIVE PREVIEW").font(Brand.sectionTitle).tracking(1.6).foregroundStyle(Brand.mute)
          Text(sizeCaption(spec)).font(Brand.mono).foregroundStyle(.white.opacity(0.8))
        }.padding(20)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.28))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.07))))
      .overlay(dropOverlay)
      .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
          if let url { Task { @MainActor in await store.print(file: url, copies: copies) } }
        }
        return true
      }
      actions
    }
    .padding(.trailing, 20).padding(.vertical, 20)
  }

  private func sizeCaption(_ s: PreviewSpec) -> String {
    let wd = Int((s.widthPt * 203 / 72).rounded()), hd = Int((s.heightPt * 203 / 72).rounded())
    let name = CustomSize(value: store.value("PageSize")).map { "\(Self.num($0.width)) × \(Self.num($0.height)) \($0.unit) (custom)" } ?? store.label(of: "PageSize")
    return "\(name) · \(wd)×\(hd) dots @ 203 dpi"
  }

  private static func num(_ d: Double) -> String { d.formatted(.number.precision(.fractionLength(0...2))) }

  private var dropOverlay: some View {
    RoundedRectangle(cornerRadius: 20, style: .continuous)
      .strokeBorder(Brand.heat, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
      .overlay(Text("Drop to print").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Brand.heat))
      .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.black.opacity(0.55)))
      .opacity(dropping ? 1 : 0).allowsHitTesting(false)
      .animation(.easeOut(duration: 0.15), value: dropping)
  }

  private var actions: some View {
    Card(title: "Printer", symbol: "printer") {
      HStack(spacing: 8) {
        ForEach(PrinterAction.allCases) { a in
          Button { Task { await store.run(a) } } label: {
            Label(a.title, systemImage: a.symbol).labelStyle(.titleAndIcon).frame(maxWidth: .infinity)
          }
          .buttonStyle(HeatButtonStyle()).help(a.detail)
          .disabled(!store.hasTool || store.busy.contains(a.id))
        }
      }
      HStack(spacing: 10) {
        Button { Task { await store.printTestLabel() } } label: { Label("Print test label", systemImage: "flame.fill") }
          .buttonStyle(HeatButtonStyle(prominent: true)).disabled(store.busy.contains("print"))
        Button { choose() } label: { Label("Print file…", systemImage: "doc.badge.arrow.up") }
          .buttonStyle(HeatButtonStyle()).disabled(store.busy.contains("print"))
        Stepper(value: $copies, in: 1...99) { Text("×\(copies)").font(Brand.mono) }.fixedSize()
        Spacer()
        Button { withAnimation(.snappy) { showZPL.toggle() } } label: { Label("ZPL", systemImage: "chevron.left.forwardslash.chevron.right") }
          .buttonStyle(HeatButtonStyle())
      }
      if showZPL {
        TextEditor(text: $zpl).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
          .padding(8).frame(height: 96).background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.4)))
        HStack {
          Text("Sent raw — your page settings don't apply.").font(.system(size: 11)).foregroundStyle(Brand.mute)
          Spacer()
          Button("Send ZPL") { Task { await store.sendZPL(zpl) } }.buttonStyle(HeatButtonStyle(prominent: true)).disabled(store.busy.contains("zpl"))
        }
      }
      if !store.hasTool {
        Text("rp425 tool not found — Calibrate, Feed, Config and Flush are unavailable.").font(.system(size: 11)).foregroundStyle(Brand.magenta)
      }
    }
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf, .png, .jpeg, .gif, .plainText, UTType(filenameExtension: "zpl")].compactMap { $0 }
    panel.message = "Choose a file to print with the settings shown. .zpl files are sent raw."
    if panel.runModal() == .OK, let url = panel.url { Task { await store.print(file: url, copies: copies) } }
  }

  private var toast: some View {
    Group {
      if let t = store.toast {
        Text(t.text).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(4)
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(Capsule().fill(t.isError ? AnyShapeStyle(Brand.magenta) : AnyShapeStyle(Color(white: 0.16))).shadow(radius: 12))
          .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
          .padding(.bottom, 22).transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.spring(duration: 0.3), value: store.toast)
  }

  private func syncCustom() {
    if let c = CustomSize(value: store.value("PageSize")) { customSize = c }
  }
}

extension Array {
  subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
