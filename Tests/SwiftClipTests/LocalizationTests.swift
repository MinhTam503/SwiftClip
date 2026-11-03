import AppKit
import XCTest

@testable import SwiftClip

final class LocalizationTests: XCTestCase {
  func withLocale(_ body: (Localization, UserDefaults) throws -> Void) rethrows {
    let name = "SwiftClipTests.Localization." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(Localization(defaults: defaults), defaults)
  }
  func testEveryKeyIsTranslatedAndPlaceholderSignaturesMatch() throws {
    let pattern = try NSRegularExpression(pattern: "%[0-9$]*l?[d@]|%%")
    func signature(_ text: String) -> [String] {
      pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        String(text[Range($0.range, in: text)!])
      }
    }
    for key in L10n.Key.allCases {
      let en = Localization.bundle(language: "en").localizedString(
        forKey: key.rawValue, value: "__MISSING__", table: "Localizable")
      let vi = Localization.bundle(language: "vi").localizedString(
        forKey: key.rawValue, value: "__MISSING__", table: "Localizable")
      XCTAssertNotEqual(en, "__MISSING__", key.rawValue)
      XCTAssertNotEqual(vi, "__MISSING__", key.rawValue)
      XCTAssertFalse(en.isEmpty)
      XCTAssertFalse(vi.isEmpty)
      XCTAssertEqual(signature(en), signature(vi), key.rawValue)
    }
  }
  func testSelectionPersistsAndSystemLanguageFallsBack() {
    withLocale { localization, defaults in
      localization.selection = .vi
      XCTAssertEqual(localization.text(.settings), "Cài đặt")
      XCTAssertEqual(Localization(defaults: defaults).selection, .vi)
      localization.selection = .en
      XCTAssertEqual(localization.text(.settings), "Settings")
      XCTAssertEqual(Localization(defaults: defaults).selection, .en)
    }
    XCTAssertEqual(Localization.resolve(.system, preferred: ["vi-VN", "en-US"]), "vi")
    XCTAssertEqual(Localization.resolve(.system, preferred: ["fr-FR", "en-GB"]), "en")
    XCTAssertEqual(Localization.resolve(.system, preferred: ["fr-FR"]), "en")
    XCTAssertEqual(Localization.resolve(.en, preferred: ["vi-VN"]), "en")
  }
  func testFormattingAndStaticTimestampsInBothLanguages() {
    withLocale { localization, _ in
      let date = Date(timeIntervalSince1970: 10000)
      localization.selection = .en
      XCTAssertEqual(
        ClipboardTimestamp.label(
          date, relativeTo: date.addingTimeInterval(60), localization: localization), "1 minute ago"
      )
      XCTAssertEqual(
        ClipboardTimestamp.label(
          date, relativeTo: date.addingTimeInterval(120), localization: localization),
        "2 minutes ago")
      XCTAssertEqual(
        localization.text(.recordFocusSearch, arguments: [3]), "Record Focus Search (key 3)")
      localization.selection = .vi
      XCTAssertEqual(
        ClipboardTimestamp.label(
          date, relativeTo: date.addingTimeInterval(120), localization: localization),
        "2 phút trước")
      XCTAssertEqual(
        localization.text(.recordFocusSearch, arguments: [3]), "Ghi phím tìm kiếm (phím 3)")
    }
  }
  func testExistingNoticeRetranslatesWithoutRecreatingError() {
    withLocale { localization, _ in
      let notice = AppNotice.message(.shortcutConflict)
      let error = AppNotice.error(AppError.shortcutUnavailable(-9878), .operationFailed)
      localization.selection = .en
      XCTAssertTrue(notice.localized(using: localization).hasPrefix("Shortcut"))
      XCTAssertTrue(error.localized(using: localization).contains("-9878"))
      localization.selection = .vi
      XCTAssertTrue(notice.localized(using: localization).hasPrefix("Phím"))
      XCTAssertTrue(error.localized(using: localization).hasPrefix("Phím tắt"))
    }
  }
  func testClipboardPayloadDoesNotChangeWhenLanguageChanges() {
    withLocale { localization, _ in
      let payload = Payload(items: [
        [Representation(type: "public.utf8-plain-text", data: Data("Hello — xin chào".utf8))]
      ])
      let hash = payload.hash
      localization.selection = .vi
      XCTAssertEqual(payload.hash, hash)
      localization.selection = .en
      XCTAssertEqual(payload.hash, hash)
    }
  }
  func testAppKitMenusAndWindowTitlesUseSelectedLanguage() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftClip-Language-Review-" + UUID().uuidString)
    let model = HistoryModel(root: root)
    let app = AppDelegate(model: model)
    let menu = NSApp.mainMenu
    let windows = NSApp.windowsMenu
    let selected = Localization.shared.selection
    let saved = UserDefaults.standard.object(forKey: Localization.preferenceKey)
    let settings = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 620), styleMask: [.titled],
      backing: .buffered, defer: false)
    settings.isReleasedWhenClosed = false
    app.settingsWindow = settings
    defer {
      NSApp.mainMenu = menu
      NSApp.windowsMenu = windows
      Localization.shared.selection = selected
      if let saved {
        UserDefaults.standard.set(saved, forKey: Localization.preferenceKey)
      } else {
        UserDefaults.standard.removeObject(forKey: Localization.preferenceKey)
      }
      app.settingsWindow = nil
      settings.close()
      model.queue.sync {}
      try? FileManager.default.removeItem(at: root)
    }
    Localization.shared.selection = .en
    app.refreshLocalizedUI()
    XCTAssertEqual(settings.title, "SwiftClip Settings")
    XCTAssertEqual(NSApp.mainMenu?.items[1].title, "Edit")
    XCTAssertEqual(NSApp.mainMenu?.items.first?.submenu?.items[1].title, "Settings…")
    Localization.shared.selection = .vi
    app.refreshLocalizedUI()
    XCTAssertEqual(settings.title, "Cài đặt SwiftClip")
    XCTAssertEqual(NSApp.mainMenu?.items[1].title, "Sửa")
    XCTAssertEqual(NSApp.mainMenu?.items.first?.submenu?.items[1].title, "Cài đặt…")
  }

}
