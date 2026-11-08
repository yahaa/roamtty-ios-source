import XCTest

/// Android's tapped paths and localhost previews (roamtty #275) against the live SSH fixture.
final class TerminalLinksUITests: RoamttyLiveUITestCase {
    /// The terminal runs under the status bar, which takes taps: the markers are printed this many rows down.
    private static let markerRow = 4.0
    private static let down = "\\n\\n\\n\\n"
    /// Taps the cell at `column` on the marker's row; `columns` and `rows` are the terminal's size.
    private func tapTopRow(_ surface: XCUIElement, column: Double, columns: Double, rows: Double, hold: TimeInterval = 0) {
        let cell = CGVector(dx: surface.frame.width / columns, dy: surface.frame.height / rows)
        let point = surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (column + 0.5) * cell.dx, dy: (Self.markerRow + 0.5) * cell.dy))
        if hold > 0 { point.press(forDuration: hold) } else { point.tap() }
    }
    /// The terminal's `rows`x`columns`, as the marker line printed them.
    private func size(_ surface: XCUIElement, marker: String) -> (rows: Double, columns: Double)? {
        let value = (surface.value as? String ?? "").replacingOccurrences(of: "\n", with: "")
        guard let regex = try? NSRegularExpression(pattern: marker + "_([0-9]+)x([0-9]+)"),
              let match = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).last,
              let rows = Range(match.range(at: 1), in: value), let columns = Range(match.range(at: 2), in: value) else { return nil }
        return (Double(value[rows]) ?? 0, Double(value[columns]) ?? 0)
    }

    func testTappedPathOpensTheFileAtItsLine() throws {
        let surface = try openTerminal(mode: "SSH")
        let id = String(UUID().uuidString.prefix(6)).lowercased()
        let file = "rt-path-\(id).ts"
        try runCommand("cd /tmp && printf 'first line\\nsecond line %s\\nthird line\\n' \(id) > \(file) && clear && sleep 2 && " +
                       "printf '\(Self.down)%s:2:5 PATHSIZE_%s\\n' \(file) \"$(stty size | tr ' ' x)\"")
        waitForOutput("PATHSIZE_", surface: surface)
        let measured = try XCTUnwrap(size(surface, marker: "PATHSIZE"))
        tapTopRow(surface, column: 3, columns: measured.columns, rows: measured.rows)
        let preview = app.textViews["file-code-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15), "A tapped path that names a file opens it")
        XCTAssertTrue((preview.value as? String ?? "").contains("second line \(id)"))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", file)).firstMatch.exists, "The preview is titled with the file")
        capture("Tapped path opens the file at its line")
        app.buttons["preview-done"].tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        // A path that names no file is an ordinary tap: nothing opens.
        try runCommand("clear && sleep 2 && printf '\(Self.down)missing-\(id).ts:3 GONESIZE_%s\\n' \"$(stty size | tr ' ' x)\"")
        waitForOutput("GONESIZE_", surface: surface)
        // A short press marks the path in the accent colour, underlined, as Android does.
        tapTopRow(surface, column: 3, columns: measured.columns, rows: measured.rows, hold: 0.25)
        capture("Pressed path is marked")
        XCTAssertFalse(preview.waitForExistence(timeout: 4))
        _ = try runCommand("rm -f /tmp/\(file)")
        closeTerminal()
    }

    func testLocalhostLinkAndHostPortOpenInTheApp() throws {
        let surface = try openTerminal(mode: "SSH")
        let port = 18000 + Int.random(in: 0..<1500)
        try runCommand("cd /tmp && (python3 -m http.server \(port) --bind 127.0.0.1 >/dev/null 2>&1 &) && sleep 1 && clear && sleep 2 && " +
                       "printf '\(Self.down)http://localhost:\(port)/ WEBSIZE_%s\\n' \"$(stty size | tr ' ' x)\"")
        waitForOutput("WEBSIZE_", surface: surface)
        let measured = try XCTUnwrap(size(surface, marker: "WEBSIZE"))
        tapTopRow(surface, column: 8, columns: measured.columns, rows: measured.rows)
        XCTAssertTrue(app.descendants(matching: .any)["port-preview"].firstMatch.waitForExistence(timeout: 10), "A loopback link opens in the app")
        let listing = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Directory listing'")).firstMatch
        XCTAssertTrue(listing.waitForExistence(timeout: 20), "The server's page comes through the tunnel")
        let address = app.staticTexts["port-preview-address"]
        XCTAssertTrue(address.label.contains("localhost:\(port)"), address.label)
        capture("Localhost page through the SSH tunnel")
        app.buttons["port-preview-back"].tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        // The host page lists the port with the process behind it, and a tap opens the same page.
        leaveTerminal()
        let row = app.buttons["host-port-\(port)"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<6 where !row.exists || !row.isHittable { scroll.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The host page lists the listening port")
        XCTAssertTrue(row.label.contains("http.server"), row.label)
        capture("Host page ports list")
        row.tap()
        XCTAssertTrue(listing.waitForExistence(timeout: 20))
        app.buttons["port-preview-back"].tap()
        // A port nothing listens on says so.
        try openTerminal(mode: "SSH")
        try runCommand("pkill -f 'http.server \(port)'; clear && sleep 2 && printf '\(Self.down)http://127.0.0.1:\(port)/ DOWNSIZE_%s\\n' \"$(stty size | tr ' ' x)\"")
        let after = app.descendants(matching: .any)["terminal-surface"].firstMatch
        waitForOutput("DOWNSIZE_", surface: after)
        tapTopRow(after, column: 8, columns: measured.columns, rows: measured.rows)
        XCTAssertTrue(app.staticTexts["port-preview-problem"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["port-preview-retry"].exists)
        capture("Port nothing listens on")
        app.buttons["port-preview-back"].tap()
        closeTerminal()
    }
}
