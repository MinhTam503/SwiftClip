import AppKit
// Opt-in diagnostics use an isolated temporary database and private pasteboard.
// They never read or modify the user's clipboard/history or preferences.
import Darwin

extension AppDelegate {
  func runDiagnostics() {
    monitor.stop()
    let args = ProcessInfo.processInfo.arguments
    let output: URL
    if let index = args.firstIndex(of: "--diagnostic-output"), index + 1 < args.count {
      output = URL(fileURLWithPath: args[index + 1])
    } else {
      output = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftClip-measurements.json")
    }
    let long = args.contains("--diagnostic")
    var samples = [[String: Any]]()
    let began = DispatchTime.now().uptimeNanoseconds
    let wallBegan = Date()
    func sample(_ phase: String) {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      let cpu =
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
          usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
      let wallElapsed = Date().timeIntervalSince(wallBegan)
      samples.append([
        "phase": phase, "seconds": elapsed, "wallSeconds": wallElapsed,
        "interruptedBySleep": wallElapsed - elapsed > 5,
        "physicalFootprintMiB": status == KERN_SUCCESS
          ? Double(info.phys_footprint) / 1_048_576 : -1,
        "residentMiB": Double(info.resident_size) / 1_048_576, "cpuSeconds": cpu,
      ])
      if let data = try? JSONSerialization.data(
        withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: output, options: .atomic)
      }
    }
    func after(_ seconds: Double, _ action: @escaping () -> Void) {
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }
    func checkpoint(_ minute: Int) {
      guard long, minute < 10 else { return }
      after(60) {
        sample("idle_minute_\(minute)")
        checkpoint(minute + 1)
      }
    }
    after(2) {
      sample("idle_initial")
      checkpoint(1)
      // Keep the actual polling timer active, but use a private pasteboard in diagnostics.
      self.monitor.start(pasteboard: NSPasteboard.withUniqueName())
      after(long ? 600 : 5) {
        sample(long ? "idle_10_minutes" : "idle_5_seconds")
        self.model.perform { repo in
          let pb = NSPasteboard.withUniqueName()
          defer { pb.releaseGlobally() }
          for i in 0..<1000 {
            try autoreleasepool {
              let text =
                "SwiftClip diagnostic text \(i)\n"
                + String(repeating: "Native clipboard history. ", count: 10)
              let payload = Payload(items: [
                [
                  Representation(
                    type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
                ]
              ])
              _ = PasteManager.write(payload, to: pb)
              guard let (p, k, t) = ClipboardReader.read(pb, maxBytes: 20 * 1024 * 1024) else {
                return
              }
              try repo.save(p, kind: k, preview: t, source: "diagnostic", limit: 0)
            }
          }
          DispatchQueue.main.async {
            after(1) {
              sample("after_1000_text")
              self.model.perform { repo in
                let pb = NSPasteboard.withUniqueName()
                defer { pb.releaseGlobally() }
                for i in 0..<100 {
                  try autoreleasepool {
                    let bitmap = NSBitmapImageRep(
                      bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8,
                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    if let bytes = bitmap.bitmapData {
                      arc4random_buf(bytes, bitmap.bytesPerRow * bitmap.pixelsHigh)
                    }
                    guard let data = bitmap.representation(using: .png, properties: [:]) else {
                      return
                    }
                    let payload = Payload(items: [
                      [
                        Representation(type: NSPasteboard.PasteboardType.png.rawValue, data: data),
                        Representation(
                          type: NSPasteboard.PasteboardType.string.rawValue,
                          data: Data("Diagnostic image \(i)".utf8)),
                      ]
                    ])
                    _ = PasteManager.write(payload, to: pb)
                    guard let (p, k, t) = ClipboardReader.read(pb, maxBytes: 20 * 1024 * 1024)
                    else { return }
                    try repo.save(p, kind: k, preview: t, source: "diagnostic", limit: 0)
                  }
                }
                DispatchQueue.main.async {
                  after(1) {
                    sample("after_100_images_512px")
                    self.show()
                    after(2) {
                      sample("popup_images")
                      self.close()
                      func cycle(_ n: Int) {
                        guard n > 0 else {
                          after(2) {
                            sample(long ? "after_100_popup_cycles" : "after_20_popup_cycles")
                            self.model.perform { repo in
                              try repo.clear()
                              DispatchQueue.main.async {
                                after(2) {
                                  sample("after_clear_all")
                                  self.monitor.stop()
                                  self.model.perform { repo in
                                    let root = repo.root
                                    DispatchQueue.main.async {
                                      self.model.queue.async {
                                        try? FileManager.default.removeItem(at: root)
                                      }
                                      NSApp.terminate(nil)
                                    }
                                  }
                                }
                              }
                            }
                          }
                          return
                        }
                        if long && n == 80 { sample("after_20_popup_cycles") }
                        self.show()
                        after(0.2) {
                          self.close()
                          after(0.2) { cycle(n - 1) }
                        }
                      }
                      cycle(long ? 100 : 20)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

extension AppDelegate {
  /// Explicit test-only event trace; never records clipboard content or application identities.
  func recordUIEvent(_ name: String) {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--ui-test-output"), index + 1 < args.count else {
      return
    }
    let url = URL(fileURLWithPath: args[index + 1])
    var events =
      ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        as? [[String: Any]]) ?? []
    events.append(["event": name, "time": Date().timeIntervalSince1970])
    if let data = try? JSONSerialization.data(
      withJSONObject: Array(events.suffix(100)), options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: url, options: .atomic)
    }
  }
}
