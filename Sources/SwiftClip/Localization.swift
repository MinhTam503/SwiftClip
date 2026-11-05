import AppKit
import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
  case system, en, vi
  var id: String { rawValue }
  var title: String {
    switch self {
    case .system: return L10n.t(.system)
    case .en: return L10n.t(.english)
    case .vi: return L10n.t(.vietnamese)
    }
  }
}

extension Notification.Name {
  static let swiftClipLanguageChanged = Notification.Name("SwiftClipLanguageChanged")
}

final class Localization: ObservableObject {
  static let shared = Localization()
  static let preferenceKey = "appLanguage"
  private let defaults: UserDefaults
  @Published var selection: AppLanguage {
    didSet {
      guard oldValue != selection else { return }
      defaults.set(selection.rawValue, forKey: Self.preferenceKey)
      NotificationCenter.default.post(name: .swiftClipLanguageChanged, object: self)
    }
  }
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    selection =
      AppLanguage(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "system") ?? .system
  }
  var languageCode: String {
    let saved =
      AppLanguage(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "system") ?? .system
    if saved != .system { return saved.rawValue }
    return Self.resolve(saved, preferred: Locale.preferredLanguages)
  }
  var locale: Locale { Locale(identifier: languageCode) }
  static func resolve(_ choice: AppLanguage, preferred: [String]) -> String {
    guard choice == .system else { return choice.rawValue }
    for item in preferred {
      let language =
        item.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        ?? ""
      if language == "en" || language == "vi" { return language }
    }
    return "en"
  }
  static var resourceBundle: Bundle {
    #if SWIFT_PACKAGE
      return .module
    #else
      return .main
    #endif
  }
  private static let bundles: [String: Bundle] = {
    var result = [String: Bundle]()
    for language in ["en", "vi"] {
      if let url = resourceBundle.url(forResource: language, withExtension: "lproj"),
        let bundle = Bundle(url: url)
      {
        result[language] = bundle
      }
    }
    return result
  }()
  static func bundle(language: String) -> Bundle { bundles[language] ?? resourceBundle }
  func error(_ error: Error, context: L10n.Key = .operationFailed) -> String {
    if let own = error as? AppError { return own.localized(using: self) }
    return text(context, arguments: [String((error as NSError).code)])
  }
  func text(_ key: L10n.Key, arguments: [CVarArg] = []) -> String {
    let code = languageCode
    let fallback = Self.bundle(language: "en").localizedString(
      forKey: key.rawValue, value: nil, table: "Localizable")
    let format = Self.bundle(language: code).localizedString(
      forKey: key.rawValue, value: fallback, table: "Localizable")
    return arguments.isEmpty
      ? format : String(format: format, locale: Locale(identifier: code), arguments: arguments)
  }
}

enum L10n {
  enum Key: String, CaseIterable {
    case shortcuts
    case appName
    case paused
    case clearHistoryHelp
    case settings
    case settingsMenu
    case settingsTitle
    case searchPlaceholder
    case clearSearch
    case emptyHistory
    case emptySearch
    case emptyHint
    case paste
    case copy
    case pin
    case unpin
    case pinned
    case preview
    case deleteItem
    case newer
    case older
    case popupKeys
    case escapeClose
    case reverseMouseScroll
    case reverseMouseScrollHint
    case mouseScrollPermission
    case mouseScrollUnavailable
    case general
    case launchAtLogin
    case openLoginSettings
    case showMenuIcon
    case startBackground
    case copyOnly
    case closeAfterSelection
    case appearance
    case system
    case light
    case dark
    case language
    case english
    case vietnamese
    case accessibilityGranted
    case accessibilityDenied
    case openAccessibility
    case accessibilityHint
    case globalShortcut
    case openClipboardValue
    case recording
    case recordShortcut
    case recordFocusSearch
    case recordPaste
    case restoreDefaults
    case shortcutHelp
    case shortcutRules
    case shortcutConflict
    case shortcutValue
    case history
    case maximumItems
    case unlimited
    case maximumCapture
    case megabytes
    case removeAfter
    case never
    case daysOne
    case daysOther
    case historyPolicy
    case clearAllAction
    case privacy
    case pauseMonitoring
    case privacyPolicy
    case ignoreApps
    case pollingInterval
    case milliseconds
    case loginEnabled
    case loginApproval
    case loginNotRegistered
    case loginNotFound
    case statusUnknown
    case openClipboard
    case quit
    case ok
    case cancel
    case clearAllTitle
    case clearAllBody
    case clearAllConfirm
    case benchmarkName
    case benchmarkTip
    case editMenu
    case undo
    case redo
    case cut
    case selectAll
    case windowMenu
    case minimize
    case bringAllFront
    case contentText
    case contentImage
    case contentURL
    case contentFile
    case contentRich
    case contentOther
    case justNow
    case minutesOne
    case minutesOther
    case hoursOne
    case hoursOther
    case daysAgoOne
    case daysAgoOther
    case clipboardWriteFailed
    case pasteManual
    case pastePermission
    case pasteSecure
    case pasteActivationFailed
    case pasteFocusLost
    case pasteInappropriate
    case pasteEventFailed
    case invalidShortcut
    case shortcutUnavailable
    case databaseNewer
    case databaseFailure
    case databaseOpenFailed
    case payloadUnavailable
    case operationFailed
  }
  static func t(_ key: Key, _ arguments: CVarArg...) -> String {
    Localization.shared.text(key, arguments: arguments)
  }
  static func number(_ value: Int) -> String {
    value.formatted(.number.locale(Localization.shared.locale))
  }
  static func quantity(_ count: Int, one: Key, other: Key) -> String {
    t(count == 1 ? one : other, count)
  }
  static func contentKind(_ kind: String) -> String {
    switch kind {
    case "text": return t(.contentText)
    case "image": return t(.contentImage)
    case "url": return t(.contentURL)
    case "file": return t(.contentFile)
    case "rich text": return t(.contentRich)
    default: return t(.contentOther)
    }
  }
  static func preview(_ clip: Clip) -> String {
    // Compatibility with generic preview metadata written before localization.
    // Actual clipboard payloads are never translated or rewritten.
    if clip.preview.isEmpty || (clip.kind == "image" && clip.preview == "Image")
      || (clip.kind == "rich text" && clip.preview == "Rich content")
    {
      return contentKind(clip.kind)
    }
    return clip.preview
  }
  static func error(_ error: Error, context: Key = .operationFailed) -> String {
    Localization.shared.error(error, context: context)
  }
}

enum AppError: LocalizedError {
  case invalidShortcut
  case shortcutUnavailable(Int)
  case newerDatabase
  var errorDescription: String? { localized(using: .shared) }
  func localized(using localization: Localization) -> String {
    switch self {
    case .invalidShortcut: return localization.text(.invalidShortcut)
    case .shortcutUnavailable(let code):
      return localization.text(.shortcutUnavailable, arguments: [String(code)])
    case .newerDatabase: return localization.text(.databaseNewer)
    }
  }
}

enum AppNotice {
  case message(L10n.Key)
  case error(Error, L10n.Key)
  var text: String { localized(using: .shared) }
  func localized(using localization: Localization) -> String {
    switch self {
    case .message(let key): return localization.text(key)
    case .error(let error, let context): return localization.error(error, context: context)
    }
  }
}
