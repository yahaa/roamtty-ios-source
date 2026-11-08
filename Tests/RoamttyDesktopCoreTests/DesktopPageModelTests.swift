import XCTest
@testable import RoamttyDesktopCore

final class DesktopPageModelTests: XCTestCase {
    func testPanelToggleAndIMEShortcut() {
        let m = DesktopPageModel()
        m.togglePanel(.operations)
        XCTAssertEqual(m.panel, .operations)
        m.togglePanel(.operations)
        XCTAssertEqual(m.panel, .none)
        m.tapModifier(HidUsage.LEFT_CTRL)
        guard case .frames(let frames) = m.commitIME("c", composing: false) else { return XCTFail("a committed character sends frames") }
        XCTAssertEqual(frames.count, 4)
        XCTAssertTrue(frames.contains { $0 == DesktopProtocol.key(HidUsage.LEFT_CTRL, down: true) })
        XCTAssertTrue(frames.contains { $0 == DesktopProtocol.key(HidUsage.letter("c"), down: true) })
    }

    func testIMETextAndNewline() {
        let m = DesktopPageModel()
        guard case .frames(let frames) = m.commitIME("hi\nthere", composing: false) else { return XCTFail("committed text sends frames") }
        XCTAssertEqual(frames[0], DesktopProtocol.text("hi"))
        XCTAssertTrue(frames.contains { $0 == DesktopProtocol.key(HidUsage.ENTER, down: true) })
        XCTAssertEqual(frames.last, DesktopProtocol.text("there"))
        XCTAssertEqual(m.commitIME("x", composing: true), .composingIgnored)
    }

    func testOsSpecificModifiersAndCombos() {
        XCTAssertEqual(DesktopPageModel.modifierKeys(os: "macos").map(\.label), ["⌃", "⌥", "⌘"])
        XCTAssertEqual(DesktopPageModel.comboKeys(os: "windows").map(\.label).first, "Alt+Tab")
        XCTAssertEqual(DesktopPageModel.moreKeys().count, 12 + 12)
        let events = DesktopPageModel().combo([HidUsage.LEFT_ALT, HidUsage.TAB])
        XCTAssertEqual(events.map(\.hid), [HidUsage.LEFT_ALT, HidUsage.TAB, HidUsage.TAB, HidUsage.LEFT_ALT])
        XCTAssertEqual(events.map(\.down), [true, true, false, false])
    }

    func testClipNotesAndQuality() {
        let m = DesktopPageModel(english: false)
        XCTAssertEqual(m.clipSentNote(empty: true), "手机剪贴板为空")
        XCTAssertEqual(m.clipReceivedNote(length: 3), "已复制远程剪贴板（3 字）")
        XCTAssertEqual(m.qualityLabel("clear"), "清晰")
        m.english = true
        XCTAssertEqual(m.qualityLabel("smooth"), "Smooth")
    }
}
