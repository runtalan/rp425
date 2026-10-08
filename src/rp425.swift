// rp425 - talk to a Rongta RP425 directly over USB (no CUPS, no vendor software).
//
//   rp425 info                 IEEE 1284 device ID and firmware (~HI)
//   rp425 status               host status (~HS), on firmware that supports it
//   rp425 send [file|-]        send raw ZPL (or the output of rastertorp425)
//   rp425 calibrate            measure label length / gap (~JC)
//   rp425 feed                 feed one label (~PH)
//   rp425 config               print the configuration label (~WC)
//   rp425 cancel               cancel everything buffered in the printer (~JA)

import Foundation
import IOUSBHost

let vendorID = 0x0FE6
let productID = 0x8800

struct Printer {
  let intf: IOUSBHostInterface
  let outPipe: IOUSBHostPipe
  let inPipe: IOUSBHostPipe?

  static func open() throws -> Printer {
    var it: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it)
    defer { IOObjectRelease(it) }
    while case let s = IOIteratorNext(it), s != 0 {
      var dev: io_registry_entry_t = 0
      IORegistryEntryGetParentEntry(s, kIOServicePlane, &dev)
      func prop(_ k: String) -> Int? {
        IORegistryEntryCreateCFProperty(dev, k as CFString, nil, 0)?.takeRetainedValue() as? Int
      }
      guard prop("idVendor") == vendorID, prop("idProduct") == productID else {
        IOObjectRelease(s)
        continue
      }
      let intf = try IOUSBHostInterface(__ioService: s, options: [], queue: nil, interestHandler: nil)
      var out: IOUSBHostPipe?, inp: IOUSBHostPipe?
      for ep in 1...15 {
        if out == nil { out = try? intf.copyPipe(withAddress: ep) }
        if inp == nil { inp = try? intf.copyPipe(withAddress: 0x80 | ep) }
      }
      guard let out else { throw Failure("printer has no bulk OUT endpoint") }
      // A previous process may have abandoned a read mid-transfer; resync data toggles.
      try? out.clearStall()
      try? inp?.clearStall()
      return Printer(intf: intf, outPipe: out, inPipe: inp)
    }
    throw Failure("RP425 (0FE6:8800) not found on USB — is it on and plugged in? (Is a CUPS job holding it?)")
  }

  func deviceID() throws -> String {
    let req = IOUSBDeviceRequest(bmRequestType: 0xA1, bRequest: 0, wValue: 0, wIndex: 0, wLength: 1024)
    let buf = NSMutableData(length: 1024)!
    var n = 0
    try intf.__send(req, data: buf, bytesTransferred: &n, completionTimeout: 2)
    return String(decoding: (buf as Data).prefix(n).dropFirst(2), as: UTF8.self)
  }

  func write(_ data: Data) throws {
    let chunk = 16 * 1024
    var offset = 0
    while offset < data.count {
      let part = NSMutableData(data: data.subdata(in: offset..<min(offset + chunk, data.count)))
      var sent = 0
      try outPipe.__sendIORequest(with: part, bytesTransferred: &sent, completionTimeout: 30)
      offset += sent
    }
  }

  /// Reads until the printer goes quiet; replies to ~HS arrive as several STX..ETX frames.
  func read(timeout: TimeInterval = 2) -> Data {
    guard let inPipe else { return Data() }
    var all = Data()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let buf = NSMutableData(length: 4096)!
      var n = 0
      do {
        try inPipe.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: all.isEmpty ? timeout : 1)
      } catch { if ProcessInfo.processInfo.environment["RP425_DEBUG"] != nil { FileHandle.standardError.write("read: \(error)\n".data(using: .utf8)!) }; break }
      if n == 0 { continue }
      all.append((buf as Data).prefix(n))
    }
    return all
  }

  func query(_ cmd: String) throws -> [String] {
    try write(Data(cmd.utf8))
    let text = String(decoding: read(), as: UTF8.self)
    return text.split(whereSeparator: { $0 == "\u{02}" || $0 == "\u{03}" || $0 == "\r" || $0 == "\n" })
      .map(String.init).filter { !$0.isEmpty }
  }
}

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ s: String) { description = s }
}

func describeStatus(_ frames: [String]) -> String {
  // ~HS returns three frames; see the ZPL manual. Fields we care about:
  // frame 1: aaa,b,c,dddd,eee,f,g,h,iii,j,k,l  (b = paper out, c = pause, ...)
  // frame 2: mmm,n,o,p,q,r,s,t,uuuuuuuu,v,www  (o = head up, p = ribbon out, ...)
  guard frames.count >= 2 else { return "no ~HS reply (raw: \(frames))" }
  let a = frames[0].split(separator: ",").map(String.init)
  let b = frames[1].split(separator: ",").map(String.init)
  var problems: [String] = []
  if a.count > 1, a[1] == "1" { problems.append("paper out") }
  if a.count > 2, a[2] == "1" { problems.append("paused") }
  if a.count > 5, a[5] == "1" { problems.append("receive buffer full") }
  if a.count > 9, a[9] == "1" { problems.append("corrupt RAM") }
  if a.count > 10, a[10] == "1" { problems.append("head too cold") }
  if a.count > 11, a[11] == "1" { problems.append("head too hot") }
  if b.count > 2, b[2] == "1" { problems.append("head open") }
  let queued = a.count > 4 ? Int(a[4]) ?? 0 : 0
  var s = problems.isEmpty ? "ready" : problems.joined(separator: ", ")
  if queued > 0 { s += " (\(queued) label formats in buffer)" }
  return s + "\n" + frames.joined(separator: "\n")
}

func run() throws {
  let args = Array(CommandLine.arguments.dropFirst())
  guard let cmd = args.first else {
    print("usage: rp425 info | status | send [file|-] | calibrate | feed | config | cancel")
    exit(2)
  }
  let p = try Printer.open()
  switch cmd {
  case "info":
    print("device id: \(try p.deviceID())")
    print("firmware:  \(try p.query("~HI\r\n").joined(separator: " "))")
  case "status":
    // Firmware V1.11 answers neither ~HS nor the USB GET_PORT_STATUS request.
    let hs = try p.query("~HS\r\n")
    print(hs.isEmpty ? "printer did not answer ~HS (RP425 firmware V1.11 does not report status)" : describeStatus(hs))
  case "send":
    let path = args.count > 1 ? args[1] : "-"
    let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile()
      : try Data(contentsOf: URL(fileURLWithPath: path))
    try p.write(data)
    FileHandle.standardError.write("sent \(data.count) bytes\n".data(using: .utf8)!)
  case "calibrate": try p.write(Data("~JC\r\n".utf8))
  case "feed": try p.write(Data("~PH\r\n".utf8))
  case "config": try p.write(Data("~WC\r\n".utf8))
  case "cancel": try p.write(Data("~JA\r\n".utf8))
  default:
    throw Failure("unknown command \(cmd)")
  }
}

do { try run() } catch {
  FileHandle.standardError.write("rp425: \(error)\n".data(using: .utf8)!)
  exit(1)
}
