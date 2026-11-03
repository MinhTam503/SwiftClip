import AppKit
import ApplicationServices
import Carbon

final class ClipboardMonitor {
  private var timer: Timer?
  private let settings: Settings
  private let sourceApp: () -> String
  init(
    settings: Settings = .shared,
    sourceApp: @escaping () -> String = {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    }
  ) {
    self.settings = settings
    self.sourceApp = sourceApp
  }
  private var count = NSPasteboard.general.changeCount
  private var pasteboard: NSPasteboard = .general
  var captured: ((Payload, String, String, String) -> Void)?
  func start(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
    count = pasteboard.changeCount
    timer?.invalidate()
    let interval = Double(settings.int("poll", 500)) / 1000
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      self?.poll()
    }
    timer?.tolerance = interval * 0.2
  }
  func stop() {
    timer?.invalidate()
    timer = nil
  }
  func suppressCurrent() { count = pasteboard.changeCount }
  private func poll() {
    let pb = pasteboard
    let observed = pb.changeCount
    guard observed != count else { return }
    count = observed
    guard !settings.bool("paused"), !IsSecureEventInputEnabled() else { return }
    let source = sourceApp()
    let ignored = settings.string("ignored").split(whereSeparator: { $0 == "\n" || $0 == "," }).map
    { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard !ignored.contains(source), !source.isEmpty else { return }
    if let (payload, kind, preview) = ClipboardReader.read(pb, maxBytes: settings.maxBytes),
      pb.changeCount == observed
    {
      captured?(payload, kind, preview, source)
    }
  }
  deinit { timer?.invalidate() }
}
final class HotkeyManager {
  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var configuration: (UInt32, UInt32)?
  var action: (() -> Void)?
  init() {
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, data in
        guard let data else { return noErr }
        Unmanaged<HotkeyManager>.fromOpaque(data).takeUnretainedValue().action?()
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }
  func register(key: UInt32, modifiers: UInt32) throws {
    guard Settings.validShortcut(key: key, modifiers: modifiers) else {
      throw AppError.invalidShortcut
    }
    if let configuration, configuration.0 == key, configuration.1 == modifiers { return }
    var next: EventHotKeyRef?
    let status = RegisterEventHotKey(
      key, modifiers, EventHotKeyID(signature: 0x5357_434C, id: 1), GetApplicationEventTarget(), 0,
      &next)
    guard status == noErr else {
      throw AppError.shortcutUnavailable(Int(status))
    }
    if let reference { UnregisterEventHotKey(reference) }
    reference = next
    configuration = (key, modifiers)
  }
  deinit {
    if let reference { UnregisterEventHotKey(reference) }
    if let handler { RemoveEventHandler(handler) }
  }
}
enum PasteManager {
  static func write(_ payload: Payload, to pb: NSPasteboard = .general) -> Bool {
    let objects = payload.items.map { reps -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for r in reps { item.setData(r.data, forType: .init(r.type)) }
      return item
    }
    guard !objects.isEmpty else { return false }
    pb.clearContents()
    return pb.writeObjects(objects)
  }
  static var trusted: Bool { AXIsProcessTrusted() }
  static func openAccessibility() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }
  static func paste(into app: NSRunningApplication, completion: @escaping (String?) -> Void) {
    guard trusted else {
      completion(
        L10n.t(.pastePermission)
      )
      return
    }
    let pid = app.processIdentifier
    let session = PasteSession(
      dependencies: .init(
        trusted: { trusted },
        frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
        secureInput: { IsSecureEventInputEnabled() },
        inspectFocus: { completion in
          focusQueue.async {
            let state = inspectFocus(pid: pid)
            DispatchQueue.main.async { completion(state) }
          }
        },
        sendPaste: { sendCommandV() },
        schedule: { action in
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: action)
        },
        inputFocusReleased: { NSApp.keyWindow?.isVisible != true }
      ), completion: completion)
    if !app.isActive { app.activate(options: [.activateIgnoringOtherApps]) }
    session.start()
  }

  private static let focusQueue = DispatchQueue(
    label: "com.personal.swiftclip.paste-focus", qos: .userInitiated)

  private static func inspectFocus(pid: pid_t) -> PasteFocus {
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 0.1)
    var focused: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      axApp, kAXFocusedUIElementAttribute as CFString, &focused)
    if result == .apiDisabled { return .permissionDenied }
    guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
      return .unavailable
    }
    let element = unsafeBitCast(focused, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(element, 0.1)
    var role: CFTypeRef?
    var subrole: CFTypeRef?
    let subroleResult = AXUIElementCopyAttributeValue(
      element, kAXSubroleAttribute as CFString, &subrole)
    let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    if subroleResult == .apiDisabled || roleResult == .apiDisabled { return .permissionDenied }
    if (subrole as? String) == kAXSecureTextFieldSubrole { return .secure }
    let inappropriate = [
      kAXButtonRole, kAXCheckBoxRole, kAXMenuItemRole, kAXMenuBarRole, kAXToolbarRole,
    ]
    if let role = role as? String, inappropriate.contains(role) { return .blocked }
    return .available
  }

  private static func sendCommandV() -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }
}

enum PasteFocus { case available, unavailable, secure, blocked, permissionDenied }

/// AX metadata is best-effort. Native Command-V does not require an AX text element.
/// Every asynchronous probe is followed by a fresh foreground/permission/secure-input check.
final class PasteSession {
  struct Dependencies {
    var trusted: () -> Bool
    var frontmost: () -> Bool
    var secureInput: () -> Bool
    var inspectFocus: (@escaping (PasteFocus) -> Void) -> Void
    var sendPaste: () -> Bool
    var schedule: (@escaping () -> Void) -> Void
    var inputFocusReleased: () -> Bool = { true }
  }
  private let dependencies: Dependencies
  private let completion: (String?) -> Void
  private var activationRetries = 10
  private var focusRetries = 3
  private var finished = false
  private var focusSettled = false
  init(dependencies: Dependencies, completion: @escaping (String?) -> Void) {
    self.dependencies = dependencies
    self.completion = completion
  }
  func start() { dependencies.schedule { self.attempt() } }
  private func finish(_ message: String?) {
    guard !finished else { return }
    finished = true
    completion(message)
  }
  private func permissionMessage() -> String {
    L10n.t(.pastePermission)
  }
  private func attempt() {
    guard !finished else { return }
    guard dependencies.trusted() else {
      finish(permissionMessage())
      return
    }
    guard !dependencies.secureInput() else {
      finish(L10n.t(.pasteSecure))
      return
    }
    guard dependencies.frontmost(), dependencies.inputFocusReleased() else {
      focusSettled = false
      guard activationRetries > 0 else {
        finish(L10n.t(.pasteActivationFailed))
        return
      }
      activationRetries -= 1
      start()
      return
    }
    // Foreground PID can change before AppKit/browser key focus is restored.
    // Require two scheduled readiness observations, rather than posting during activation.
    guard focusSettled else {
      focusSettled = true
      start()
      return
    }
    dependencies.inspectFocus { [self] focus in
      guard !finished else { return }
      guard dependencies.trusted() else {
        finish(permissionMessage())
        return
      }
      guard dependencies.frontmost(), dependencies.inputFocusReleased() else {
        finish(L10n.t(.pasteFocusLost))
        return
      }
      guard !dependencies.secureInput() else {
        finish(L10n.t(.pasteSecure))
        return
      }
      switch focus {
      case .permissionDenied: finish(permissionMessage())
      case .secure: finish(L10n.t(.pasteSecure))
      case .blocked: finish(L10n.t(.pasteInappropriate))
      case .unavailable where focusRetries > 0:
        focusRetries -= 1
        start()
      case .available, .unavailable:
        finish(dependencies.sendPaste() ? nil : L10n.t(.pasteEventFailed))
      }
    }
  }
}
