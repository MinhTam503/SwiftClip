import AppKit
import SwiftUI

@main struct SwiftClipApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  var body: some Scene { SwiftUI.Settings { EmptyView() } }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let model: HistoryModel
  override convenience init() {
    let args = ProcessInfo.processInfo.arguments
    let root: URL? =
      args.contains("--diagnostic") || args.contains("--diagnostic-short")
      ? FileManager.default.temporaryDirectory.appendingPathComponent(
        "SwiftClip-Diagnostic-" + String(ProcessInfo.processInfo.processIdentifier)) : nil
    self.init(model: HistoryModel(root: root))
  }
  init(model: HistoryModel) {
    self.model = model
    super.init()
  }
  let monitor = ClipboardMonitor()
  let hotkey = HotkeyManager()
  var status: NSStatusItem?
  var panel: NSPanel?
  var settingsWindow: NSWindow?
  var target: NSRunningApplication?
  var clickMonitor: Any?
  var keyMonitor: Any?
  var previewWindow: NSWindow?
  private var languageObserver: NSObjectProtocol?
  var selectionInFlight = false
  private(set) var historyConfirmationInFlight = false
  private var popupWasMoved = false
  private var positioningPopup = false
  private var openingPopup = false
  private var presentationGeneration = 0
  private var popupScreen = NSRect.zero
  private var popupPointer = NSPoint.zero
  private var popupAvoid: NSRect?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    monitor.captured = { [weak self] p, k, t, s in
      self?.recordUIEvent("clipboard_captured")
      self?.model.save(p, kind: k, preview: t, source: s)
    }
    model.onRowsChanged = { [weak self] in self?.resizePopup() }
    model.onChange = { [weak self] in if self?.panel != nil { self?.model.load() } }
    hotkey.action = { [weak self] in
      self?.recordUIEvent("global_hotkey")
      self?.toggle()
    }
    languageObserver = NotificationCenter.default.addObserver(
      forName: .swiftClipLanguageChanged, object: nil, queue: .main
    ) { [weak self] _ in self?.refreshLocalizedUI() }
    applySettings()
    refreshLocalizedUI()
    DispatchQueue.main.async { [weak self] in self?.refreshLocalizedUI() }
    if ProcessInfo.processInfo.arguments.contains("--diagnostic")
      || ProcessInfo.processInfo.arguments.contains("--diagnostic-short")
    {
      runDiagnostics()
      return
    }
    if !Settings.shared.bool("background", true) { show() }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    show()
    return true
  }
  func applySettings() {
    monitor.start()
    if !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--diagnostic") }) {
      do {
        try hotkey.register(key: Settings.shared.key, modifiers: Settings.shared.modifiers)
      } catch {
        model.notice = .error(error, .operationFailed)
        showSettings()
      }
    }
    if Settings.shared.bool("menu", true) {
      if status == nil {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let diagnostic = ProcessInfo.processInfo.arguments.contains(where: {
          $0.hasPrefix("--diagnostic")
        })
        item.button?.image = NSImage(
          systemSymbolName: diagnostic ? "hourglass" : "clipboard",
          accessibilityDescription: diagnostic ? L10n.t(.benchmarkName) : L10n.t(.appName))
        item.button?.toolTip =
          diagnostic ? L10n.t(.benchmarkTip) : L10n.t(.appName)
        item.button?.target = self
        item.button?.action = #selector(statusClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status = item
      }
    } else if let status {
      NSStatusBar.system.removeStatusItem(status)
      self.status = nil
    }
    let appearance = Settings.shared.string("appearance")
    NSApp.appearance =
      appearance == "Light"
      ? NSAppearance(named: .aqua) : appearance == "Dark" ? NSAppearance(named: .darkAqua) : nil
    let limit = Settings.shared.limit
    let days = Settings.shared.int("days", 0)
    model.perform { try $0.cleanup(limit: limit, days: days) }
  }
  func refreshLocalizedUI() {
    settingsWindow?.title = L10n.t(.settingsTitle)
    previewWindow?.title = L10n.t(.preview)
    let diagnostic = ProcessInfo.processInfo.arguments.contains(where: {
      $0.hasPrefix("--diagnostic")
    })
    status?.button?.toolTip = L10n.t(diagnostic ? .benchmarkTip : .appName)
    status?.button?.setAccessibilityLabel(L10n.t(diagnostic ? .benchmarkName : .appName))
    let main = NSMenu()
    func submenu(_ key: L10n.Key) -> NSMenu {
      let item = NSMenuItem(title: L10n.t(key), action: nil, keyEquivalent: "")
      let menu = NSMenu(title: L10n.t(key))
      item.submenu = menu
      main.addItem(item)
      return menu
    }
    let application = submenu(.appName)
    for (key, selector, equivalent) in [
      (L10n.Key.openClipboard, #selector(openClipboard), ""),
      (.settingsMenu, #selector(openSettings), ","), (.quit, #selector(quit), "q"),
    ] {
      let item = NSMenuItem(title: L10n.t(key), action: selector, keyEquivalent: equivalent)
      item.target = self
      application.addItem(item)
    }
    let edit = submenu(.editMenu)
    for (key, selector, equivalent, shift) in [
      (L10n.Key.undo, "undo:", "z", false), (.redo, "redo:", "z", true), (.cut, "cut:", "x", false),
      (.copy, "copy:", "c", false), (.paste, "paste:", "v", false),
      (.selectAll, "selectAll:", "a", false),
    ] {
      let item = NSMenuItem(
        title: L10n.t(key), action: Selector(selector), keyEquivalent: equivalent)
      item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
      edit.addItem(item)
    }
    let windows = submenu(.windowMenu)
    windows.addItem(
      NSMenuItem(
        title: L10n.t(.minimize), action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"))
    windows.addItem(
      NSMenuItem(
        title: L10n.t(.bringAllFront), action: #selector(NSApplication.arrangeInFront(_:)),
        keyEquivalent: ""))
    NSApp.mainMenu = main
    NSApp.windowsMenu = windows
  }
  @objc func statusClick() {
    if NSApp.currentEvent?.type == .rightMouseUp, let status {
      let menu = NSMenu()
      for (title, action) in [
        (L10n.t(.openClipboard), #selector(openClipboard)),
        (L10n.t(.settingsMenu), #selector(openSettings)),
        (L10n.t(.quit), #selector(quit)),
      ] {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
      }
      status.menu = menu
      status.button?.performClick(nil)
      status.menu = nil
    } else {
      toggle()
    }
  }
  @objc func quit() { NSApp.terminate(nil) }
  @objc func openClipboard() { show() }
  @objc func openSettings() { showSettings() }
  func toggle() { panel == nil && !openingPopup ? show() : close() }
  func show() {
    recordUIEvent("popup_requested")
    guard panel == nil, !openingPopup else { return }
    let current = NSWorkspace.shared.frontmostApplication
    if current?.processIdentifier != ProcessInfo.processInfo.processIdentifier { target = current }
    openingPopup = true
    presentationGeneration += 1
    let token = presentationGeneration
    let screen =
      NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen
      .main!
    popupScreen = screen.visibleFrame
    popupPointer = NSEvent.mouseLocation
    let pid = current?.processIdentifier
    PopupFocusProbe.read(
      pid: pid, desktopTop: NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
    ) { [weak self] rect in
      guard let self, self.openingPopup, token == self.presentationGeneration else { return }
      self.openingPopup = false
      if let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { return }
      self.popupAvoid = rect
      self.presentPopup()
    }
  }
  private func presentPopup() {
    model.beginPresentation()
    let p = ClipboardPanel(clipboardRect: .zero)
    p.isMovableByWindowBackground = true
    p.level = .floating
    p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    p.isReleasedWhenClosed = false
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = true
    p.delegate = self
    p.contentView = ClipboardHostingView(rootView: PopupView(model: model, app: self))
    panel = p
    popupWasMoved = false
    resizePopup()
    model.load()
    // A nonactivating panel borrows key focus without deactivating the original app.
    p.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .init("SwiftClipFocusSearch"), object: nil)
    }
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      guard let self, !self.historyConfirmationInFlight else { return }
      self.close()
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, NSApp.keyWindow === self.panel else { return event }
      if event.keyCode == 53 {
        if !self.model.query.isEmpty {
          self.model.query = ""
          self.model.load()
        } else {
          self.close()
        }
        return nil
      }
      if event.keyCode == Settings.shared.int("focusKey", 3)
        && event.modifierFlags.intersection([.command, .shift, .option, .control])
          == NSEvent.ModifierFlags(
            rawValue: UInt(
              Settings.shared.int("focusFlags", Int(NSEvent.ModifierFlags.command.rawValue))))
      {
        NotificationCenter.default.post(name: .init("SwiftClipFocusSearch"), object: nil)
        return nil
      }
      if event.keyCode == 125 {
        self.model.move(1)
        return nil
      }
      if event.keyCode == 126 {
        self.model.move(-1)
        return nil
      }
      if event.keyCode == Settings.shared.int("pasteKey", 36),
        event.modifierFlags.intersection(PopupShortcut.mask).rawValue
          == UInt(Settings.shared.int("pasteFlags", 0)),
        let clip = self.model.clips.first(where: { $0.id == self.model.selected })
      {
        self.select(clip)
        return nil
      }
      if event.keyCode == 51 && event.modifierFlags.contains(.command),
        let clip = self.model.clips.first(where: { $0.id == self.model.selected })
      {
        self.model.perform { try $0.delete(clip.id) }
        return nil
      }
      return event
    }
  }
  private func resizePopup() {
    guard let panel else { return }
    if popupWasMoved, let screen = panel.screen { popupScreen = screen.visibleFrame }
    let size = PopupLayout.size(
      count: model.clips.count, navigation: model.hasMore || model.pageOffset > 0,
      message: !model.message.isEmpty, screen: popupScreen)
    let frame =
      popupWasMoved
      ? PopupLayout.draggedFrame(size: size, previous: panel.frame, screen: popupScreen)
      : PopupLayout.frame(
        size: size, screen: popupScreen, pointer: popupPointer, avoiding: popupAvoid)
    positioningPopup = true
    panel.setFrame(frame, display: true)
    positioningPopup = false
  }
  func windowDidMove(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === panel, !positioningPopup else {
      return
    }
    popupWasMoved = true
  }
  func windowDidResignKey(_ notification: Notification) {
    if let window = notification.object as? NSWindow, window === panel, !selectionInFlight,
      !historyConfirmationInFlight
    {
      close()
    }
  }
  func close() {
    recordUIEvent("popup_closed")
    openingPopup = false
    presentationGeneration += 1
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    let closing = panel
    panel = nil
    closing?.delegate = nil
    closing?.close()
    closing?.contentView = nil
    model.release()
  }
  func select(_ clip: Clip, copyOnly: Bool = false) {
    guard !selectionInFlight else { return }
    let destination = target
    model.payload(clip) { [weak self] payload in
      guard let self, !self.selectionInFlight else { return }
      self.selectionInFlight = true
      guard PasteManager.write(payload) else {
        self.model.notice = .message(.clipboardWriteFailed)
        self.selectionInFlight = false
        return
      }
      self.monitor.suppressCurrent()
      self.recordUIEvent("clipboard_written")
      let auto = !copyOnly && !Settings.shared.bool("copyOnly")
      let keepOpen = auto && !Settings.shared.bool("closeAfter", true)
      if keepOpen {
        self.panel?.orderOut(nil)
      } else if auto || Settings.shared.bool("closeAfter", true) {
        self.close()
      }
      if auto, let destination {
        PasteManager.paste(into: destination) { message in
          self.selectionInFlight = false
          if keepOpen { self.panel?.orderFront(nil) }
          if let message { self.feedback(message) }
        }
      } else {
        self.selectionInFlight = false
        if keepOpen { self.panel?.orderFront(nil) }
        if auto { self.feedback(L10n.t(.pasteManual)) }
      }
    }
  }
  func feedback(_ text: String) {
    let alert = NSAlert()
    alert.messageText = L10n.t(.appName)
    alert.informativeText = text
    alert.addButton(withTitle: L10n.t(.ok))
    if !PasteManager.trusted { alert.addButton(withTitle: L10n.t(.openAccessibility)) }
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertSecondButtonReturn { PasteManager.openAccessibility() }
  }
  func clearHistory() {
    guard !historyConfirmationInFlight else { return }
    let alert = NSAlert()
    alert.messageText = L10n.t(.clearAllTitle)
    alert.informativeText = L10n.t(.clearAllBody)
    alert.addButton(withTitle: L10n.t(.cancel))
    alert.addButton(withTitle: L10n.t(.clearAllConfirm))
    if let panel {
      historyConfirmationInFlight = true
      alert.beginSheetModal(for: panel) { [weak self, weak panel] response in
        guard let self else { return }
        self.historyConfirmationInFlight = false
        if response == .alertSecondButtonReturn { self.model.perform { try $0.clear() } }
        if let panel, self.panel === panel { panel.makeKeyAndOrderFront(nil) }
      }
    } else if alert.runModal() == .alertSecondButtonReturn {
      model.perform { try $0.clear() }
    }
  }
  func preview(_ clip: Clip) {
    model.payload(clip) { [weak self] payload in
      guard let self else { return }
      self.close()
      self.previewWindow?.close()
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      w.title = L10n.t(.preview)
      w.isReleasedWhenClosed = false
      w.delegate = self
      w.contentView = NSHostingView(rootView: PreviewView(payload: payload))
      self.previewWindow = w
      w.center()
      NSApp.activate(ignoringOtherApps: true)
      w.makeKeyAndOrderFront(nil)
    }
  }
  func showSettings() {
    close()
    if settingsWindow == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 580, height: 650), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
      w.title = L10n.t(.settingsTitle)
      w.isReleasedWhenClosed = false
      w.delegate = self
      w.contentView = NSHostingView(
        rootView: SettingsView(settings: Settings.shared, model: model, app: self))
      settingsWindow = w
      w.center()
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
  }
  func windowWillClose(_ notification: Notification) {
    if notification.object as? NSWindow === previewWindow {
      previewWindow?.contentView = nil
      previewWindow = nil
    }
    if notification.object as? NSWindow === settingsWindow {
      settingsWindow?.contentView = nil
      settingsWindow = nil
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    monitor.stop()
    if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    model.queue.sync {}
  }
}
