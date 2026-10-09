import Foundation

struct CmdResult {
  let status: Int32
  let output: String
  var ok: Bool { status == 0 }
}

/// Runs a tool without a shell (arguments are never re-parsed) and collects stdout+stderr.
func runTool(_ exe: String, _ args: [String], input: Data? = nil) async -> CmdResult {
  await withCheckedContinuation { cont in
    DispatchQueue.global(qos: .userInitiated).async {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: exe)
      p.arguments = args
      let out = Pipe()
      p.standardOutput = out
      p.standardError = out
      let inPipe = input == nil ? nil : Pipe()
      if let inPipe { p.standardInput = inPipe }
      do { try p.run() } catch {
        cont.resume(returning: CmdResult(status: 127, output: "\(exe): \(error.localizedDescription)"))
        return
      }
      if let input, let inPipe {
        inPipe.fileHandleForWriting.write(input)
        try? inPipe.fileHandleForWriting.close()
      }
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      cont.resume(returning: CmdResult(status: p.terminationStatus,
                                       output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }
  }
}

enum CUPS {
  /// The user's effective defaults: PPD defaults overlaid with ~/.cups/lpoptions.
  static func values(queue: String) async -> [String: String] {
    var vals: [String: String] = [:]
    let listing = await runTool("/usr/bin/lpoptions", ["-p", queue, "-l"]).output
    for line in listing.split(whereSeparator: \.isNewline) {
      // Key/Label: a *b c
      guard let colon = line.firstIndex(of: ":"), let slash = line.firstIndex(of: "/"), slash < colon else { continue }
      let key = String(line[..<slash])
      if let star = line[colon...].split(separator: " ").first(where: { $0.hasPrefix("*") }) {
        vals[key] = String(star.dropFirst())
      }
    }
    // `-l` prints a placeholder for custom sizes; the plain listing has the real value.
    let plain = await runTool("/usr/bin/lpoptions", ["-p", queue]).output
    for part in plain.split(separator: " ") {
      if let eq = part.firstIndex(of: "=") {
        let k = String(part[..<eq])
        if vals[k] != nil { vals[k] = String(part[part.index(after: eq)...]) }
      }
    }
    return vals
  }

  static func save(queue: String, _ changes: [String: String]) async -> CmdResult {
    await runTool("/usr/bin/lpoptions", ["-p", queue] + changes.sorted { $0.key < $1.key }.flatMap { ["-o", "\($0.key)=\($0.value)"] })
  }

  static func reset(queue: String, keys: [String]) async -> CmdResult {
    await runTool("/usr/bin/lpoptions", ["-p", queue] + keys.flatMap { ["-r", $0] })
  }

  static func status(queue: String) async -> PrinterStatus {
    let r = await runTool("/usr/bin/lpstat", ["-p", queue])
    guard r.ok else { return .missing }
    let s = r.output.lowercased()
    if s.contains("disabled") || s.contains("paused") { return .paused }
    if s.contains("now printing") || s.contains("processing") { return .printing }
    if s.contains("idle") { return .ready }
    return .unknown
  }

  /// Sends a file through the queue; `.zpl` files go raw, bypassing the filter and page options.
  static func print(queue: String, file: URL, copies: Int, options: [String: String]) async -> CmdResult {
    let raw = file.pathExtension.lowercased() == "zpl"
    var args = ["-d", queue, "-n", String(copies), "-t", "Ember · \(file.lastPathComponent)"]
    if raw { args += ["-o", "raw"] } else { args += options.sorted { $0.key < $1.key }.flatMap { ["-o", "\($0.key)=\($0.value)"] } }
    return await runTool("/usr/bin/lp", args + [file.path])
  }

  static func printRaw(queue: String, zpl: String) async -> CmdResult {
    await runTool("/usr/bin/lp", ["-d", queue, "-o", "raw", "-t", "Ember ZPL"], input: Data(zpl.utf8))
  }
}

enum PrinterStatus {
  case ready, printing, paused, missing, unknown
  var label: String {
    switch self {
    case .ready: "READY"
    case .printing: "PRINTING"
    case .paused: "PAUSED"
    case .missing: "NO QUEUE"
    case .unknown: "UNKNOWN"
    }
  }
}

/// The printer actions that go straight to the USB device through the bundled `rp425` tool.
enum PrinterAction: String, CaseIterable, Identifiable {
  case calibrate, feed, config, cancel
  var id: String { rawValue }
  var title: String {
    switch self {
    case .calibrate: "Calibrate"
    case .feed: "Feed"
    case .config: "Config label"
    case .cancel: "Flush buffer"
    }
  }
  var symbol: String {
    switch self {
    case .calibrate: "scope"
    case .feed: "arrow.down.to.line"
    case .config: "doc.text"
    case .cancel: "xmark.bin"
    }
  }
  var detail: String {
    switch self {
    case .calibrate: "Re-measure label and gap length. Do this after changing stock."
    case .feed: "Feed one label."
    case .config: "Print the printer's own configuration label."
    case .cancel: "Cancel everything buffered inside the printer."
    }
  }

  static var tool: String? {
    [Bundle.main.path(forResource: "rp425", ofType: nil), "/usr/local/bin/rp425"]
      .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
