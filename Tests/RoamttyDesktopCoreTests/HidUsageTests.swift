import XCTest
@testable import RoamttyDesktopCore

/// Mirrors Android's HidUsageTest; the hardware-key rows use iOS's UIKeyboardHIDUsage codes for the same keys.
final class HidUsageTests: XCTestCase {
    private func ev(_ pairs: [(Int, Bool)]) -> [ModifierLatch.KeyEvent] { pairs.map { ModifierLatch.KeyEvent($0.0, $0.1) } }

    func testHardwareKeys() {
        XCTAssertEqual(HidUsage.A, HidUsage.fromKeyboardHIDUsage(0x04))          // keyboardA
        XCTAssertEqual(0x27, HidUsage.fromKeyboardHIDUsage(0x27))                 // keyboard0
        XCTAssertEqual(0x1E, HidUsage.fromKeyboardHIDUsage(0x1E))                 // keyboard1
        XCTAssertEqual(HidUsage.ENTER, HidUsage.fromKeyboardHIDUsage(0x28))
        XCTAssertEqual(HidUsage.f(12), HidUsage.fromKeyboardHIDUsage(0x45))
        XCTAssertEqual(HidUsage.LEFT_GUI, HidUsage.fromKeyboardHIDUsage(0xE3))    // keyboardLeftGUI (⌘)
        XCTAssertEqual(0x59, HidUsage.fromKeyboardHIDUsage(0x59))                 // keypad1
        XCTAssertEqual(0x64, HidUsage.fromKeyboardHIDUsage(0x64))                 // ISO \
        XCTAssertNil(HidUsage.fromKeyboardHIDUsage(0x32))                          // non-US #, as Android
        XCTAssertNil(HidUsage.fromKeyboardHIDUsage(0x80))                          // volume up
        XCTAssertNil(HidUsage.fromKeyboardHIDUsage(0x90))                          // LANG1
        XCTAssertEqual(0x68, HidUsage.f(13))
        XCTAssertEqual(HidUsage.C, HidUsage.letter("C"))
    }

    func testTappedModifierWrapsOneKey() {
        let m = ModifierLatch()
        m.tap(HidUsage.LEFT_CTRL)
        XCTAssertEqual(ev([(HidUsage.LEFT_CTRL, true), (HidUsage.C, true), (HidUsage.C, false), (HidUsage.LEFT_CTRL, false)]), m.press(HidUsage.C))
        XCTAssertEqual(.off, m.state(HidUsage.LEFT_CTRL))
        XCTAssertEqual(ev([(HidUsage.C, true), (HidUsage.C, false)]), m.press(HidUsage.C))
    }

    func testHeldModifierStays() {
        let m = ModifierLatch()
        m.hold(HidUsage.LEFT_SHIFT)
        _ = m.press(HidUsage.A)
        XCTAssertEqual(.locked, m.state(HidUsage.LEFT_SHIFT))
        m.tap(HidUsage.LEFT_SHIFT)
        XCTAssertEqual(.off, m.state(HidUsage.LEFT_SHIFT))
    }

    func testModifiersGoDownInTheOrderLatched() {
        let m = ModifierLatch()
        m.tap(HidUsage.LEFT_SHIFT)
        m.hold(HidUsage.LEFT_CTRL)
        XCTAssertEqual(ev([(HidUsage.LEFT_SHIFT, true), (HidUsage.LEFT_CTRL, true), (HidUsage.Z, true), (HidUsage.Z, false),
                           (HidUsage.LEFT_CTRL, false), (HidUsage.LEFT_SHIFT, false)]), m.press(HidUsage.Z))
        XCTAssertEqual(ev([(HidUsage.LEFT_CTRL, true), (HidUsage.Z, true), (HidUsage.Z, false), (HidUsage.LEFT_CTRL, false)]), m.press(HidUsage.Z))
    }
}
