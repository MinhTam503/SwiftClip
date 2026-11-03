import AppKit
import Carbon
import SQLite3
import SwiftUI
import XCTest

@testable import SwiftClip

final class SwiftClipTests: XCTestCase {
  func payload(_ value: String) -> Payload {
    Payload(items: [
      [Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))]
    ])
  }
  func withRepository(_ body: (Repository, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(Repository(root: root), root)
  }
  func testHistoryPathsRejectTraversalAndSymlinks() throws {
    try withRepository { repo, root in
      let outside = root.deletingLastPathComponent().appendingPathComponent(
        UUID().uuidString + ".json")
      try Data("synthetic outside file".utf8).write(to: outside)
      defer { try? FileManager.default.removeItem(at: outside) }
      let link = root.appendingPathComponent("Payloads/link.json")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
      for path in [
        "../" + outside.lastPathComponent, outside.path, "Payloads/../outside.json",
        "Payloads/link.json",
      ] {
        let clip = Clip(
          id: "test", kind: "text", preview: "", path: path,
          thumbnail: nil, date: Date(), pinned: false, size: 0)
        XCTAssertThrowsError(try repo.payload(clip))
      }
      try repo.save(payload("safe"), kind: "text", preview: "safe", source: "test", limit: 0)
      let clip = try XCTUnwrap(repo.list().first)
      var db: OpaquePointer?
      XCTAssertEqual(
        sqlite3_open(root.appendingPathComponent("Database/clipboard.sqlite").path, &db), SQLITE_OK)
      defer { sqlite3_close(db) }
      XCTAssertEqual(
        sqlite3_exec(db, "UPDATE clips SET path='Payloads/link.json'", nil, nil, nil), SQLITE_OK)
      XCTAssertThrowsError(try repo.delete(clip.id))
      XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
  }

  func testPrivatePermissionsAndClearRemovesSearchText() throws {
    try withRepository { repo, root in
      let marker = "synthetic-deletion-marker-" + UUID().uuidString
      try repo.save(payload(marker), kind: "text", preview: marker, source: "test", limit: 0)
      let clip = try XCTUnwrap(repo.list().first)
      for (path, expected) in [
        (root.path, 0o700),
        (root.appendingPathComponent("Database").path, 0o700),
        (root.appendingPathComponent(clip.path).path, 0o600),
      ] {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, expected)
      }
      try repo.clear()
      let database = try Data(contentsOf: root.appendingPathComponent("Database/clipboard.sqlite"))
      XCTAssertNil(database.range(of: Data(marker.utf8)))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.path).path))
    }
  }

  func testSymlinkedStoreIsRejected() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("store")
    let outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Payloads"), withDestinationURL: outside)
    XCTAssertThrowsError(try Repository(root: root))
  }

  func testHashAndRepresentationOrder() {
    XCTAssertEqual(payload("abc").hash, payload("abc").hash)
    XCTAssertNotEqual(payload("abc").hash, payload("ABC").hash)
    let a = Representation(type: "a", data: Data([1]))
    let b = Representation(type: "b", data: Data([2]))
    XCTAssertEqual(Payload(items: [[a, b]]).hash, Payload(items: [[b, a]]).hash)
    XCTAssertNotEqual(Payload(items: [[a, b]]).hash, Payload(items: [[b], [a]]).hash)
  }
  func testDetector() {
    XCTAssertEqual(ClipboardReader.kind([NSPasteboard.PasteboardType.fileURL.rawValue]), "file")
    XCTAssertEqual(
      ClipboardReader.kind([
        NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue,
      ]), "image")
    XCTAssertEqual(ClipboardReader.kind([NSPasteboard.PasteboardType.URL.rawValue]), "url")
    XCTAssertEqual(ClipboardReader.kind([NSPasteboard.PasteboardType.rtf.rawValue]), "rich text")
  }
  func testDatabaseDuplicateSearchLimitPinRestartAndDelete() throws {
    try withRepository { repo, root in
      try repo.save(payload("First"), kind: "text", preview: "First", source: "test", limit: 2)
      try repo.save(payload("Second"), kind: "text", preview: "Second", source: "test", limit: 2)
      try repo.save(payload("First"), kind: "text", preview: "First", source: "test", limit: 2)
      XCTAssertEqual(try repo.list().count, 2)
      XCTAssertEqual(try repo.list().first?.preview, "First")
      XCTAssertEqual(try repo.list(query: "fIrSt").count, 1)
      XCTAssertEqual(try repo.list(query: "%").count, 0)
      let first = try XCTUnwrap(repo.list().first)
      try repo.pin(first)
      try repo.save(payload("Third"), kind: "text", preview: "Third", source: "test", limit: 2)
      XCTAssertEqual(try repo.list().count, 2)
      XCTAssertTrue(try repo.list().first!.pinned)
      let reopened = try Repository(root: root)
      XCTAssertEqual(try reopened.list().count, 2)
      XCTAssertEqual(try reopened.payload(first).hash, payload("First").hash)
      try repo.delete(first.id)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent(first.path).path))
      try repo.clear()
      XCTAssertEqual(try repo.list().count, 0)
    }
  }
  func testPaginationAndOrphanCleanup() throws {
    try withRepository { repo, root in
      for n in 0..<70 {
        try repo.save(
          payload("item \(n)"), kind: "text", preview: "item \(n)", source: "test", limit: 0)
      }
      XCTAssertEqual(try repo.list().count, 60)
      XCTAssertEqual(try repo.list(offset: 60).count, 10)
      let orphan = root.appendingPathComponent("Payloads/orphan.json")
      try Data([1]).write(to: orphan)
      _ = try Repository(root: root)
      XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
  }
  func testClipboardRoundTripPrivacyAndSizeLimit() throws {
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    XCTAssertTrue(PasteManager.write(payload("hello"), to: pb))
    let captured = try XCTUnwrap(ClipboardReader.read(pb, maxBytes: 1000))
    XCTAssertEqual(captured.2, "hello")
    XCTAssertEqual(captured.0.hash, payload("hello").hash)
    XCTAssertNil(ClipboardReader.read(pb, maxBytes: 1))
    for forbidden in ClipboardReader.forbidden {
      pb.clearContents()
      let item = NSPasteboardItem()
      item.setString("secret", forType: .string)
      item.setData(Data(), forType: .init(forbidden))
      pb.writeObjects([item])
      XCTAssertNil(ClipboardReader.read(pb, maxBytes: 1000))
    }
  }
  func testImageURLAndFilePersistence() throws {
    try withRepository { repo, root in
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      )!
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      let pb = NSPasteboard.withUniqueName()
      defer { pb.releaseGlobally() }
      let image = Payload(items: [
        [Representation(type: NSPasteboard.PasteboardType.png.rawValue, data: png)]
      ])
      XCTAssertTrue(PasteManager.write(image, to: pb))
      let captured = try XCTUnwrap(ClipboardReader.read(pb, maxBytes: 100000))
      try repo.save(captured.0, kind: captured.1, preview: captured.2, source: "test", limit: 500)
      let clip = try XCTUnwrap(repo.list().first)
      let thumbnail = try XCTUnwrap(clip.thumbnail)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: root.appendingPathComponent(thumbnail).path))
      XCTAssertEqual(try repo.payload(clip).hash, image.hash)
      try repo.delete(clip.id)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent(thumbnail).path))
      for type in [NSPasteboard.PasteboardType.URL, .fileURL] {
        let value = type == .URL ? "https://example.com" : "file:///tmp/example.txt"
        let p = Payload(items: [[Representation(type: type.rawValue, data: Data(value.utf8))]])
        XCTAssertTrue(PasteManager.write(p, to: pb))
        XCTAssertNotNil(ClipboardReader.read(pb, maxBytes: 1000))
      }
    }
  }
  func testHotkeyValidation() {
    XCTAssertTrue(Settings.validShortcut(key: 9, modifiers: UInt32(cmdKey | shiftKey)))
    XCTAssertFalse(Settings.validShortcut(key: 9, modifiers: UInt32(shiftKey)))
    XCTAssertFalse(Settings.validShortcut(key: 999, modifiers: UInt32(cmdKey)))
  }
  func testUnicodeFullSearchAndMissingPayload() throws {
    try withRepository { repo, root in
      let text = String(repeating: "prefix ", count: 100) + "ĐƯỜNG DẪN TỆP"
      try repo.save(payload(text), kind: "text", preview: text, source: "test", limit: 100)
      let clip = try XCTUnwrap(repo.list(query: "đường dẫn tệp").first)
      XCTAssertLessThanOrEqual(clip.preview.count, 240)
      try FileManager.default.removeItem(at: root.appendingPathComponent(clip.path))
      XCTAssertThrowsError(try repo.payload(clip))
    }
  }
  func testFutureSchemaRejectedAndMigrationVersion() throws {
    try withRepository { _, root in
      var db: OpaquePointer?
      XCTAssertEqual(
        sqlite3_open(root.appendingPathComponent("Database/clipboard.sqlite").path, &db), SQLITE_OK)
      defer { sqlite3_close(db) }
      var statement: OpaquePointer?
      sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
      XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
      XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
      sqlite3_finalize(statement)
      sqlite3_exec(db, "PRAGMA user_version=999", nil, nil, nil)
      XCTAssertThrowsError(try Repository(root: root))
    }
  }
  func testRichTextRepresentationsPreserved() throws {
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    let rtf = Data("{\\rtf1\\ansi Formatted text}".utf8)
    let payload = Payload(items: [
      [
        Representation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf),
        Representation(
          type: NSPasteboard.PasteboardType.string.rawValue, data: Data("Formatted text".utf8)),
      ]
    ])
    XCTAssertTrue(PasteManager.write(payload, to: pb))
    let captured = try XCTUnwrap(ClipboardReader.read(pb, maxBytes: 10000))
    XCTAssertEqual(captured.0.hash, payload.hash)
    XCTAssertEqual(pb.data(forType: .rtf), rtf)
  }

  func testMonitorDetectsChangesAndIgnoresOwnWrites() {
    let suite = "SwiftClipTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = Settings(defaults: defaults)
    settings.set("poll", 250)
    let monitor = ClipboardMonitor(settings: settings, sourceApp: { "test.app" })
    let pb = NSPasteboard.withUniqueName()
    defer {
      monitor.stop()
      pb.releaseGlobally()
    }
    let found = expectation(description: "timer captures new clipboard")
    monitor.captured = { p, kind, preview, source in
      XCTAssertEqual(preview, "monitored")
      XCTAssertEqual(kind, "text")
      XCTAssertEqual(source, "test.app")
      XCTAssertEqual(p.hash, self.payload("monitored").hash)
      found.fulfill()
    }
    monitor.start(pasteboard: pb)
    _ = PasteManager.write(payload("monitored"), to: pb)
    wait(for: [found], timeout: 2)
    let absent = expectation(description: "self write suppressed")
    absent.isInverted = true
    monitor.captured = { _, _, _, _ in absent.fulfill() }
    _ = PasteManager.write(payload("own write"), to: pb)
    monitor.suppressCurrent()
    wait(for: [absent], timeout: 0.4)
    let ignored = expectation(description: "ignored source suppressed")
    ignored.isInverted = true
    monitor.captured = { _, _, _, _ in ignored.fulfill() }
    settings.set("ignored", "test.app")
    _ = PasteManager.write(payload("ignored"), to: pb)
    wait(for: [ignored], timeout: 0.4)
    let paused = expectation(description: "paused monitoring suppresses capture")
    paused.isInverted = true
    monitor.captured = { _, _, _, _ in paused.fulfill() }
    settings.set("ignored", "")
    settings.set("paused", true)
    _ = PasteManager.write(payload("paused"), to: pb)
    wait(for: [paused], timeout: 0.4)
  }
  func testActualCarbonRegistrationConflict() throws {
    let first = HotkeyManager()
    let second = HotkeyManager()
    let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    try first.register(key: 79, modifiers: modifiers)
    try first.register(key: 79, modifiers: modifiers)
    XCTAssertThrowsError(try second.register(key: 79, modifiers: modifiers))
  }
  func testVersionOneMigrationPreservesHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Database"), withIntermediateDirectories: true)
    var db: OpaquePointer?
    sqlite3_open(root.appendingPathComponent("Database/clipboard.sqlite").path, &db)
    let sql =
      "CREATE TABLE clips(id TEXT PRIMARY KEY, kind TEXT, preview TEXT, hash TEXT UNIQUE, path TEXT, thumbnail TEXT, created REAL, updated REAL, pinned INTEGER DEFAULT 0, size INTEGER, source TEXT); INSERT INTO clips VALUES('old','text','ĐƯỜNG','hash','Payloads/old.json','',0,0,0,0,'test'); PRAGMA user_version=1;"
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    let repo = try Repository(root: root)
    XCTAssertEqual(try repo.list(query: "đường").first?.id, "old")
  }

  func testAgeAndDiskQuotaRetentionPreservePins() throws {
    try withRepository { repo, root in
      try repo.save(payload("pinned"), kind: "text", preview: "pinned", source: "test", limit: 0)
      let pinned = try XCTUnwrap(repo.list().first)
      try repo.pin(pinned)
      try repo.save(payload("old"), kind: "text", preview: "old", source: "test", limit: 0)
      var db: OpaquePointer?
      XCTAssertEqual(
        sqlite3_open(root.appendingPathComponent("Database/clipboard.sqlite").path, &db), SQLITE_OK)
      defer { sqlite3_close(db) }
      XCTAssertEqual(
        sqlite3_exec(db, "UPDATE clips SET updated=0 WHERE pinned=0", nil, nil, nil), SQLITE_OK)
      try repo.cleanup(limit: 0, days: 7)
      XCTAssertEqual(try repo.list().map(\.id), [pinned.id])
      try repo.save(payload("large"), kind: "text", preview: "large", source: "test", limit: 0)
      XCTAssertEqual(
        sqlite3_exec(db, "UPDATE clips SET size=1073741825 WHERE pinned=0", nil, nil, nil),
        SQLITE_OK)
      try repo.cleanup(limit: 0)
      XCTAssertEqual(try repo.list().map(\.id), [pinned.id])
    }
  }

  func testPopupShortcutProtectsSearchAndNavigation() {
    XCTAssertTrue(PopupShortcut.valid(key: 36, flags: [], search: false))
    XCTAssertTrue(PopupShortcut.valid(key: 36, flags: .command, search: false))
    XCTAssertTrue(PopupShortcut.valid(key: 3, flags: [.command, .capsLock], search: true))
    XCTAssertFalse(PopupShortcut.valid(key: 0, flags: [], search: false))
    XCTAssertFalse(PopupShortcut.valid(key: 3, flags: .shift, search: true))
    XCTAssertFalse(PopupShortcut.valid(key: 53, flags: .command, search: false))
    XCTAssertFalse(PopupShortcut.valid(key: 51, flags: .command, search: true))
  }

  func testPasteWithoutWebAccessibilityMetadataStillSendsOneCommandV() {
    var probes = 0
    var pastes = 0
    var completions = 0
    let session = PasteSession(
      dependencies: .init(
        trusted: { true }, frontmost: { true }, secureInput: { false },
        inspectFocus: { done in
          probes += 1
          done(.unavailable)
        },
        sendPaste: {
          pastes += 1
          return true
        }, schedule: { $0() }
      )
    ) { message in
      XCTAssertNil(message)
      completions += 1
    }
    session.start()
    XCTAssertEqual(probes, 4)
    XCTAssertEqual(pastes, 1)
    XCTAssertEqual(completions, 1)
  }
  func testPasteRetriesTransientFocusAndStopsWhenReady() {
    var probes = 0
    var pastes = 0
    let session = PasteSession(
      dependencies: .init(
        trusted: { true }, frontmost: { true }, secureInput: { false },
        inspectFocus: { done in
          probes += 1
          done(probes == 1 ? .unavailable : .available)
        },
        sendPaste: {
          pastes += 1
          return true
        }, schedule: { $0() }
      )
    ) { XCTAssertNil($0) }
    session.start()
    XCTAssertEqual(probes, 2)
    XCTAssertEqual(pastes, 1)
  }
  func testPasteBlocksSecureControlsPermissionsAndLostFocus() {
    for focus in [PasteFocus.secure, .blocked, .permissionDenied] {
      var pastes = 0
      let session = PasteSession(
        dependencies: .init(
          trusted: { true }, frontmost: { true }, secureInput: { false },
          inspectFocus: { $0(focus) },
          sendPaste: {
            pastes += 1
            return true
          }, schedule: { $0() }
        )
      ) { XCTAssertNotNil($0) }
      session.start()
      XCTAssertEqual(pastes, 0)
    }
    for trusted in [false, true] {
      var frontmost = true
      var secure = false
      var pastes = 0
      let session = PasteSession(
        dependencies: .init(
          trusted: { trusted }, frontmost: { frontmost }, secureInput: { secure },
          inspectFocus: { done in
            frontmost = false
            secure = true
            done(.available)
          },
          sendPaste: {
            pastes += 1
            return true
          }, schedule: { $0() }
        )
      ) { XCTAssertNotNil($0) }
      session.start()
      XCTAssertEqual(pastes, 0)
    }
  }
  func testPasteRechecksSecureInputAfterAsyncProbe() {
    var secure = false
    var pastes = 0
    let session = PasteSession(
      dependencies: .init(
        trusted: { true }, frontmost: { true }, secureInput: { secure },
        inspectFocus: { done in
          secure = true
          done(.available)
        },
        sendPaste: {
          pastes += 1
          return true
        }, schedule: { $0() }
      )
    ) { XCTAssertNotNil($0) }
    session.start()
    XCTAssertEqual(pastes, 0)
  }

  func testPasteDoesNotSendWhenPermissionRevokedDuringFocusProbe() {
    var trusted = true
    var pastes = 0
    let session = PasteSession(
      dependencies: .init(
        trusted: { trusted }, frontmost: { true }, secureInput: { false },
        inspectFocus: { done in
          trusted = false
          done(.unavailable)
        },
        sendPaste: {
          pastes += 1
          return true
        }, schedule: { $0() }
      )
    ) { XCTAssertNotNil($0) }
    session.start()
    XCTAssertEqual(pastes, 0)
  }
  func testPasteActivationTimeoutIsBoundedAndDoesNotProbeOrSend() {
    var probes = 0
    var pastes = 0
    var schedules = 0
    var completions = 0
    let session = PasteSession(
      dependencies: .init(
        trusted: { true }, frontmost: { false }, secureInput: { false },
        inspectFocus: { done in
          probes += 1
          done(.available)
        },
        sendPaste: {
          pastes += 1
          return true
        },
        schedule: {
          schedules += 1
          $0()
        }
      )
    ) { message in
      XCTAssertNotNil(message)
      completions += 1
    }
    session.start()
    XCTAssertEqual(probes, 0)
    XCTAssertEqual(pastes, 0)
    XCTAssertEqual(schedules, 11)
    XCTAssertEqual(completions, 1)
  }

  func testPopupAvoidsFocusedEditorAndStaysOnScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let field = NSRect(x: 300, y: 380, width: 800, height: 60)
    let size = PopupLayout.size(count: 2, navigation: false, message: false, screen: screen)
    let frame = PopupLayout.frame(
      size: size, screen: screen, pointer: NSPoint(x: 700, y: 410), avoiding: field)
    XCTAssertFalse(frame.intersects(field))
    XCTAssertTrue(screen.contains(frame))
    XCTAssertLessThan(frame.height, 300)
  }
  func testPopupFindsSpaceBelowTopEdgeAndOnNegativeCoordinateMonitor() {
    for screen in [
      NSRect(x: 0, y: 0, width: 1440, height: 900),
      NSRect(x: -1440, y: -200, width: 1440, height: 900),
    ] {
      let field = NSRect(x: screen.minX + 300, y: screen.maxY - 90, width: 800, height: 50)
      let size = PopupLayout.size(count: 6, navigation: true, message: false, screen: screen)
      let frame = PopupLayout.frame(
        size: size, screen: screen, pointer: NSPoint(x: field.midX, y: field.midY), avoiding: field)
      XCTAssertFalse(frame.intersects(field))
      XCTAssertTrue(screen.contains(frame))
      XCTAssertLessThan(frame.maxY, field.minY)
    }
  }
  func testPopupPointerFallbackAndSmallScreenAreBounded() {
    let screen = NSRect(x: 0, y: 0, width: 1024, height: 768)
    let pointer = NSPoint(x: 500, y: 380)
    let frame = PopupLayout.frame(
      size: PopupLayout.size(count: 1, navigation: false, message: false, screen: screen),
      screen: screen, pointer: pointer, avoiding: nil)
    XCTAssertFalse(frame.contains(pointer))
    XCTAssertTrue(screen.contains(frame))
    let small = NSRect(x: 0, y: 0, width: 320, height: 240)
    let compact = PopupLayout.frame(
      size: PopupLayout.size(count: 1000, navigation: true, message: true, screen: small),
      screen: small, pointer: .zero, avoiding: small)
    XCTAssertTrue(small.contains(compact))
  }
  func testPopupHeightDoesNotGrowWithUnlimitedHistory() {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    XCTAssertEqual(
      PopupLayout.size(count: 60, navigation: true, message: false, screen: screen),
      PopupLayout.size(count: 100000, navigation: true, message: false, screen: screen))
    XCTAssertLessThan(
      PopupLayout.size(count: 0, navigation: false, message: false, screen: screen).height, 250)
  }
  func testTimestampUsesExplicitPopupSnapshot() {
    let suite = "SwiftClipTests.Localization." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let localization = Localization(defaults: defaults)
    localization.selection = .vi
    let copied = Date(timeIntervalSince1970: 10000)
    let opened = copied.addingTimeInterval(125)
    XCTAssertEqual(
      ClipboardTimestamp.label(copied, relativeTo: opened, localization: localization),
      "2 phút trước")
    XCTAssertEqual(
      ClipboardTimestamp.label(copied, relativeTo: opened, localization: localization),
      "2 phút trước")
    XCTAssertEqual(
      ClipboardTimestamp.label(
        copied, relativeTo: copied.addingTimeInterval(3600), localization: localization),
      "1 giờ trước")
    XCTAssertEqual(
      ClipboardTimestamp.label(
        copied, relativeTo: copied.addingTimeInterval(-10), localization: localization), "Vừa xong")
  }

  func testFirstPasteWaitsForPanelFocusReleaseAndSettling() {
    var released = false
    var probes = 0
    var sends = 0
    var completions = 0
    var pending = [() -> Void]()
    let session = PasteSession(
      dependencies: .init(
        trusted: { true }, frontmost: { true }, secureInput: { false },
        inspectFocus: { done in
          probes += 1
          done(.available)
        },
        sendPaste: {
          sends += 1
          return true
        }, schedule: { pending.append($0) },
        inputFocusReleased: { released }
      )
    ) { message in
      XCTAssertNil(message)
      completions += 1
    }
    session.start()
    pending.removeFirst()()
    XCTAssertEqual(probes, 0)
    XCTAssertEqual(sends, 0)
    released = true
    pending.removeFirst()()
    XCTAssertEqual(probes, 0)
    XCTAssertEqual(sends, 0)
    pending.removeFirst()()
    XCTAssertEqual(sends, 1)
    XCTAssertEqual(completions, 1)
  }
  func testPasteAbortsIfPopupStealsFocusDuringProbe() {
    var released = true
    var sends = 0
    let session = PasteSession(
      dependencies: .init(
        trusted: { true }, frontmost: { true }, secureInput: { false },
        inspectFocus: { done in
          released = false
          done(.available)
        },
        sendPaste: {
          sends += 1
          return true
        }, schedule: { $0() },
        inputFocusReleased: { released }
      )
    ) { XCTAssertNotNil($0) }
    session.start()
    XCTAssertEqual(sends, 0)
  }
  func testClearConfirmationKeepsPopupOpenOnCancelAndConfirm() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = HistoryModel(root: root)
    let app = AppDelegate(model: model)
    let panel = ClipboardPanel(clipboardRect: NSRect(x: 0, y: 0, width: 420, height: 300))
    panel.isReleasedWhenClosed = false
    panel.delegate = app
    app.panel = panel
    defer {
      app.close()
      model.queue.sync {}
      try? FileManager.default.removeItem(at: root)
    }
    model.save(
      payload("synthetic history"), kind: "text", preview: "synthetic history", source: "test")
    model.queue.sync {}
    for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn] {
      app.clearHistory()
      XCTAssertTrue(app.historyConfirmationInFlight)
      let sheet = try XCTUnwrap(panel.attachedSheet)
      app.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
      XCTAssertTrue(app.panel === panel)
      panel.endSheet(sheet, returnCode: response)
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))
      XCTAssertFalse(app.historyConfirmationInFlight)
      XCTAssertTrue(app.panel === panel)
      model.queue.sync {}
      let repo = try Repository(root: root)
      XCTAssertEqual(try repo.list().count, response == .alertFirstButtonReturn ? 1 : 0)
    }
  }

  func testDraggedPopupKeepsTopEdgeWhenHistoryHeightChanges() {
    let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
    let previous = NSRect(x: -1000, y: 400, width: 420, height: 400)
    let smaller = PopupLayout.draggedFrame(
      size: NSSize(width: 420, height: 220), previous: previous, screen: screen)
    XCTAssertEqual(smaller.minX, previous.minX)
    XCTAssertEqual(smaller.maxY, previous.maxY)
    let edge = PopupLayout.draggedFrame(
      size: NSSize(width: 420, height: 460),
      previous: NSRect(x: -100, y: -300, width: 420, height: 220), screen: screen)
    XCTAssertTrue(screen.contains(edge))
  }

  func testClipboardPanelDoesNotActivateOwnerAndAcceptsFirstClick() {
    _ = NSApplication.shared
    let panel = ClipboardPanel(clipboardRect: NSRect(x: 0, y: 0, width: 420, height: 220))
    panel.isReleasedWhenClosed = false
    defer { panel.close() }
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.canBecomeKey)
    let view = ClipboardHostingView(rootView: SwiftUI.Text("Clipboard test"))
    XCTAssertTrue(view.acceptsFirstMouse(for: nil))
  }

}
