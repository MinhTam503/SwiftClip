import AppKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

final class Repository {
  private var db: OpaquePointer?
  let root: URL
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  init(
    root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SwiftClip")
  ) throws {
    self.root = root
    for dir in ["Database", "Payloads", "Thumbnails"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(dir), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    guard
      sqlite3_open(root.appendingPathComponent("Database/clipboard.sqlite").path, &db) == SQLITE_OK
    else { throw error() }
    try exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;")
    let version = try statement("PRAGMA user_version")
    let v = sqlite3_step(version) == SQLITE_ROW ? sqlite3_column_int(version, 0) : 0
    sqlite3_finalize(version)
    guard v <= 2 else {
      throw AppError.newerDatabase
    }
    try exec(
      "CREATE TABLE IF NOT EXISTS clips(id TEXT PRIMARY KEY, kind TEXT, preview TEXT, hash TEXT UNIQUE, path TEXT, thumbnail TEXT, created REAL, updated REAL, pinned INTEGER DEFAULT 0, size INTEGER, source TEXT); CREATE INDEX IF NOT EXISTS clips_updated ON clips(updated DESC); CREATE INDEX IF NOT EXISTS clips_created ON clips(created DESC);"
    )
    if v < 2 {
      try exec("BEGIN IMMEDIATE")
      do {
        try exec("ALTER TABLE clips ADD COLUMN search TEXT DEFAULT ''")
        var afterRow: Int64 = 0
        while true {
          let rows = try statement(
            "SELECT rowid,id,preview FROM clips WHERE rowid>? ORDER BY rowid LIMIT 60")
          sqlite3_bind_int64(rows, 1, afterRow)
          var batch = [(Int64, String, String)]()
          while sqlite3_step(rows) == SQLITE_ROW {
            batch.append((sqlite3_column_int64(rows, 0), str(rows, 1), str(rows, 2).lowercased()))
          }
          sqlite3_finalize(rows)
          if batch.isEmpty { break }
          for (row, id, text) in batch {
            let update = try statement("UPDATE clips SET search=? WHERE id=?")
            bind(update, 1, text)
            bind(update, 2, id)
            do { try run(update) } catch {
              sqlite3_finalize(update)
              throw error
            }
            sqlite3_finalize(update)
            afterRow = row
          }
        }
        try exec("PRAGMA user_version=2; COMMIT;")
      } catch {
        try? exec("ROLLBACK")
        throw error
      }
    }
    try exec(
      "CREATE INDEX IF NOT EXISTS clips_order ON clips(pinned DESC,updated DESC); CREATE INDEX IF NOT EXISTS clips_path ON clips(path); CREATE INDEX IF NOT EXISTS clips_thumbnail ON clips(thumbnail)"
    )
    try cleanupOrphans()
  }
  deinit { sqlite3_close(db) }
  private func error() -> NSError {
    NSError(
      domain: "SQLite", code: Int(sqlite3_errcode(db)),
      userInfo: [NSLocalizedDescriptionKey: L10n.t(.databaseFailure, String(sqlite3_errcode(db)))])
  }
  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
  }
  private func statement(_ sql: String) throws -> OpaquePointer {
    var s: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw error() }
    return s
  }
  private func bind(_ s: OpaquePointer, _ index: Int32, _ value: String) {
    sqlite3_bind_text(s, index, value, -1, transient)
  }
  private func str(_ s: OpaquePointer, _ i: Int32) -> String {
    sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
  }
  private func run(_ s: OpaquePointer) throws {
    guard sqlite3_step(s) == SQLITE_DONE else { throw error() }
  }
  func save(
    _ payload: Payload, kind: String, preview: String, source: String, limit: Int, days: Int = 0
  ) throws {
    let hash = payload.hash
    let existing = try statement("UPDATE clips SET updated=? WHERE hash=?")
    sqlite3_bind_double(existing, 1, Date().timeIntervalSince1970)
    bind(existing, 2, hash)
    defer { sqlite3_finalize(existing) }
    try run(existing)
    if sqlite3_changes(db) > 0 {
      try cleanup(limit: limit, days: days)
      return
    }
    let id = UUID().uuidString
    let path = "Payloads/\(id).json"
    let data = try JSONEncoder().encode(payload)
    try data.write(
      to: root.appendingPathComponent(path), options: [.atomic, .completeFileProtectionUnlessOpen])
    var thumbnail = ""
    if kind == "image",
      let r = payload.items.flatMap({ $0 }).first(where: {
        $0.type == NSPasteboard.PasteboardType.png.rawValue
          || $0.type == NSPasteboard.PasteboardType.tiff.rawValue
      }), let src = CGImageSourceCreateWithData(r.data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        src, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 160,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    {
      let relative = "Thumbnails/\(id).png"
      if let dest = CGImageDestinationCreateWithURL(
        root.appendingPathComponent(relative) as CFURL, UTType.png.identifier as CFString, 1, nil)
      {
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) { thumbnail = relative }
      }
    }
    do {
      let s = try statement(
        "INSERT INTO clips(id,kind,preview,hash,path,thumbnail,created,updated,size,source,search) VALUES(?,?,?,?,?,?,?,?,?,?,?)"
      )
      defer { sqlite3_finalize(s) }
      for (i, value) in [id, kind, String(preview.prefix(240)), hash, path, thumbnail].enumerated()
      { bind(s, Int32(i + 1), value) }
      sqlite3_bind_double(s, 7, Date().timeIntervalSince1970)
      sqlite3_bind_double(s, 8, Date().timeIntervalSince1970)
      sqlite3_bind_int64(s, 9, Int64(data.count))
      bind(s, 10, source)
      bind(s, 11, preview.lowercased())
      try run(s)
    } catch {
      try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
      if !thumbnail.isEmpty {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(thumbnail))
      }
      throw error
    }
    try cleanup(limit: limit, days: days)
  }
  func list(query: String = "", offset: Int = 0, count: Int = 60) throws -> [Clip] {
    let s = try statement(
      "SELECT id,kind,preview,path,thumbnail,updated,pinned,size FROM clips WHERE instr(search,?)>0 ORDER BY pinned DESC,updated DESC LIMIT ? OFFSET ?"
    )
    defer { sqlite3_finalize(s) }
    bind(s, 1, query.lowercased())
    sqlite3_bind_int(s, 2, Int32(count))
    sqlite3_bind_int(s, 3, Int32(offset))
    var items = [Clip]()
    while true {
      let status = sqlite3_step(s)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw error() }
      let thumb = str(s, 4)
      items.append(
        Clip(
          id: str(s, 0), kind: str(s, 1), preview: str(s, 2), path: str(s, 3),
          thumbnail: thumb.isEmpty ? nil : thumb,
          date: Date(timeIntervalSince1970: sqlite3_column_double(s, 5)),
          pinned: sqlite3_column_int(s, 6) != 0, size: Int(sqlite3_column_int64(s, 7))))
    }
    return items
  }
  func payload(_ clip: Clip) throws -> Payload {
    try JSONDecoder().decode(
      Payload.self, from: Data(contentsOf: root.appendingPathComponent(clip.path)))
  }
  func pin(_ clip: Clip) throws {
    let s = try statement("UPDATE clips SET pinned=? WHERE id=?")
    defer { sqlite3_finalize(s) }
    sqlite3_bind_int(s, 1, clip.pinned ? 0 : 1)
    bind(s, 2, clip.id)
    try run(s)
  }
  func delete(_ id: String) throws {
    let s = try statement("SELECT path,thumbnail FROM clips WHERE id=?")
    bind(s, 1, id)
    var files = [String]()
    if sqlite3_step(s) == SQLITE_ROW { files = [str(s, 0), str(s, 1)] }
    sqlite3_finalize(s)
    let d = try statement("DELETE FROM clips WHERE id=?")
    defer { sqlite3_finalize(d) }
    bind(d, 1, id)
    try run(d)
    for file in files where !file.isEmpty {
      try? FileManager.default.removeItem(at: root.appendingPathComponent(file))
    }
  }
  func clear() throws {
    try exec("DELETE FROM clips; PRAGMA wal_checkpoint(TRUNCATE);")
    try cleanupOrphans()
  }
  func cleanup(limit: Int, days: Int = 0) throws {
    let s = try statement(
      "SELECT id,size,pinned,updated FROM clips ORDER BY pinned DESC,updated DESC")
    defer { sqlite3_finalize(s) }
    var count = 0
    var bytes: Int64 = 0
    var ids = [String]()
    while sqlite3_step(s) == SQLITE_ROW {
      count += 1
      bytes += sqlite3_column_int64(s, 1)
      let expired =
        days > 0
        && sqlite3_column_double(s, 3)
          < Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
      if sqlite3_column_int(s, 2) == 0
        && ((limit > 0 && count > limit) || bytes > 1_073_741_824 || expired)
      {
        ids.append(str(s, 0))
      }
    }
    for id in ids { try delete(id) }
  }
  private func cleanupOrphans() throws {
    let check = try statement("SELECT 1 FROM clips WHERE path=? OR thumbnail=? LIMIT 1")
    defer { sqlite3_finalize(check) }
    for dir in ["Payloads", "Thumbnails"] {
      let iterator = FileManager.default.enumerator(
        at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
      while let url = iterator?.nextObject() as? URL {
        let relative = dir + "/" + url.lastPathComponent
        sqlite3_reset(check)
        sqlite3_clear_bindings(check)
        bind(check, 1, relative)
        bind(check, 2, relative)
        if sqlite3_step(check) == SQLITE_DONE { try FileManager.default.removeItem(at: url) }
      }
    }
  }
}
