import XCTest

final class DraftFocusUITests: RoamttyLiveUITestCase {
    func testPortraitDraftKeepsKeyboardFocusAndSendsCommand() throws {
        XCUIDevice.shared.orientation = .portrait
        let surface = try openTerminal(mode: "SSH")
        terminalMenu("menu-edit-text")
        let editor = app.textViews["prompt-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Opening the keyboard must not recreate the draft editor and drop focus")
        let command = "printf '%s%s\\n' ROAMTTY_ DRAFT_OK"
        editor.typeText(command)
        XCTAssertEqual(editor.value as? String, command)
        app.buttons["prompt-send"].tap()
        app.buttons["prompt-enter"].tap()
        waitForOutput("ROAMTTY_DRAFT_OK", surface: surface)
    }
}
