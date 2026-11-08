import XCTest

/// Exercises document-provider permissions and real SFTP transfers. The simulator
/// runner seeds only source documents; all imports and destinations are picked in UI.
final class NativeFileWorkflowUITests: RoamttyLiveUITestCase {
    func testNativeFolderImportUploadsNestedBytes() throws {
        _ = try openTerminal()
        let base = fixturePath("folder-upload")
        try command("mkdir -m 700 " + quote(base), marker: "FOLDER_READY")
        openRemoteFolder(base)
        filesMenu("files-upload")
        button("上传文件夹", "Upload folder").tap()
        selectDocument("roamtty-ui-folder", folder: true)
        let name = app.textFields["files-upload-name-0"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, "roamtty-ui-folder")
        replace(name, with: "uploaded-folder")
        XCTAssertEqual(app.textFields["files-upload-destination"].value as? String, base)
        app.buttons["files-start-upload"].tap()
        completed("transfer-status-upload-uploaded-folder")
        capture("Native Files folder imported and uploaded recursively")
        app.buttons["transfer-done"].tap()
        closeRemoteBrowser()
        // swiftlint:disable:next line_length - a Python one-liner run on the fixture host
        let script = "import pathlib; p=pathlib.Path(" + pythonString(base + "/uploaded-folder") + "); assert (p/'readme.txt').read_bytes()==b'Roamtty native folder fixture\\n'; assert (p/'nested'/'bytes.bin').read_bytes()==bytes(range(256))"
        try command("python3 -c " + quote(script), marker: "FOLDER_BYTES_VERIFIED")
        for action in ["files-open-terminal", "files-open-agent"] {
            openRemoteFolder(base)
            app.buttons["files-options"].tap()
            app.buttons[action].tap()
            let launch = app.buttons["launch-session"]
            XCTAssertTrue(launch.waitForExistence(timeout: 10))
            wait(NSPredicate(format: "isEnabled == true"), on: launch, timeout: 20)
            XCTAssertEqual(app.textFields["launch-directory"].value as? String, base)
            app.buttons["launch-cancel"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 8))
            XCTAssertTrue(phase("已连接").exists)
            XCTAssertFalse(app.buttons["files-picker-done"].exists)
        }
        try removeFixture(base)
    }

    func testCancelLargeDownloadKeepsSSHAliveAndDoesNotPublishFile() throws {
        _ = try openTerminal()
        let base = fixturePath("cancel")
        let filename = "cancel-" + String(UUID().uuidString.prefix(8)) + ".bin"
        let remote = base + "/" + filename
        // Sparse on the fixture server: enough real bytes to keep the transfer
        // running until the user can cancel, without allocating a giant source.
        try command("mkdir -m 700 " + quote(base) + " && truncate -s 1073741824 " + quote(remote), marker: "CANCEL_SOURCE_READY")
        openRemoteFolder(base)
        let file = app.buttons["files-entry-" + remote]
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.press(forDuration: 0.8)
        app.buttons["files-action-download"].tap()
        let status = app.staticTexts["transfer-status-download-" + filename]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(["下载中", "Downloading"].contains(status.label), "Cancellation must interrupt a real running transfer")
        let cancel = button("取消", "Cancel")
        XCTAssertTrue(cancel.isHittable); cancel.tap()
        wait(NSPredicate(format: "label == '已取消' OR label == 'Cancelled'"), on: status)
        XCTAssertFalse(app.buttons["transfer-share-" + filename].exists, "A cancelled partial file must not become a completed artifact")
        capture("Cancelled transfer preserves its own cancelled state")
        app.buttons["transfer-done"].tap(); closeRemoteBrowser()
        try command("test \"$(stat -c %s " + quote(remote) + ")\" = 1073741824", marker: "SSH_ALIVE_AFTER_CANCEL")

        // Verify publication through the actual Files picker, not a mocked job.
        openRemoteFolder(base)
        filesMenu("files-upload"); button("上传文件", "Upload files").tap()
        navigateToDocuments()
        let downloads = documentCell("Downloads")
        XCTAssertTrue(downloads.waitForExistence(timeout: 8)); downloads.tap()
        XCTAssertFalse(documentCell(filename).exists, "The cancelled download must not be visible as a final local file")
        documentNavigation.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["files-picker-done"].waitForExistence(timeout: 8))
        closeRemoteBrowser()
        try removeFixture(base)
    }

    func testImportedFontAndChosenDownloadFolderSurviveRelaunch() throws {
        openSettings()
        app.buttons["theme-system"].tap()
        let importFont = app.buttons["settings-font-import"]
        revealSetting(importFont); importFont.tap()
        selectDocument("roamtty-ui-custom-font", folder: false)
        let font = app.buttons["settings-font"]
        XCTAssertTrue(font.waitForExistence(timeout: 10))
        wait(NSPredicate(format: "value == 'AndaleMono'"), on: font)
        let downloads = app.buttons["settings-download-folder"]
        revealSetting(downloads); downloads.tap()
        selectDocument("roamtty-ui-downloads", folder: true)
        XCTAssertTrue(downloads.waitForExistence(timeout: 10))
        XCTAssertTrue(downloads.label.contains("自定义目录") || downloads.label.contains("Custom folder"))
        app.buttons["settings-done"].tap()
        app.terminate(); app.launch()
        openSettings()
        XCTAssertTrue(app.buttons["theme-system"].isSelected)
        revealSetting(font); XCTAssertEqual(font.value as? String, "AndaleMono")
        revealSetting(downloads)
        XCTAssertTrue(downloads.label.contains("自定义目录") || downloads.label.contains("Custom folder"))
        capture("Imported font and document-provider download folder persisted")

        // Imported fonts remain available after choosing a bundled face, and
        // reimporting the same file must not fail with CoreText AlreadyRegistered.
        revealSetting(font); font.tap()
        XCTAssertTrue(app.buttons["FiraCode"].waitForExistence(timeout: 5)); app.buttons["FiraCode"].tap()
        wait(NSPredicate(format: "value == 'FiraCode'"), on: font)
        font.tap()
        let custom = app.buttons.matching(NSPredicate(format: "identifier == 'settings-font-custom' OR label == 'roamtty-ui-custom-font.ttf'")).firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 5)); custom.tap()
        wait(NSPredicate(format: "value == 'AndaleMono'"), on: font)
        revealSetting(importFont); importFont.tap()
        selectDocument("roamtty-ui-custom-font", folder: false)
        wait(NSPredicate(format: "value == 'AndaleMono'"), on: font)
        XCTAssertFalse(app.staticTexts["settings-font-error"].exists)

        revealSetting(importFont); importFont.tap()
        selectDocument("roamtty-ui-invalid-font", folder: false)
        XCTAssertTrue(app.staticTexts["settings-font-error"].waitForExistence(timeout: 8))
        XCTAssertEqual(font.value as? String, "AndaleMono", "A rejected import must retain the last valid custom font")
        let clear = app.buttons["settings-font-clear-custom"]
        revealSetting(clear); clear.tap()
        wait(NSPredicate(format: "value == 'JetBrainsMono'"), on: font)
        XCTAssertFalse(clear.exists)
        XCTAssertFalse(app.staticTexts["settings-font-error"].exists)
        revealSetting(font); font.tap()
        let system = app.buttons.matching(NSPredicate(format: "identifier == 'settings-font-system' OR label == '系统等宽' OR label == 'System monospace'")).firstMatch
        XCTAssertTrue(system.waitForExistence(timeout: 5)); system.tap()
        wait(NSPredicate(format: "value == '系统等宽' OR value == 'System monospace'"), on: font)
        capture("Custom font reselect, repeat import, validation, clear and system monospace")
        app.buttons["settings-done"].tap()

        _ = try openTerminal()
        let base = fixturePath("bookmark")
        let filename = "bookmark-" + String(UUID().uuidString.prefix(8)) + ".txt"
        let payload = "BOOKMARK_CONTENT_" + UUID().uuidString
        try command("mkdir -m 700 " + quote(base) + " && printf '%s' " + quote(payload) + " > " + quote(base + "/" + filename), marker: "BOOKMARK_READY")
        openRemoteFolder(base)
        let source = app.buttons["files-entry-" + base + "/" + filename]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.press(forDuration: 0.8)
        app.buttons["files-action-download"].tap()
        completed("transfer-status-download-" + filename)
        app.buttons["transfer-done"].tap()
        filesMenu("files-upload")
        button("上传文件", "Upload files").tap()
        navigateToDocuments()
        let chosenFolder = documentCell("roamtty-ui-downloads")
        XCTAssertTrue(chosenFolder.waitForExistence(timeout: 8)); chosenFolder.tap()
        let downloaded = documentCell(filename)
        XCTAssertTrue(downloaded.waitForExistence(timeout: 8), "The download must be inside the folder chosen before relaunch")
        downloaded.tap(); finishDocumentSelection()
        let uploadName = app.textFields["files-upload-name-0"]
        XCTAssertTrue(uploadName.waitForExistence(timeout: 10)); replace(uploadName, with: "roundtrip.txt")
        app.buttons["files-start-upload"].tap(); completed("transfer-status-upload-roundtrip.txt")
        app.buttons["transfer-done"].tap(); closeRemoteBrowser()
        try command("cmp -s " + quote(base + "/" + filename) + " " + quote(base + "/roundtrip.txt"), marker: "BOOKMARK_BYTES_VERIFIED")
        try removeFixture(base)
    }

    private func openSettings() {
        XCTAssertTrue(app.buttons["open-drawer"].waitForExistence(timeout: 8)); app.buttons["open-drawer"].tap()
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 5))
    }
    private func revealSetting(_ item: XCUIElement) {
        let scroll = app.scrollViews["settings-scroll"]
        for _ in 0..<6 {
            let top = app.navigationBars.firstMatch.frame.maxY
            if item.exists && item.isHittable && item.frame.minY > top && item.frame.maxY < app.frame.maxY { return }
            if item.exists && item.frame.minY <= top { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        XCTAssertTrue(item.isHittable)
    }
    private func selectDocument(_ name: String, folder: Bool) {
        XCTAssertTrue(documentNavigation.waitForExistence(timeout: 10))
        if !documentCell(name).waitForExistence(timeout: 2) { navigateToDocuments() }
        let file = documentCell(name)
        XCTAssertTrue(file.waitForExistence(timeout: 8), "Seed the native document fixture before running this suite")
        file.tap()
        if folder { finishDocumentSelection() }
    }
    private func navigateToDocuments() {
        XCTAssertTrue(documentNavigation.waitForExistence(timeout: 10))
        // The picker remembers its last folder across invocations. Browse returns
        // to its locations list; otherwise follow its native back buttons there.
        for _ in 0..<7 {
            let local = app.cells.matching(NSPredicate(format: "label CONTAINS 'On My iPhone' OR label CONTAINS '我的 iPhone' OR label CONTAINS '我的iPhone'")).firstMatch
            if local.exists { local.tap(); break }
            if documentCell("Roamtty").exists { break }
            let back = documentNavigation.buttons["BackButton"]
            if back.exists { back.tap(); continue }
            let browse = app.tabBars["DOC.browsingModeTabBar"].buttons.matching(NSPredicate(format: "label == '浏览' OR label == 'Browse'")).firstMatch
            XCTAssertTrue(browse.exists, "The native picker must expose its Browse tab"); browse.tap()
        }
        let roamtty = documentCell("Roamtty")
        XCTAssertTrue(roamtty.waitForExistence(timeout: 8)); roamtty.tap()
    }
    private func finishDocumentSelection() {
        // Underlying sheets remain in the accessibility tree. Limit the action
        // to the document provider's navigation bar, never their Done buttons.
        let open = documentNavigation.buttons.matching(NSPredicate(format: "label == 'Open' OR label == '打开' OR label == 'Done' OR label == '完成' OR label == 'Choose' OR label == '选取'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5)); XCTAssertTrue(open.isEnabled); open.tap()
    }
    private var documentNavigation: XCUIElement { app.navigationBars["FullDocumentManagerViewControllerNavigationBar"] }
    private func documentCell(_ name: String) -> XCUIElement {
        // Files hides common extensions, while imported font names retain .ttf.
        let stem = (name as NSString).deletingPathExtension
        return app.cells.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", name, name + ",", name + ".", stem + ",")).firstMatch
    }
    private func openRemoteFolder(_ path: String) {
        openTools(); app.buttons["download-file"].tap()
        filesMenu("files-select")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); replace(search, with: path); search.typeText("\n")
        let folder = app.buttons["files-entry-" + path]
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.tap()
        XCTAssertTrue(app.buttons["files-breadcrumb-" + path].waitForExistence(timeout: 15))
    }
    private func closeRemoteBrowser() {
        let done = app.buttons["files-picker-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8)); done.tap()
        wait(NSPredicate(format: "exists == false"), on: done)
    }
    private func completed(_ identifier: String) {
        let status = app.staticTexts[identifier]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        wait(NSPredicate(format: "label == '已完成' OR label == 'Completed'"), on: status, timeout: 45)
    }
    private func button(_ chinese: String, _ english: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", chinese, english)).firstMatch
    }
    private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: Double = 8) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout), .completed)
    }
    private func command(_ text: String, marker: String) throws {
        let half = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        let emit = "printf '%s' " + quote(String(marker[..<half])) + "; printf '%s\\n' " + quote(String(marker[half...]))
        let surface = try runCommand(text + " && { " + emit + "; }")
        waitForOutput(marker, surface: surface)
    }
    private func fixturePath(_ purpose: String) -> String { "/tmp/roamtty-ios-ui-" + purpose + "-" + UUID().uuidString }
    private func removeFixture(_ path: String) throws {
        XCTAssertTrue(path.hasPrefix("/tmp/roamtty-ios-ui-"))
        try command("rm -rf -- " + quote(path), marker: "NATIVE_FIXTURE_REMOVED")
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func pythonString(_ value: String) -> String { "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
}
