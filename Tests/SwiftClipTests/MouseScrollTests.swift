import AppKit
import XCTest

@testable import SwiftClip

final class MouseScrollTests: XCTestCase {
  private let fields: [CGEventField] = [
    .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
    .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
    .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
  ]
  func event(continuous: Bool = false) throws -> CGEvent {
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line,
        wheelCount: 2, wheel1: 3, wheel2: -2, wheel3: 0))
    for (field, value) in zip(fields, [3, -2, 196608, -131072, 30, -20]) {
      event.setIntegerValueField(field, value: Int64(value))
    }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
    event.flags = [.maskShift, .maskAlternate]
    return event
  }
  func values(_ event: CGEvent) -> [Int64] { fields.map { event.getIntegerValueField($0) } }

  func testReversesBothWheelAxesAndAllRepresentationsWithoutChangingModifiers() throws {
    let event = try event()
    let before = values(event)
    let timestamp = event.timestamp
    MouseWheelDirection.reverseIfDiscrete(event)
    XCTAssertEqual(values(event), before.map { -$0 })
    XCTAssertEqual(event.flags, [.maskShift, .maskAlternate])
    XCTAssertEqual(event.timestamp, timestamp)
    XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 0)
  }

  func testTrackpadContinuousAndGestureOrMomentumEventsAreUnchanged() throws {
    let continuous = try event(continuous: true)
    let before = values(continuous)
    MouseWheelDirection.reverseIfDiscrete(continuous)
    XCTAssertEqual(values(continuous), before)
    for field in [CGEventField.scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase] {
      let gesture = try event()
      gesture.setIntegerValueField(field, value: 1)
      let original = values(gesture)
      MouseWheelDirection.reverseIfDiscrete(gesture)
      XCTAssertEqual(values(gesture), original)
      XCTAssertEqual(gesture.getIntegerValueField(field), 1)
    }
  }

  func testAlternatingMouseAndTrackpadHaveNoSharedDirectionState() throws {
    let wheel = try event()
    let trackpad = try event(continuous: true)
    let wheelBefore = values(wheel)
    let trackpadBefore = values(trackpad)
    for _ in 0..<1000 {
      MouseWheelDirection.reverseIfDiscrete(wheel)
      MouseWheelDirection.reverseIfDiscrete(trackpad)
    }
    XCTAssertEqual(values(wheel), wheelBefore)
    XCTAssertEqual(values(trackpad), trackpadBefore)
    let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    MouseWheelDirection.reverseIfDiscrete(key)
    XCTAssertEqual(key.type, .keyDown)
    XCTAssertEqual(key.getIntegerValueField(.keyboardEventKeycode), 0)
  }

  func testDisabledByDefaultAndRepeatedStopIsSafe() {
    let controller = MouseScrollReverser()
    XCTAssertEqual(controller.state, .off)
    controller.configure(enabled: false)
    controller.stop()
    controller.stop()
    XCTAssertEqual(controller.state, .off)
  }
}
