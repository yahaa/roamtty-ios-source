import Foundation
import XCTest

final class PreviewSettingsUITests: RoamttyLiveUITestCase {
    func testSearchFullscreenAndIndependentPreviewPreferencesPersistAcrossRelaunch() throws {
        openSettings()
        let slider = app.sliders["settings-font-size"]
        revealSetting(slider); slider.adjust(toNormalizedSliderPosition: 0.5)
        let terminalSize = app.staticTexts["settings-font-size-value"].label
        XCTAssertNotEqual(terminalSize, "13 pt")
        app.buttons["settings-done"].tap()

        let surface = try openTerminal(mode: "SSH")
        let base = "/tmp/roamtty-ios-ui-preview-options-" + UUID().uuidString
        let text = "Alpha alpha\nbeta ALPHA\n" + String(repeating: "A long source line to exercise wrapping. ", count: 12) + "\n"
        let markdown = "# Preview settings fixture\n\n**Rendered content** and `inline code`.\n"
        let ready = "PREVIEW_OPTIONS_READY_" + nonce()
        try runCommand("mkdir -m 700 " + quote(base) + " && mkdir " + quote(base + "/existing") + " && "
            + write(text, to: base + "/one.txt") + " && " + write(text, to: base + "/two.txt") + " && "
            + write(markdown, to: base + "/README.md") + " && " + emit(ready))
        waitForOutput(ready, surface: surface)
        openRemoteFolder(base)
        openPreview(base + "/one.txt")
        assertPreview(size: "13 pt", wrapped: false)

        option("preview-find")
        let search = app.textFields["preview-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); replace(search, with: "alpha")
        assertSearchCount("1/3")
        app.buttons["preview-search-previous"].tap(); assertSearchCount("3/3")
        app.buttons["preview-search-next"].tap(); assertSearchCount("1/3")
        replace(search, with: "1")
        let count = app.staticTexts["preview-search-count"]
        waitFor(NSPredicate(format: "label == '无结果' OR label == 'No results'"), count)
        XCTAssertFalse(app.buttons["preview-search-next"].isEnabled)
        XCTAssertFalse(app.buttons["preview-search-previous"].isEnabled)
        // A source line numbered 1 must not create a match for a gutter digit.
        capture("Preview counts source matches and previous wraps")
        app.buttons["preview-search-close"].tap()

        option("preview-font-larger"); option("preview-font-larger"); option("preview-wrap")
        assertPreview(size: "15 pt", wrapped: true)
        option("preview-fullscreen")
        let fullText = app.textViews["file-code-fullscreen"]
        XCTAssertTrue(fullText.waitForExistence(timeout: 5)); XCTAssertTrue((fullText.value as? String ?? "").contains("Alpha alpha"))
        XCTAssertFalse(app.buttons["preview-done"].isHittable)
        capture("Wrapped source fullscreen")
        app.buttons["preview-fullscreen-close"].tap()
        XCTAssertTrue(app.textViews["file-code-preview"].waitForExistence(timeout: 5))
        app.buttons["preview-done"].tap()

        openPreview(base + "/two.txt")
        assertPreview(size: "15 pt", wrapped: true)
        app.buttons["preview-done"].tap()
        entry(base + "/README.md").tap()
        XCTAssertTrue(app.staticTexts["Preview settings fixture"].waitForExistence(timeout: 15))
        option("preview-fullscreen")
        let fullMarkdown = app.scrollViews["file-markdown-fullscreen"].firstMatch
        XCTAssertTrue(fullMarkdown.waitForExistence(timeout: 5))
        // The covered preview contains the same heading. Resolve the foreground
        // scroll view's copy, then wait for the fullscreen transition to settle.
        let fullscreenHeading = fullMarkdown.staticTexts["Preview settings fixture"]
        waitFor(NSPredicate(format: "exists == true AND hittable == true"), fullscreenHeading)
        XCTAssertTrue(fullMarkdown.frame.contains(fullscreenHeading.frame))
        XCTAssertTrue(app.buttons["preview-fullscreen-close"].isHittable)
        capture("Rendered Markdown fullscreen")
        app.buttons["preview-fullscreen-close"].tap()
        option("preview-render-markdown")
        XCTAssertTrue(app.textViews["file-code-preview"].waitForExistence(timeout: 5))
        option("preview-fullscreen")
        XCTAssertTrue(fullText.waitForExistence(timeout: 5)); XCTAssertTrue((fullText.value as? String ?? "").contains("# Preview settings fixture"))
        app.buttons["preview-fullscreen-close"].tap()
        app.buttons["preview-done"].tap()

        // A server mutation failure must stay visible in this child browser,
        // with dismissal restoring normal list actions.
        menu("files-options").tap(); app.buttons["files-new-folder"].tap()
        let folderName = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(folderName.waitForExistence(timeout: 5)); replace(folderName, with: "existing")
        app.alerts.firstMatch.buttons.matching(identifier: "files-create-folder").firstMatch.tap()
        let failure = app.staticTexts["files-operation-error"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["files-operation-error-dismiss"].isHittable)
        capture("Duplicate mkdir error is visible inside terminal file picker")
        app.buttons["files-operation-error-dismiss"].tap(); waitFor(NSPredicate(format: "exists == false"), failure)
        XCTAssertTrue(entry(base + "/existing").isHittable)
        closeBrowser(); closeTerminal()

        app.terminate(); app.launch()
        let resumed = try openTerminal(mode: "SSH")
        openRemoteFolder(base); openPreview(base + "/two.txt")
        assertPreview(size: "15 pt", wrapped: true)
        capture("Independent preview font and wrap survive app restart")
        app.buttons["preview-done"].tap(); closeBrowser()
        let cleaned = "PREVIEW_OPTIONS_CLEANED_" + nonce()
        try runCommand("rm -rf -- " + quote(base) + " && test ! -e " + quote(base) + " && " + emit(cleaned))
        waitForOutput(cleaned, surface: resumed); closeTerminal()
        // Closing a terminal already returns to the home sessions tab.
        // openSettings verifies that the home drawer is present before entering it.
        openSettings()
        revealSetting(app.staticTexts["settings-font-size-value"])
        XCTAssertEqual(app.staticTexts["settings-font-size-value"].label, terminalSize, "Preview font changes must not alter terminal font size")
        app.buttons["settings-done"].tap()
    }

    private func openSettings() {
        XCTAssertTrue(app.buttons["open-drawer"].waitForExistence(timeout: 8)); app.buttons["open-drawer"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 5)); app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 5))
    }
    private func revealSetting(_ element: XCUIElement) {
        let scroll = app.scrollViews["settings-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if element.exists && element.isHittable && scroll.frame.contains(element.frame) { return }
            scroll.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    private func openRemoteFolder(_ path: String) {
        openTools(); app.buttons["download-file"].tap()
        filesMenu("files-select")
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); replace(search, with: path); search.typeText("\n")
        XCTAssertTrue(entry(path).waitForExistence(timeout: 15)); entry(path).tap()
        XCTAssertTrue(app.buttons["files-breadcrumb-" + path].waitForExistence(timeout: 15))
    }
    private func openPreview(_ path: String) {
        XCTAssertTrue(entry(path).waitForExistence(timeout: 8)); entry(path).tap()
        XCTAssertTrue(app.textViews["file-code-preview"].waitForExistence(timeout: 15))
    }
    private func assertPreview(size: String, wrapped: Bool) {
        waitFor(NSPredicate(format: "label == %@", size), app.staticTexts["preview-font-size"])
        waitFor(NSPredicate(format: wrapped ? "label == '换行' OR label == 'Wrapped'" : "label == '不换行' OR label == 'No wrap'"), app.staticTexts["preview-wrap-status"])
    }
    private func assertSearchCount(_ count: String) { waitFor(NSPredicate(format: "label == %@", count), app.staticTexts["preview-search-count"]) }
    private func option(_ identifier: String) {
        menu("preview-options").tap()
        let control = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5)); control.tap()
    }
    private func closeBrowser() {
        let done = app.buttons["files-picker-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap(); waitFor(NSPredicate(format: "exists == false"), done)
    }
    private func waitFor(_ predicate: NSPredicate, _ element: XCUIElement) {
        let check = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 8), .completed)
    }
    private func menu(_ identifier: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: identifier).firstMatch }
    private func entry(_ path: String) -> XCUIElement { app.buttons["files-entry-" + path] }
    private func nonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func write(_ text: String, to path: String) -> String { "printf '%s' " + quote(Data(text.utf8).base64EncodedString()) + " | base64 -d > " + quote(path) }
    private func emit(_ marker: String) -> String {
        let split = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        return "{ printf '%s' " + quote(String(marker[..<split])) + "; printf '%s\\n' " + quote(String(marker[split...])) + "; }"
    }
}
