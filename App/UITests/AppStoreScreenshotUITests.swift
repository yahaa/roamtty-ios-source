import XCTest
import UIKit

/// Captures the actual app with a dedicated SSH fixture, without launch debug controls.
final class AppStoreScreenshotUITests: RoamttyLiveUITestCase {
    func testEnglishStoreScreenshots() throws { try captureStore(language: "en") }
    func testChineseStoreScreenshots() throws { try captureStore(language: "zh") }

    override func waitForConnected(timeout: Double = 20) {
        let connected = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'terminal-phase' AND (label == '已连接' OR label == 'Connected')")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: timeout), "The screenshot fixture must connect")
    }

    private func shot(_ name: String, language: String) throws {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let directory = URL(fileURLWithPath: "/tmp/roamtty-appstore/\(device)/\(language)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        capture("App Store \(device) \(language) \(name)")
    }

    private func captureStore(language: String) throws {
        app.buttons["open-drawer"].tap()
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["language-" + language].waitForExistence(timeout: 5))
        app.buttons["language-" + language].tap()
        app.buttons["settings-done"].tap()
        try openHost()
        hostMenu("host-detail-edit")
        replace(app.textFields["host-name"], with: language == "zh" ? "开发服务器" : "Development Server")
        app.buttons["save-host"].tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 5))
        sleep(3)
        try shot("02-monitor", language: language)

        let surface = try openTerminal(directory: "~")
        // The ordinary SSH fixture is enough; do not depend on a manually seeded demo folder.
        // swiftlint:disable:next line_length - one shell command line typed into the terminal
        try runCommand("mkdir -p ~/roamtty-demo && { test -e ~/roamtty-demo/README.md || printf '# Development workspace\\n\\nSample files for Roamtty screenshots.\\n' > ~/roamtty-demo/README.md; } && printf 'STORE_FIXTURE_''READY\\n'")
        waitForOutput("STORE_FIXTURE_READY", surface: surface)
        // swiftlint:disable:next line_length - one shell command line typed into the terminal
        try runCommand("clear; printf '\\n\\n\\033[1;36mDevelopment workspace\\033[0m\\n\\n'; uname -sm; printf '\\nSSH + tmux session\\n\\nProject files\\n'; ls -1 --color=always ~/roamtty-demo; printf '\\nStorage\\n'; df -h / | awk 'NR>1 {print $3 \" used of \" $2 \" (\" $5 \")\"}'; printf '\\nReady for SSH, tmux and SFTP.\\n'")
        waitForOutput("Project files", surface: surface)
        sleep(2)
        try shot("01-terminal", language: language)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        let ghost = app.buttons["terminal-ghost"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 3))
        ghost.press(forDuration: 1.2)
        sleep(1)
        try shot("03-terminal-controls", language: language)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        leaveTerminal()

        app.buttons["host-detail-files"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["files-options"].firstMatch.waitForExistence(timeout: 10))
        let demo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'files-entry-' AND identifier ENDSWITH '/roamtty-demo'")).firstMatch
        XCTAssertTrue(demo.waitForExistence(timeout: 8)); demo.tap()
        sleep(3)
        try shot("04-files", language: language)
    }
}
