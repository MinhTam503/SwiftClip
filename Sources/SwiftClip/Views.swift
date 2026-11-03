import AppKit
import Carbon
import ImageIO
import ServiceManagement
import SwiftUI

struct PopupView: View {
  @ObservedObject private var localization = Localization.shared
  @ObservedObject var model: HistoryModel
  let app: AppDelegate
  @FocusState private var searching: Bool
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(L10n.t(.appName), systemImage: "clipboard").font(.headline)
        Spacer()
        if Settings.shared.bool("paused") {
          Text(L10n.t(.paused)).font(.caption).foregroundStyle(.secondary)
        }
        Button {
          app.clearHistory()
        } label: {
          Image(systemName: "trash")
        }.help(L10n.t(.clearHistoryHelp)).accessibilityLabel(L10n.t(.clearHistoryHelp))
        Button {
          app.showSettings()
        } label: {
          Image(systemName: "gearshape")
        }.help(L10n.t(.settings)).accessibilityLabel(L10n.t(.settings))
      }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
        TextField(L10n.t(.searchPlaceholder), text: $model.query).textFieldStyle(.plain).focused(
          $searching)
        if !model.query.isEmpty {
          Button {
            model.query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }.buttonStyle(.plain).help(L10n.t(.clearSearch)).accessibilityLabel(L10n.t(.clearSearch))
        }
      }.padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 10)
      Divider()
      if !model.message.isEmpty {
        Text(model.message).font(.caption).foregroundStyle(.red).padding(8)
      }
      if model.clips.isEmpty {
        Spacer()
        Image(systemName: "clipboard").font(.system(size: 36)).foregroundStyle(.secondary)
        Text(model.query.isEmpty ? L10n.t(.emptyHistory) : L10n.t(.emptySearch))
          .font(.headline).padding(.top, 8)
        Text(L10n.t(.emptyHint)).font(.caption).foregroundStyle(.secondary)
        Spacer()
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(model.clips) { clip in
                ClipRow(clip: clip, selected: model.selected == clip.id, openedAt: model.openedAt)
                  .contentShape(Rectangle()).onTapGesture {
                    model.selected = clip.id
                    app.select(clip)
                  }
                  .contextMenu {
                    Button(L10n.t(.paste)) { app.select(clip) }
                    Button(L10n.t(.copy)) { app.select(clip, copyOnly: true) }
                    Button(clip.pinned ? L10n.t(.unpin) : L10n.t(.pin)) {
                      model.perform { try $0.pin(clip) }
                    }
                    Button(L10n.t(.preview)) { app.preview(clip) }
                    Divider()
                    Button(L10n.t(.deleteItem), role: .destructive) {
                      model.perform { try $0.delete(clip.id) }
                    }
                  }.id(clip.id)
              }
              if model.pageOffset > 0 || model.hasMore {
                HStack {
                  if model.pageOffset > 0 { Button(L10n.t(.newer)) { model.load(previous: true) } }
                  Spacer()
                  if model.hasMore { Button(L10n.t(.older)) { model.load(more: true) } }
                }.padding(8)
              }
            }.padding(8)
          }.onChange(of: model.selected) { value in if let value { proxy.scrollTo(value) } }
        }
      }
      Divider()
      HStack {
        Text(L10n.t(.popupKeys))
        Spacer()
        Text(L10n.t(.escapeClose))
      }.font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
      Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden().frame(
        height: 0)
    }.environment(\.locale, localization.locale).frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
      .onReceive(
        NotificationCenter.default.publisher(for: .init("SwiftClipFocusSearch"))
      ) { _ in searching = true }.onAppear { searching = true }.onChange(of: model.query) { _ in
        model.search()
      }
  }
}
struct ClipRow: View {
  @ObservedObject private var localization = Localization.shared
  let clip: Clip
  let selected: Bool
  let openedAt: Date
  @State private var thumbnail: NSImage?
  var icon: String {
    switch clip.kind {
    case "image": return "photo"
    case "file": return "doc"
    case "url": return "link"
    case "rich text": return "textformat"
    default: return "text.alignleft"
    }
  }
  var body: some View {
    HStack(spacing: 12) {
      Group {
        if let thumbnail {
          Image(nsImage: thumbnail).resizable().scaledToFit()
        } else {
          Image(systemName: icon).accessibilityHidden(true).font(.system(size: 20)).foregroundStyle(
            .secondary)
        }
      }.frame(width: 42, height: 42)
      VStack(alignment: .leading, spacing: 4) {
        Text(String(L10n.preview(clip).prefix(240))).font(.system(size: 13)).lineLimit(2).frame(
          maxWidth: .infinity, alignment: .leading)
        HStack {
          Text(L10n.contentKind(clip.kind))
          Text(ClipboardTimestamp.label(clip.date, relativeTo: openedAt))
          if clip.pinned { Image(systemName: "pin.fill").accessibilityLabel(L10n.t(.pinned)) }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }.padding(10).background(
      selected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .accessibilityElement(children: .combine)
    .task(id: clip.thumbnail) {
      guard let path = clip.thumbnail else { return }
      let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SwiftClip").appendingPathComponent(path)
      let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
      guard !Task.isCancelled else { return }
      if let data { thumbnail = NSImage(data: data) }
    }.onDisappear { thumbnail = nil }
  }
}
struct PreviewView: View {
  @ObservedObject private var localization = Localization.shared
  let payload: Payload
  @State private var image: NSImage?
  @State private var text = ""
  var body: some View {
    ScrollView {
      if let image {
        Image(nsImage: image).resizable().scaledToFit().padding()
      } else {
        Text(text.isEmpty ? L10n.t(.contentRich) : text).textSelection(.enabled).frame(
          maxWidth: .infinity, alignment: .leading
        ).padding(
          20)
      }
    }
    .frame(minWidth: 400, minHeight: 300).task {
      let result = await Task.detached(priority: .utility) { () -> (CGImage?, String) in
        let reps = payload.items.flatMap { $0 }
        if let data = reps.first(where: {
          $0.type == NSPasteboard.PasteboardType.png.rawValue
            || $0.type == NSPasteboard.PasteboardType.tiff.rawValue
        })?.data,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 1600,
              kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        {
          return (cg, "")
        }
        var text = reps.filter {
          [
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.fileURL.rawValue, NSPasteboard.PasteboardType.URL.rawValue,
          ].contains($0.type)
        }.compactMap { String(data: $0.data, encoding: .utf8) }.joined(separator: "\n")
        if text.isEmpty,
          let rtf = reps.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue })?.data
        {
          text = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string ?? ""
        }
        return (nil, text)
      }.value
      guard !Task.isCancelled else { return }
      if let cg = result.0 { image = NSImage(cgImage: cg, size: .zero) }
      text = result.1
    }
  }
}
struct SettingsView: View {
  @ObservedObject private var localization = Localization.shared
  @ObservedObject var settings: Settings
  @ObservedObject var model: HistoryModel
  let app: AppDelegate
  @State private var loginError: Error?
  @State private var recording = false
  @State private var recordingAction = "global"
  func bool(_ key: String, _ fallback: Bool = false) -> Binding<Bool> {
    Binding(
      get: { settings.bool(key, fallback) },
      set: {
        settings.set(key, $0)
        app.applySettings()
      })
  }
  func number(_ key: String, _ fallback: Int) -> Binding<Int> {
    Binding(
      get: { settings.int(key, fallback) },
      set: {
        settings.set(key, $0)
        app.applySettings()
      })
  }
  func string(_ key: String) -> Binding<String> {
    Binding(
      get: { settings.string(key) },
      set: {
        settings.set(key, $0)
        app.applySettings()
      })
  }
  var body: some View {
    TabView {
      Form {
        Section(L10n.t(.general)) {
          Picker(L10n.t(.language), selection: $localization.selection) {
            ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
          }
          Toggle(
            L10n.t(.launchAtLogin),
            isOn: Binding(
              get: { SMAppService.mainApp.status == .enabled },
              set: { enabled in
                do {
                  if enabled {
                    try SMAppService.mainApp.register()
                  } else {
                    try SMAppService.mainApp.unregister()
                  }
                  loginError = nil
                } catch { loginError = error }
              }))
          Text(loginError.map { L10n.error($0) } ?? statusText).font(.caption).foregroundStyle(
            .secondary)
          Button(L10n.t(.openLoginSettings)) { SMAppService.openSystemSettingsLoginItems() }
          Toggle(L10n.t(.showMenuIcon), isOn: bool("menu", true))
          Toggle(L10n.t(.startBackground), isOn: bool("background", true))
          Toggle(L10n.t(.copyOnly), isOn: bool("copyOnly"))
          Toggle(L10n.t(.closeAfterSelection), isOn: bool("closeAfter", true))
          Picker(L10n.t(.appearance), selection: string("appearance")) {
            Text(L10n.t(.system)).tag("")
            Text(L10n.t(.light)).tag("Light")
            Text(L10n.t(.dark)).tag("Dark")
          }
        }
        Section(L10n.t(.paste)) {
          Text(PasteManager.trusted ? L10n.t(.accessibilityGranted) : L10n.t(.accessibilityDenied))
            .font(.caption)
          Button(L10n.t(.openAccessibility)) { PasteManager.openAccessibility() }
          Text(L10n.t(.accessibilityHint)).font(.caption)
            .foregroundStyle(.secondary)
        }
      }.tabItem { Label(L10n.t(.general), systemImage: "gearshape") }
      Form {
        Section(L10n.t(.globalShortcut)) {
          Text(L10n.t(.openClipboardValue, shortcutLabel))
          Button(recording ? L10n.t(.recording) : L10n.t(.recordShortcut)) {
            recordingAction = "global"
            recording = true
          }
          if recording {
            ShortcutRecorder { event in
              recording = false
              let flags = event.modifierFlags
              var modifiers: UInt32 = 0
              if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
              if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
              if flags.contains(.option) { modifiers |= UInt32(optionKey) }
              if flags.contains(.control) { modifiers |= UInt32(controlKey) }
              if recordingAction == "global" {
                updateShortcut(UInt32(event.keyCode), modifiers)
              } else if PopupShortcut.valid(
                key: event.keyCode, flags: flags, search: recordingAction == "focus")
                && !(UInt32(event.keyCode) == settings.key && modifiers == settings.modifiers)
              {
                let prefix = recordingAction == "focus" ? "focus" : "paste"
                settings.set(prefix + "Key", Int(event.keyCode))
                settings.set(prefix + "Flags", Int(flags.intersection(PopupShortcut.mask).rawValue))
                model.notice = nil
              } else {
                model.notice = .message(.shortcutConflict)
              }
            }.frame(height: 30)
          }
          Button(L10n.t(.recordFocusSearch, settings.int("focusKey", 3))) {
            recordingAction = "focus"
            recording = true
          }
          Button(L10n.t(.recordPaste, settings.int("pasteKey", 36))) {
            recordingAction = "paste"
            recording = true
          }
          Button(L10n.t(.restoreDefaults)) {
            updateShortcut(9, UInt32(cmdKey | shiftKey))
            settings.set("focusKey", 3)
            settings.set("focusFlags", Int(NSEvent.ModifierFlags.command.rawValue))
            settings.set("pasteKey", 36)
            settings.set("pasteFlags", 0)
          }
          Text(L10n.t(.shortcutHelp))
            .font(.caption).foregroundStyle(.secondary)
          Text(
            L10n.t(.shortcutRules)
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.tabItem { Label(L10n.t(.shortcuts), systemImage: "keyboard") }
      Form {
        Section(L10n.t(.history)) {
          Picker(L10n.t(.maximumItems), selection: number("limit", 500)) {
            Text(L10n.number(100)).tag(100)
            Text(L10n.number(500)).tag(500)
            Text(L10n.number(1000)).tag(1000)
            Text(L10n.t(.unlimited)).tag(0)
          }
          Picker(L10n.t(.maximumCapture), selection: number("imageMB", 20)) {
            Text(L10n.t(.megabytes, 5)).tag(5)
            Text(L10n.t(.megabytes, 20)).tag(20)
            Text(L10n.t(.megabytes, 50)).tag(50)
          }
          Picker(L10n.t(.removeAfter), selection: number("days", 0)) {
            Text(L10n.t(.never)).tag(0)
            Text(L10n.quantity(7, one: .daysOne, other: .daysOther)).tag(7)
            Text(L10n.quantity(30, one: .daysOne, other: .daysOther)).tag(30)
            Text(L10n.quantity(90, one: .daysOne, other: .daysOther)).tag(90)
          }
          Text(
            L10n.t(.historyPolicy)
          ).font(.caption).foregroundStyle(.secondary)
          Button(L10n.t(.clearAllAction), role: .destructive) { app.clearHistory() }
        }
      }.tabItem { Label(L10n.t(.history), systemImage: "clock") }
      Form {
        Section(L10n.t(.privacy)) {
          Toggle(L10n.t(.pauseMonitoring), isOn: bool("paused"))
          Text(
            L10n.t(.privacyPolicy)
          ).font(.caption).foregroundStyle(.secondary)
          Text(L10n.t(.ignoreApps))
          TextEditor(text: string("ignored")).font(.system(.body, design: .monospaced)).frame(
            height: 120
          ).border(Color.secondary.opacity(0.3))
          Picker(L10n.t(.pollingInterval), selection: number("poll", 500)) {
            Text(L10n.t(.milliseconds, 250)).tag(250)
            Text(L10n.t(.milliseconds, 500)).tag(500)
            Text(L10n.t(.milliseconds, 1000)).tag(1000)
          }
          Button(L10n.t(.clearAllAction), role: .destructive) { app.clearHistory() }
        }
      }.tabItem { Label(L10n.t(.privacy), systemImage: "hand.raised") }
    }.environment(\.locale, localization.locale).formStyle(.grouped).padding(12).frame(
      width: 580, height: 620
    )
    .overlay(alignment: .bottom) {
      if !model.message.isEmpty {
        Text(model.message).font(.caption).foregroundStyle(.red).padding(8).background(
          .regularMaterial)
      }
    }
  }
  var statusText: String {
    switch SMAppService.mainApp.status {
    case .enabled: return L10n.t(.loginEnabled)
    case .requiresApproval: return L10n.t(.loginApproval)
    case .notRegistered: return L10n.t(.loginNotRegistered)
    case .notFound: return L10n.t(.loginNotFound)
    @unknown default: return L10n.t(.statusUnknown)
    }
  }
  var shortcutLabel: String {
    let m = settings.modifiers
    let symbols =
      (m & UInt32(controlKey) != 0 ? "⌃" : "") + (m & UInt32(optionKey) != 0 ? "⌥" : "")
      + (m & UInt32(shiftKey) != 0 ? "⇧" : "") + (m & UInt32(cmdKey) != 0 ? "⌘" : "")
    return L10n.t(.shortcutValue, symbols, Int(settings.key)) + (settings.key == 9 ? " (V)" : "")
  }
  func updateShortcut(_ key: UInt32, _ modifiers: UInt32) {
    do {
      try app.hotkey.register(key: key, modifiers: modifiers)
      settings.set("key", Int(key))
      settings.set("modifiers", Int(modifiers))
      model.notice = nil
    } catch { model.notice = .error(error, .operationFailed) }
  }
}
struct ShortcutRecorder: NSViewRepresentable {
  let captured: (NSEvent) -> Void
  func makeNSView(context: Context) -> KeyCapture {
    let view = KeyCapture()
    view.captured = captured
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    return view
  }
  func updateNSView(_ view: KeyCapture, context: Context) {}
}
final class KeyCapture: NSView {
  var captured: ((NSEvent) -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) { captured?(event) }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    captured?(event)
    return true
  }
}
