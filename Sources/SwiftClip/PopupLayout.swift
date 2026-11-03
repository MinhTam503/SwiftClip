import AppKit
import ApplicationServices
import SwiftUI

final class ClipboardPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  convenience init(clipboardRect: NSRect) {
    self.init(
      contentRect: clipboardRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    becomesKeyOnlyIfNeeded = false
    hidesOnDeactivate = false
  }
}

final class ClipboardHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A dedicated header region keeps drag gestures separate from row selection and search.
struct PopupDragHandle: NSViewRepresentable {
  func makeNSView(context: Context) -> PopupDragView { PopupDragView() }
  func updateNSView(_ view: PopupDragView, context: Context) {}
}
final class PopupDragView: NSView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

enum PopupLayout {
  static let width: CGFloat = 420
  static func draggedFrame(size: NSSize, previous: NSRect, screen: NSRect) -> NSRect {
    let width = min(size.width, screen.width)
    let height = min(size.height, screen.height)
    return NSRect(
      x: max(screen.minX, min(previous.minX, screen.maxX - width)),
      y: max(screen.minY, min(previous.maxY - height, screen.maxY - height)),
      width: width, height: height)
  }
  static func size(count: Int, navigation: Bool, message: Bool, screen: NSRect) -> NSSize {
    let rows = min(max(count, 0), 6)
    let desired: CGFloat = rows == 0 ? 220 : max(208, 132 + CGFloat(rows) * 64)
    return NSSize(
      width: min(width, max(1, screen.width - 24)),
      height: min(
        desired + (navigation ? 32 : 0) + (message ? 36 : 0), 460, max(1, screen.height - 24)))
  }
  static func frame(size: NSSize, screen: NSRect, pointer: NSPoint, avoiding field: NSRect?)
    -> NSRect
  {
    let bounds = screen.insetBy(dx: min(12, screen.width / 4), dy: min(12, screen.height / 4))
    let size = NSSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
    let avoid = field ?? NSRect(x: pointer.x - 120, y: pointer.y - 24, width: 240, height: 48)
    let gap: CGFloat = 12
    func clampX(_ x: CGFloat) -> CGFloat { max(bounds.minX, min(x, bounds.maxX - size.width)) }
    func clampY(_ y: CGFloat) -> CGFloat { max(bounds.minY, min(y, bounds.maxY - size.height)) }
    let x = clampX(pointer.x - size.width / 2)
    let y = clampY(pointer.y - size.height / 2)
    let candidates = [
      NSRect(origin: NSPoint(x: x, y: avoid.maxY + gap), size: size),
      NSRect(origin: NSPoint(x: x, y: avoid.minY - gap - size.height), size: size),
      NSRect(origin: NSPoint(x: avoid.maxX + gap, y: y), size: size),
      NSRect(origin: NSPoint(x: avoid.minX - gap - size.width, y: y), size: size),
    ]
    if let fitting = candidates.first(where: { bounds.contains($0) && !$0.intersects(avoid) }) {
      return fitting
    }
    // Very large editors/small screens may leave no fully separate slot: minimize overlap.
    let corners = [
      NSPoint(x: bounds.minX, y: bounds.maxY - size.height),
      NSPoint(x: bounds.maxX - size.width, y: bounds.maxY - size.height),
      NSPoint(x: bounds.minX, y: bounds.minY), NSPoint(x: bounds.maxX - size.width, y: bounds.minY),
    ]
    return corners.map { NSRect(origin: $0, size: size) }.min { a, b in
      let ia = a.intersection(avoid)
      let ib = b.intersection(avoid)
      let aa = ia.isNull ? 0 : ia.width * ia.height
      let ab = ib.isNull ? 0 : ib.width * ib.height
      if aa != ab { return aa < ab }
      return hypot(a.midX - pointer.x, a.midY - pointer.y)
        < hypot(b.midX - pointer.x, b.midY - pointer.y)
    }!
  }
}

enum PopupFocusProbe {
  private static let queue = DispatchQueue(
    label: "com.personal.swiftclip.popup-focus", qos: .userInitiated)
  /// Read geometry only, never the field's text. No focus observer or polling is installed.
  static func read(pid: pid_t?, desktopTop: CGFloat, completion: @escaping (NSRect?) -> Void) {
    guard AXIsProcessTrusted(), let pid else {
      completion(nil)
      return
    }
    queue.async {
      let rect = fieldRect(pid: pid, desktopTop: desktopTop)
      DispatchQueue.main.async { completion(rect) }
    }
  }
  private static func fieldRect(pid: pid_t, desktopTop: CGFloat) -> NSRect? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.08)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    let element = unsafeBitCast(value, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(element, 0.08)
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    guard let role = role as? String,
      [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    else { return nil }
    var position: CFTypeRef?
    var dimensions: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &dimensions) == .success,
      let position, let dimensions, CFGetTypeID(position) == AXValueGetTypeID(),
      CFGetTypeID(dimensions) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
      AXValueGetValue(unsafeBitCast(dimensions, to: AXValue.self), .cgSize, &size),
      point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite, size.width > 0,
      size.height > 0
    else { return nil }
    return NSRect(
      x: point.x, y: desktopTop - point.y - size.height, width: size.width, height: size.height)
  }
}

enum ClipboardTimestamp {
  static func label(
    _ copiedAt: Date, relativeTo openedAt: Date, localization: Localization = .shared
  ) -> String {
    let age = max(0, openedAt.timeIntervalSince(copiedAt))
    if age < 60 { return localization.text(.justNow) }
    let count: Int
    let one: L10n.Key
    let other: L10n.Key
    if age < 3600 {
      count = Int(age / 60)
      one = .minutesOne
      other = .minutesOther
    } else if age < 86400 {
      count = Int(age / 3600)
      one = .hoursOne
      other = .hoursOther
    } else if age < 604800 {
      count = Int(age / 86400)
      one = .daysAgoOne
      other = .daysAgoOther
    } else {
      return copiedAt.formatted(
        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(localization.locale))
    }
    return localization.text(count == 1 ? one : other, arguments: [count])
  }
}
