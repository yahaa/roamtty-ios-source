import XCTest

final class FilesUITests: RoamttyLiveUITestCase {
    private let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP4z8DAAMIM/4EAAB/uBfsL2WiLAAAAAElFTkSuQmCC"

    func testNativePhotoPickerUploadsPNGAndInsertsWithoutEnter() throws {
        let surface = try openTerminal()
        // A saved host edit must not retarget file actions from its already-connected
        // terminal. Port 1 cannot serve the fixture; all following uploads and remote
        // PNG checks must keep using the initiating session's original SSH connection.
        leaveTerminal()
        hostMenu("host-detail-edit")
        let port = app.textFields["host-port"]
        XCTAssertTrue(port.waitForExistence(timeout: 5)); replace(port, with: "1")
        app.buttons["save-host"].tap()
        waitUntilGone(app.buttons["save-host"])
        let existingSession = homeSessionCards().firstMatch
        XCTAssertTrue(existingSession.waitForExistence(timeout: 8))
        let sessionIdentifier = existingSession.identifier
        let retainedSession = app.descendants(matching: .any)[sessionIdentifier].firstMatch
        XCTAssertTrue(sessionConnected(sessionIdentifier), "Editing the saved endpoint must retain the original connected session")
        retainedSession.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 8))
        let submitted = "PHOTO_SENT_" + shortID()
        typeIntoTerminal(emit(submitted) + "; :")
        app.buttons.matching(NSPredicate(format: "label == '收起' OR label == 'Hide'")).firstMatch.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        openTools(); app.buttons["select-image"].tap()
        // The dedicated simulator contains a real PNG seeded using `simctl addmedia`.
        let photos = app.scrollViews["photosView_content_scroll_view"]
        XCTAssertTrue(photos.waitForExistence(timeout: 15), "The native Photos picker must open")
        let photo = photos.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "The native Photos picker must expose seeded media")
        capture("Native Photos picker")
        // Photos exposes the visible thumbnail but returns an invalid AX hit point.
        // Tap its verified on-screen center, then require Done to become enabled.
        let center = CGPoint(x: photo.frame.midX, y: photo.frame.midY)
        XCTAssertGreaterThan(photo.frame.width, 0); XCTAssertGreaterThan(photo.frame.height, 0)
        XCTAssertTrue(photos.frame.contains(center)); XCTAssertTrue(app.frame.contains(center))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add' OR label BEGINSWITH '添加' OR label == 'Done' OR label == '完成'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: add)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        add.tap()

        // As on Android, a progress dialog follows the upload and gives way to a short top notice once the path is in.
        let dialog = app.descendants(matching: .any)["image-insert-dialog"]
        // The notice lives two seconds, so watch for it directly rather than after the dialog's slower poll.
        XCTAssertTrue(app.descendants(matching: .any)["top-notice"].waitForExistence(timeout: 30))
        XCTAssertFalse(dialog.exists)
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        // The inserted path names the upload: /tmp/roamtty-img-<UUID>.png.
        var path = ""
        expectation(for: NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String,
                  let range = value.filter({ !$0.isWhitespace }).range(of: #"/tmp/roamtty-img-[0-9A-Fa-f-]{36}\.png"#, options: .regularExpression) else { return false }
            path = String(value.filter { !$0.isWhitespace }[range]); return true
        }, evaluatedWith: surface)
        waitForExpectations(timeout: 40)
        XCTAssertNotNil(UUID(uuidString: String(path.dropFirst("/tmp/roamtty-img-".count).dropLast(4))))
        let prematureSubmit = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", submitted), object: surface)
        prematureSubmit.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [prematureSubmit], timeout: 2), .completed, "Attaching an image must not press Enter")
        capture("PNG path inserted without submitting")

        showTerminalKeyboard()
        surface.typeText("\n")
        waitForOutput(submitted, surface: surface)
        let verified = "PNG_VALID_" + shortID()
        let verifiedSurface = try runCommand("test \"$(od -An -tx1 -N8 " + quote(path) + " | tr -d ' \\n')\" = 89504e470d0a1a0a && " + emit(verified))
        waitForOutput(verified, surface: verifiedSurface)
        let removed = "PNG_REMOVED_" + shortID()
        let cleaned = try runCommand("rm -- " + quote(path) + " && " + emit(removed))
        waitForOutput(removed, surface: cleaned)

        // The retained tmux card must reconnect to the same original host, even
        // though the edited saved profile still has its deliberately invalid port.
        try detachTerminal()
        _ = homeSessionCards()
        XCTAssertTrue(retainedSession.waitForExistence(timeout: 8)); retainedSession.tap()
        let reconnect = app.buttons["terminal-reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 8)); reconnect.tap()
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 20))
        let resumed = "ORIGINAL_SESSION_" + shortID()
        let replacementSurface = try runCommand(emit(resumed))
        waitForOutput(resumed, surface: replacementSurface)
        capture("Original session reconnected after the saved endpoint changed")
    }

    func testRemoteManagementHiddenFuzzySearchAndBatchDownloads() throws {
        _ = try openTerminal()
        let base = fixturePath("files")
        let ready = "FILES_READY_" + shortID()
        let create = "mkdir -m 700 " + quote(base) + " && mkdir " + quote(base + "/nested-one") + " " + quote(base + "/nested-two")
            + " && " + write("one\n", to: base + "/nested-one/result.txt")
            + " && " + write("two\n", to: base + "/nested-two/result.txt")
            + " && " + write("hidden\n", to: base + "/.hidden.txt") + " && " + emit(ready)
        let surface = try runCommand(create); waitForOutput(ready, surface: surface)
        openRemoteFolder(base)

        menu("files-options").tap(); app.buttons["files-new-folder"].tap()
        let createAlert = app.alerts.firstMatch
        XCTAssertTrue(createAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(["新建文件夹", "New folder"].contains(createAlert.label), "Folder creation must open its native confirmation alert")
        // Native SwiftUI alert text fields do not retain their SwiftUI IDs on this runtime.
        let folderName = createAlert.textFields.firstMatch
        XCTAssertTrue(folderName.waitForExistence(timeout: 5)); folderName.typeText("created-folder")
        createAlert.buttons.matching(identifier: "files-create-folder").firstMatch.tap()
        let created = entry(base + "/created-folder")
        XCTAssertTrue(created.waitForExistence(timeout: 10)); created.press(forDuration: 0.8)
        app.buttons["files-action-rename"].tap()
        let renameAlert = app.alerts.firstMatch
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(["重命名", "Rename"].contains(renameAlert.label), "Renaming must open its native confirmation alert")
        let rename = renameAlert.textFields.firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertEqual(rename.value as? String, "created-folder")
        // UIAlertController already focuses this field at the end or with its
        // contents selected. Preserve that focus instead of opening its transient
        // edit menu, whose accessibility representation can disappear mid-tap.
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "created-folder".utf16.count))
        rename.typeText("renamed-folder")
        XCTAssertEqual(rename.value as? String, "renamed-folder")
        renameAlert.buttons.matching(identifier: "files-rename-save").firstMatch.tap()
        let renamed = entry(base + "/renamed-folder")
        XCTAssertTrue(renamed.waitForExistence(timeout: 10)); XCTAssertFalse(created.exists)

        entry(base + "/nested-one").press(forDuration: 0.8)
        app.buttons["files-action-download"].tap()
        waitUntilCompleted(app.staticTexts["transfer-status-download-nested-one"])
        XCTAssertTrue(app.buttons["transfer-share-nested-one"].exists, "The recursive directory must be published as a shareable local artifact")
        app.buttons["transfer-done"].tap()
        XCTAssertTrue(renamed.waitForExistence(timeout: 8)); renamed.press(forDuration: 0.8)
        app.buttons["files-action-delete"].tap()
        let delete = app.buttons.matching(identifier: "files-delete-confirm").firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        waitUntilGone(renamed)

        let hidden = entry(base + "/.hidden.txt")
        XCTAssertFalse(hidden.exists)
        menu("files-options").tap()
        let toggleHidden = app.descendants(matching: .any)["files-show-hidden"].firstMatch
        XCTAssertTrue(toggleHidden.waitForExistence(timeout: 5)); toggleHidden.tap()
        XCTAssertTrue(hidden.waitForExistence(timeout: 8))
        searchRemote(base + "/nst-/rst")
        let first = entry(base + "/nested-one/result.txt"), second = entry(base + "/nested-two/result.txt")
        XCTAssertTrue(first.waitForExistence(timeout: 15)); XCTAssertTrue(second.exists)
        filesMenu("files-select"); first.tap(); second.tap()
        for selected in [first, second] { XCTAssertTrue(["Selected", "已选择"].contains(selected.value as? String ?? "")) }
        capture("Fuzzy paths with selections from two folders")
        let batch = app.buttons["files-download-selected"]
        XCTAssertTrue(batch.isEnabled); XCTAssertTrue(batch.label.contains("2")); batch.tap()
        waitUntilCompleted(app.staticTexts["transfer-status-download-result.txt"])
        waitUntilCompleted(app.staticTexts["transfer-status-download-result (2).txt"])
        XCTAssertTrue(app.buttons["transfer-share-result.txt"].exists)
        XCTAssertTrue(app.buttons["transfer-share-result (2).txt"].exists)
        app.buttons["transfer-done"].tap(); closeRemoteBrowser()

        let verified = "FILES_CHECK_" + shortID()
        let check = "test ! -e " + quote(base + "/created-folder") + " && test ! -e " + quote(base + "/renamed-folder")
            + " && test \"$(cat " + quote(base + "/nested-one/result.txt") + ")\" = one"
            + " && test \"$(cat " + quote(base + "/nested-two/result.txt") + ")\" = two && " + emit(verified)
        let checked = try runCommand(check); waitForOutput(verified, surface: checked)
        try removeFixture(base)
    }

    func testTextMarkdownAndImagePreviewControls() throws {
        _ = try openTerminal()
        let base = fixturePath("previews"), ready = "PREVIEW_READY_" + shortID()
        let source = "let answer = 42 // NEEDLE\n" + String(repeating: "// Long preview line with several words and NEEDLE that should wrap on a narrow phone display.\n", count: 3)
        let relativeImageAlt = "Relative PNG fixture " + shortID()
        let webImageAlt = "Web PNG fixture " + shortID()
        let imageReference = "![\(relativeImageAlt)](./nested/../image.png?raw=1#preview)"
        let webImageReference = "![\(webImageAlt)](http://127.0.0.1:1/roamtty-no-autoload.png)"
        let markdown = "# File preview heading\n\n**Rendered content** and `inline code`.\n\n" + webImageReference + "\n\n" + imageReference + "\n\n- First item\n- Second item\n"
        let create = "mkdir -m 700 " + quote(base) + " && " + write(source, to: base + "/sample.swift")
            + " && " + write(markdown, to: base + "/readme.md")
            + " && printf '%s' " + quote(tinyPNG) + " | base64 -d > " + quote(base + "/image.png") + " && " + emit(ready)
        let surface = try runCommand(create); waitForOutput(ready, surface: surface)
        openRemoteFolder(base)
        entry(base + "/sample.swift").tap()
        let code = app.textViews["file-code-preview"]
        XCTAssertTrue(code.waitForExistence(timeout: 15)); XCTAssertTrue((code.value as? String ?? "").contains("let answer = 42"))
        menu("preview-options").tap(); app.buttons["preview-find"].tap()
        let find = app.textFields["preview-search"]
        XCTAssertTrue(find.waitForExistence(timeout: 5)); find.tap(); find.typeText("NEEDLE")
        app.buttons["preview-search-next"].tap(); app.buttons["preview-search-previous"].tap()
        XCTAssertEqual(find.value as? String, "NEEDLE")
        capture("Source preview search highlighting")
        app.buttons["preview-search-close"].tap()
        menu("preview-options").tap(); app.descendants(matching: .any)["preview-wrap"].firstMatch.tap()
        menu("preview-options").tap(); app.buttons["preview-font-larger"].tap()
        menu("preview-options").tap(); app.buttons["preview-font-smaller"].tap()
        XCTAssertTrue((code.value as? String ?? "").contains("let answer = 42"))
        capture("Wrapped syntax preview")
        app.buttons["preview-done"].tap()

        XCTAssertTrue(entry(base + "/readme.md").waitForExistence(timeout: 8)); entry(base + "/readme.md").tap()
        XCTAssertTrue(app.staticTexts["File preview heading"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textViews["file-code-preview"].exists)
        menu("preview-options").tap(); app.descendants(matching: .any)["preview-render-markdown"].firstMatch.tap()
        XCTAssertTrue(code.waitForExistence(timeout: 5)); XCTAssertTrue((code.value as? String ?? "").contains("# File preview heading"))
        XCTAssertTrue((code.value as? String ?? "").contains(imageReference))
        XCTAssertTrue((code.value as? String ?? "").contains(webImageReference))
        menu("preview-options").tap(); app.descendants(matching: .any)["preview-render-markdown"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["File preview heading"].waitForExistence(timeout: 5))
        let markdownPreview = app.scrollViews["file-markdown-preview"].firstMatch
        XCTAssertTrue(markdownPreview.waitForExistence(timeout: 5))
        let relativeImage = markdownPreview.images.matching(NSPredicate(format: "label == %@", relativeImageAlt)).firstMatch
        // RemoteMarkdownImage's loaded branch exposes an Image with this alt
        // label. Its unloaded Label/icon cannot satisfy the large square frame.
        let decodedImage = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard relativeImage.exists, relativeImage.isHittable else { return false }
            let frame = relativeImage.frame
            return frame.width > 100 && frame.height > 100 && frame.height <= 480 && abs(frame.width - frame.height) <= 1
                && markdownPreview.frame.contains(frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [decodedImage], timeout: 15), .completed, "The relative PNG must load from the README's remote directory and render as an actual image")
        // SwiftUI Link exposes a native Button in the iOS accessibility tree.
        let webImageLink = markdownPreview.buttons.matching(NSPredicate(format: "label == %@", webImageAlt)).firstMatch
        XCTAssertTrue(webImageLink.waitForExistence(timeout: 5), "Web images must remain explicit native links; previewing a document must not fetch them")
        XCTAssertTrue(webImageLink.isHittable)
        XCTAssertLessThan(webImageLink.frame.height, 80, "The web image stays a compact placeholder after the relative image has loaded")
        capture("Rendered remote Markdown")
        app.buttons["preview-done"].tap()

        XCTAssertTrue(entry(base + "/image.png").waitForExistence(timeout: 8)); entry(base + "/image.png").tap()
        let image = app.descendants(matching: .any)["file-image-preview"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["preview-image-dimensions"].label, "2 × 2")
        image.pinch(withScale: 2, velocity: 1)
        image.doubleTap()
        let full = app.descendants(matching: .any)["file-image-fullscreen"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 8))
        capture("Full screen remote PNG")
        app.buttons["preview-image-close"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        app.buttons["preview-done"].tap(); closeRemoteBrowser()
        try removeFixture(base)
    }

    func testSharedUploadRejectsCollisionAndUsesChosenDirectory() throws {
        _ = try openTerminal()
        let base = fixturePath("upload"), ready = "UPLOAD_READY_" + shortID()
        let original = "ORIGINAL_" + shortID()
        let create = "mkdir -m 700 " + quote(base) + " && mkdir " + quote(base + "/destination")
            + " && " + write(original + "\n", to: base + "/collision.txt") + " && " + emit(ready)
        let surface = try runCommand(create); waitForOutput(ready, surface: surface)
        openRemoteFolder(base); entry(base + "/collision.txt").tap()
        XCTAssertTrue(app.textViews["file-code-preview"].waitForExistence(timeout: 15))
        app.buttons["preview-download"].tap()
        waitUntilCompleted(app.staticTexts["transfer-status-download-collision.txt"])
        shareDownloadedFile("collision.txt")
        for identifier in ["transfer-done", "preview-done", "files-picker-done"] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 8)); app.buttons[identifier].tap()
        }
        waitUntilGone(app.buttons["files-picker-done"])
        XCUIDevice.shared.press(.home); app.activate()
        let host = app.buttons["share-host-ui-live-host"]
        XCTAssertTrue(host.waitForExistence(timeout: 15)); host.tap()
        let destination = app.textFields["files-upload-destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 15)); replace(destination, with: base)
        replace(app.textFields["files-upload-name-0"], with: "collision.txt")
        app.buttons["files-start-upload"].tap()
        let error = app.staticTexts["files-upload-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10)); XCTAssertTrue(error.label.contains("already exists"))
        XCTAssertTrue(destination.exists)
        XCTAssertFalse(app.staticTexts["transfer-status-upload-collision.txt"].exists)
        capture("Existing remote file rejected before upload")

        let collisionDetail = error.label
        replace(destination, with: base + "/missing-folder")
        app.buttons["files-start-upload"].tap()
        expectation(for: NSPredicate(format: "exists == true AND label != %@", collisionDetail), evaluatedWith: error)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(destination.exists)
        XCTAssertFalse(app.staticTexts["transfer-status-upload-collision.txt"].exists)
        app.buttons["files-upload-browse"].tap()
        let folder = app.textFields["files-upload-folder-path"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); replace(folder, with: base + "/destination"); folder.typeText("\n")
        let useFolder = app.buttons["files-upload-use-folder"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: useFolder); waitForExpectations(timeout: 15)
        XCTAssertEqual(folder.value as? String, base + "/destination"); useFolder.tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 5)); XCTAssertEqual(destination.value as? String, base + "/destination")
        replace(app.textFields["files-upload-name-0"], with: "uploaded.txt")
        app.buttons["files-start-upload"].tap()
        waitUntilCompleted(app.staticTexts["transfer-status-upload-uploaded.txt"])
        capture("Shared upload completed in chosen remote folder")
        app.buttons["transfer-done"].tap()
        waitUntilGone(app.buttons["transfer-done"])
        XCTAssertTrue(menu("files-options").waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Verify the receipt stays acknowledged across process restart before
        // checking the remote bytes, so relaunch cannot rediscover a completed upload.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["home-tab-sessions"].waitForExistence(timeout: 10))
        let incoming = app.navigationBars.matching(NSPredicate(format: "identifier == '共享文件' OR identifier == 'Shared files'")).firstMatch
        let noRepeatedReceipt = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: incoming)
        noRepeatedReceipt.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noRepeatedReceipt], timeout: 3), .completed,
                       "A completed shared upload must remain acknowledged after relaunch")
        let session = homeSessionCards().firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 8)); session.tap()
        let verified = "UPLOAD_CHECK_" + shortID()
        let check = "test \"$(cat " + quote(base + "/collision.txt") + ")\" = " + quote(original)
            + " && cmp -s " + quote(base + "/collision.txt") + " " + quote(base + "/destination/uploaded.txt") + " && " + emit(verified)
        let checked = try runCommand(check); waitForOutput(verified, surface: checked)
        try removeFixture(base)
    }

    private func openRemoteFolder(_ path: String) {
        openTools(); app.buttons["download-file"].tap()
        // Direct download starts with selection enabled; management and preview need normal row actions.
        filesMenu("files-select")
        searchRemote(path)
        let folder = entry(path)
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.tap()
        XCTAssertTrue(app.buttons["files-breadcrumb-" + path].waitForExistence(timeout: 15), "Wait for the requested directory listing before performing mutations")
        XCTAssertTrue(menu("files-options").waitForExistence(timeout: 8), "Opening a search result folder must restore the browser toolbar")
        XCTAssertTrue(app.buttons["files-picker-done"].exists, "Opening a folder must leave the picker dismissible")
    }
    private func closeRemoteBrowser() {
        let done = app.buttons["files-picker-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8)); done.tap(); waitUntilGone(done)
    }
    private func searchRemote(_ text: String) {
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); replace(search, with: text)
        search.typeText("\n")
    }
    private func entry(_ path: String) -> XCUIElement { app.buttons["files-entry-" + path] }
    private func menu(_ identifier: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: identifier).firstMatch }
    private func waitUntilCompleted(_ status: XCUIElement) {
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label == '已完成' OR label == 'Completed'"), evaluatedWith: status)
        waitForExpectations(timeout: 30)
    }
    private func waitUntilGone(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element); waitForExpectations(timeout: 10)
    }
    private func showTerminalKeyboard() {
        if app.keyboards.count == 0 {
            // As on Android, a tap on the cursor's line opens the keyboard.
            let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
            let cursor = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cursor-'")).firstMatch
            XCTAssertTrue(cursor.waitForExistence(timeout: 6))
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: cursor.frame.midY - surface.frame.minY)).tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }
    private func shareDownloadedFile(_ name: String) {
        let share = app.buttons["transfer-share-" + name]
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        let target = app.cells.matching(NSPredicate(format: "label == 'Roamtty'")).firstMatch
        if !target.waitForExistence(timeout: 4) {
            let more = app.cells.matching(NSPredicate(format: "label == 'More' OR label == '更多' OR label == 'More…'")).firstMatch
            XCTAssertTrue(more.exists); more.tap()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 8)); target.tap()
        let save = app.buttons["share-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap(); waitUntilGone(save)
    }
    private func removeFixture(_ path: String) throws {
        XCTAssertTrue(path.hasPrefix("/tmp/roamtty-ios-ui-"))
        let marker = "CLEANED_" + shortID()
        let surface = try runCommand("rm -rf -- " + quote(path) + " && " + emit(marker))
        waitForOutput(marker, surface: surface)
    }
    private func shortID() -> String { String(UUID().uuidString.prefix(8)) }
    private func fixturePath(_ purpose: String) -> String { "/tmp/roamtty-ios-ui-" + purpose + "-" + shortID() }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func write(_ content: String, to path: String) -> String { "printf '%s' " + quote(Data(content.utf8).base64EncodedString()) + " | base64 -d > " + quote(path) }
    // The full marker never appears in the echoed command, so it proves remote execution.
    private func emit(_ marker: String) -> String {
        let middle = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        return "printf '%s' " + quote(String(marker[..<middle])) + "; printf '%s\\n' " + quote(String(marker[middle...]))
    }

    /// In landscape the launch sheet and the file browser use the whole screen, like the host page there: one flat bar
    /// on top, the folders in full height beside a side column with the recent folders, the pickers and the button,
    /// and the files under a bar that carries the path, the sort, the search and the menu in place of the system ones.
    func testLandscapeLaunchSheetAndFilesUseTheWholeScreen() throws {
        try openHost()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for _ in 0..<10 where app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height { sleep(1) }
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height)

        app.buttons["host-detail-agent"].tap()
        let folders = app.descendants(matching: .any)["launch-folders"]
        XCTAssertTrue(folders.waitForExistence(timeout: 15))
        let close = app.buttons["launch-cancel"], launch = app.buttons["launch-session"]
        XCTAssertTrue(close.isHittable && launch.isHittable, "The bar and the button are both on screen")
        XCTAssertLessThan(close.frame.maxY, folders.frame.minY, "The bar is over the folders")
        XCTAssertLessThan(folders.frame.maxX, launch.frame.minX, "The button sits in the side column")
        XCTAssertLessThan(launch.frame.maxY, window.maxY, "The button is not cut off")
        XCTAssertGreaterThan(folders.frame.height, window.height * 0.6, "The folders take the height")
        capture("Launch sheet — landscape")
        close.tap()

        XCTAssertFalse(app.buttons["host-detail-continue"].exists, "No 继续 on the host page")

        app.buttons["host-detail-files"].tap()
        let search = app.textFields["files-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "The system bar is hidden in landscape")
        XCTAssertFalse(app.searchFields.firstMatch.exists, "The search is in the bar, not the system's")
        for id in ["files-back", "files-sort", "files-options"] {
            XCTAssertLessThan(abs(app.descendants(matching: .any)[id].firstMatch.frame.midY - search.frame.midY), 3, "\(id) is in the bar")
        }
        capture("Files — landscape")
        app.buttons["files-back"].tap()
        XCTAssertTrue(app.buttons["host-detail-files"].waitForExistence(timeout: 5), "Back returns to the host")
    }
}
