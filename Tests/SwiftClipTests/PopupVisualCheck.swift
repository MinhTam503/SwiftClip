import AppKit
import SwiftUI
import XCTest

@testable import SwiftClip

final class PopupVisualCheck: XCTestCase {
  func testRenderPopupForVisualReview() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftClip-UI-Review-" + UUID().uuidString)
    let model = HistoryModel(root: root)
    let app = AppDelegate(model: model)
    defer {
      model.queue.sync {}
      try? FileManager.default.removeItem(at: root)
    }
    let now = Date()
    model.beginPresentation(at: now)
    model.clips = [
      Clip(
        id: "a", kind: "text", preview: "Nội dung đã sao chép — chọn để dán", path: "",
        thumbnail: nil, date: now.addingTimeInterval(-125), pinned: true, size: 100),
      Clip(
        id: "b", kind: "url", preview: "https://example.com", path: "", thumbnail: nil,
        date: now.addingTimeInterval(-3600), pinned: false, size: 100),
    ]
    model.selected = "a"
    let panel = ClipboardPanel(clipboardRect: NSRect(x: 0, y: 0, width: 420, height: 260))
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.isReleasedWhenClosed = false
    let view = ClipboardHostingView(rootView: PopupView(model: model, app: app))
    panel.contentView = view
    view.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let savedSelection = Localization.shared.selection
    let savedPreference = UserDefaults.standard.object(forKey: Localization.preferenceKey)
    defer {
      Localization.shared.selection = savedSelection
      if let savedPreference {
        UserDefaults.standard.set(savedPreference, forKey: Localization.preferenceKey)
      } else {
        UserDefaults.standard.removeObject(forKey: Localization.preferenceKey)
      }
    }
    func snapshot(_ view: NSView, path: String) throws {
      view.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.3))
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: URL(fileURLWithPath: path))
    }
    for language in [AppLanguage.en, .vi] {
      Localization.shared.selection = language
      try snapshot(view, path: "/private/tmp/swiftclip-popup-\(language.rawValue).png")
    }
    let settingsWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 620), styleMask: [.titled],
      backing: .buffered, defer: false)
    settingsWindow.isReleasedWhenClosed = false
    let settingsView = NSHostingView(
      rootView: SettingsView(settings: Settings.shared, model: model, app: app))
    settingsWindow.contentView = settingsView
    settingsView.frame = NSRect(x: 0, y: 0, width: 580, height: 620)
    for language in [AppLanguage.en, .vi] {
      Localization.shared.selection = language
      try snapshot(settingsView, path: "/private/tmp/swiftclip-settings-\(language.rawValue).png")
    }
    settingsWindow.contentView = nil
    settingsWindow.close()
    panel.contentView = nil
    panel.close()
  }
}
