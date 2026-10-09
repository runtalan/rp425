import SwiftUI

@main
struct EmberApp: App {
  @StateObject private var store = Store()

  init() {
    // Headless check: `Ember --snapshot out.png` renders the window to a PNG and exits.
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
      let path = args[i + 1]
      let overrides = args.dropFirst(i + 2).compactMap { a -> (String, String)? in
        let p = a.split(separator: "=", maxSplits: 1).map(String.init); return p.count == 2 ? (p[0], p[1]) : nil
      }
      Task { @MainActor in
        let store = Store()
        await store.load()
        for (k, v) in overrides { store.values[k] = v }
        let host = NSHostingView(rootView: ContentView().environmentObject(store))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.appearance = NSAppearance(named: .darkAqua)
        win.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.cacheDisplay(in: host.bounds, to: rep)
          try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
      }
    }
  }

  var body: some Scene {
    Window("Ember", id: "main") {
      ContentView().environmentObject(store)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 1060, height: 800)
  }
}
