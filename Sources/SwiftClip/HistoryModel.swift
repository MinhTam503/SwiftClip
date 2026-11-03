import AppKit
import SwiftUI

final class HistoryModel: ObservableObject {
  @Published var clips = [Clip]()
  @Published var query = ""
  @Published var selected: String?
  @Published var notice: AppNotice?
  var message: String { notice?.text ?? "" }
  @Published var hasMore = false
  @Published var pageOffset = 0
  @Published private(set) var openedAt = Date()
  var onRowsChanged: (() -> Void)?
  func beginPresentation(at date: Date = Date()) { openedAt = date }
  let queue = DispatchQueue(label: "com.personal.swiftclip.storage", qos: .utility)
  private var repository: Repository?
  private var generation = 0
  private var searchWork: DispatchWorkItem?
  var onChange: (() -> Void)?
  init(root: URL? = nil) {
    queue.async { [weak self] in
      do {
        let repo = try root.map { try Repository(root: $0) } ?? Repository()
        self?.repository = repo
      } catch {
        DispatchQueue.main.async {
          self?.notice = .error(error, .databaseOpenFailed)
        }
      }
    }
  }
  func save(_ payload: Payload, kind: String, preview: String, source: String) {
    let limit = Settings.shared.limit
    let days = Settings.shared.int("days", 0)
    perform { repo in
      try repo.save(payload, kind: kind, preview: preview, source: source, limit: limit, days: days)
    }
  }
  func perform(_ operation: @escaping (Repository) throws -> Void) {
    queue.async { [weak self] in
      guard let self, let repo = self.repository else { return }
      do {
        try operation(repo)
        DispatchQueue.main.async { self.onChange?() }
      } catch { DispatchQueue.main.async { self.notice = .error(error, .operationFailed) } }
    }
  }
  func search() {
    searchWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.load() }
    searchWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }
  func load(more: Bool = false, previous: Bool = false) {
    generation += 1
    let token = generation
    let q = query
    let offset = more ? pageOffset + 60 : previous ? max(0, pageOffset - 60) : 0
    queue.async { [weak self] in
      guard let self, let repo = self.repository else { return }
      do {
        let rows = try repo.list(query: q, offset: offset)
        DispatchQueue.main.async {
          guard token == self.generation else { return }
          self.clips = rows
          self.pageOffset = offset
          self.hasMore = rows.count == 60
          self.onRowsChanged?()
          if !self.clips.contains(where: { $0.id == self.selected }) {
            self.selected = self.clips.first?.id
          }
        }
      } catch { DispatchQueue.main.async { self.notice = .error(error, .operationFailed) } }
    }
  }
  func release() {
    generation += 1
    searchWork?.cancel()
    clips = []
    hasMore = false
    pageOffset = 0
    query = ""
  }
  func payload(_ clip: Clip, completion: @escaping (Payload) -> Void) {
    queue.async { [weak self] in
      do {
        guard let payload = try self?.repository?.payload(clip) else { return }
        DispatchQueue.main.async { completion(payload) }
      } catch {
        DispatchQueue.main.async {
          self?.notice = .error(error, .payloadUnavailable)
        }
      }
    }
  }
  func move(_ delta: Int) {
    guard !clips.isEmpty else { return }
    let i = clips.firstIndex { $0.id == selected } ?? 0
    selected = clips[max(0, min(clips.count - 1, i + delta))].id
  }
}
