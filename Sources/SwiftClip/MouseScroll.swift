import AppKit
import ApplicationServices

/// An opt-in scroll-only filter. No device database, polling, event copies or reposting.
final class MouseScrollReverser: ObservableObject {
  enum State { case off, active, permissionRequired, unavailable }
  @Published private(set) var state: State = .off
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var wakeObserver: NSObjectProtocol?

  func configure(enabled: Bool) {
    precondition(Thread.isMainThread)
    guard enabled else {
      stop()
      return
    }
    guard AXIsProcessTrusted() else {
      stop()
      state = .permissionRequired
      return
    }
    if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
    stop()
    let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, context in
          guard let context else { return Unmanaged.passUnretained(event) }
          let owner = Unmanaged<MouseScrollReverser>.fromOpaque(context).takeUnretainedValue()
          if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            owner.reenable()
          } else if type == .scrollWheel {
            MouseWheelDirection.reverseIfDiscrete(event)
          }
          return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else {
      state = .unavailable
      return
    }
    self.tap = tap
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    state = CGEvent.tapIsEnabled(tap: tap) ? .active : .unavailable
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.reenable() }
  }

  private func reenable() {
    guard AXIsProcessTrusted() else {
      stop()
      state = .permissionRequired
      return
    }
    guard let tap else { return }
    CGEvent.tapEnable(tap: tap, enable: true)
    state = CGEvent.tapIsEnabled(tap: tap) ? .active : .unavailable
  }

  func stop() {
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
    }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    tap = nil
    source = nil
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    wakeObserver = nil
    if state != .off { state = .off }
  }
  deinit { stop() }
}

enum MouseWheelDirection {
  private static func reversed(_ value: Int64) -> Int64 { value == .min ? .max : -value }
  static func reverseIfDiscrete(_ event: CGEvent) {
    guard event.type == .scrollWheel,
      event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
      event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
      event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
    else { return }
    // Setting line deltas can also rewrite pixel/fixed-point fields on macOS.
    // Snapshot all values in scalars before mutation; no per-event array allocation.
    let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    let fixedVertical = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let fixedHorizontal = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)
    let pixelVertical = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let pixelHorizontal = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: reversed(vertical))
    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: reversed(horizontal))
    event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: reversed(fixedVertical))
    event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: reversed(fixedHorizontal))
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: reversed(pixelVertical))
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: reversed(pixelHorizontal))
  }
}
