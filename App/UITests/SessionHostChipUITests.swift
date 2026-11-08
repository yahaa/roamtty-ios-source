import XCTest

final class SessionHostChipUITests: RoamttyLiveUITestCase {
    /// A session card names its host on a chip beside its name, and a plain tmux terminal its folder beneath it.
    func testSessionCardShowsItsHostChipAndFolder() throws {
        try openTerminal(directory: "/tmp", mode: "tmux")
        leaveTerminal()
        let card = try XCTUnwrap(homeSessionCards().allElementsBoundByIndex.first)
        let id = String(card.identifier.dropFirst("home-session-".count))
        let chip = app.descendants(matching: .any)["home-session-host-" + id].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        XCTAssertTrue(chip.label.contains("UI Live Host"), chip.label)
        let location = app.descendants(matching: .any)["home-session-location-" + id].firstMatch
        let shown = location.waitForExistence(timeout: 15)
        capture("Session card with host chip")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/roamtty-host-chip.png"))
        XCTAssertTrue(shown)
        XCTAssertEqual(location.label, "/tmp")
        card.press(forDuration: 1)
        let close = app.buttons["home-session-close-" + id]
        XCTAssertTrue(close.waitForExistence(timeout: 3)); close.tap()
    }
}
