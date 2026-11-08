import Foundation
import XCTest

final class FileSortingUITests: RoamttyLiveUITestCase {
    func testNameSizeAndModifiedSortBothDirectionsKeepDirectoriesFirst() throws {
        let surface = try openTerminal(preferMosh: false, mode: "SSH")
        let base = "/tmp/roamtty-ios-ui-sort-" + UUID().uuidString
        let folder = "zz-directory"
        // Four different extensions plus equal size/date pairs ensure descending
        // ties still use A→Z names, rather than reversing a whole ascending list.
        let files = [("alpha.txt", String(repeating: "A", count: 41), "202201020000.00"),
                     ("bravo.TXT", String(repeating: "B", count: 17), "202201010000.00"),
                     ("middle.kt", "MID", "202201030000.00"),
                     ("zulu.md", String(repeating: "Z", count: 17), "202201010000.00")]
        var create = "mkdir -m 700 " + quote(base) + " && mkdir " + quote(base + "/" + folder)
        for (name, content, date) in files {
            let path = quote(base + "/" + name)
            create += " && printf '%s' " + quote(content) + " > " + path
                + " && touch -t " + quote(date) + " -- " + path
        }
        let ready = "SORT_FIXTURE_READY_" + nonce()
        try runCommand(create + " && " + emit(ready)); waitForOutput(ready, surface: surface)
        openRemoteFolder(base)

        assertVisibleOrder([folder, "alpha.txt", "bravo.TXT", "middle.kt", "zulu.md"], in: base)
        // swiftlint:disable:next large_tuple - one row per sort criterion
        let criteria: [(chinese: String, english: String, ascending: [String], descending: [String], startsDescending: Bool)] = [
            ("名称", "Name", ["alpha.txt", "bravo.TXT", "middle.kt", "zulu.md"], ["zulu.md", "middle.kt", "bravo.TXT", "alpha.txt"], true),
            ("大小", "Size", ["middle.kt", "bravo.TXT", "zulu.md", "alpha.txt"], ["alpha.txt", "bravo.TXT", "zulu.md", "middle.kt"], true),
            ("修改时间", "Modified", ["bravo.TXT", "zulu.md", "alpha.txt", "middle.kt"], ["middle.kt", "alpha.txt", "bravo.TXT", "zulu.md"], true),
            ("类型", "Type", ["middle.kt", "zulu.md", "alpha.txt", "bravo.TXT"], ["alpha.txt", "bravo.TXT", "zulu.md", "middle.kt"], false)
        ]
        for criterion in criteria {
            chooseSort(chinese: criterion.chinese, english: criterion.english)
            let initial = criterion.startsDescending ? criterion.descending : criterion.ascending
            let opposite = criterion.startsDescending ? criterion.ascending : criterion.descending
            assertVisibleOrder([folder] + initial, in: base)
            // As on Android, choosing the current sort again reverses it.
            chooseSort(chinese: criterion.chinese, english: criterion.english)
            assertVisibleOrder([folder] + opposite, in: base)
            capture(criterion.english + " sorts with folders first and ascending name ties")
            chooseSort(chinese: criterion.chinese, english: criterion.english)
            assertVisibleOrder([folder] + initial, in: base)
            chooseSort(chinese: criterion.chinese, english: criterion.english)
            assertVisibleOrder([folder] + opposite, in: base)
        }

        // Reopening a browser must use the shared saved Type/descending option.
        let done = app.buttons["files-picker-done"]
        XCTAssertTrue(done.exists); done.tap()
        waitUntilGone(done)
        openRemoteFolder(base)
        assertVisibleOrder([folder, "alpha.txt", "bravo.TXT", "zulu.md", "middle.kt"], in: base)
        openOptions()
        let copy = app.buttons["files-copy-current-path"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3)); copy.tap()
        done.tap(); waitUntilGone(done)
        clearDraft()
        terminalMenu("menu-paste")
        let editor = app.textViews["prompt-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, base, "Copy current path must copy the resolved directory, without a file name")
        app.buttons.matching(NSPredicate(format: "label == '收起' OR label == 'Hide'")).firstMatch.tap()
        let cleaned = "SORT_FIXTURE_CLEANED_" + nonce()
        try runCommand("rm -rf -- " + quote(base) + " && test ! -e " + quote(base) + " && " + emit(cleaned))
        waitForOutput(cleaned, surface: surface)
        closeTerminal()
        XCTAssertEqual(homeSessionCards().count, 0)
    }

    private func openRemoteFolder(_ path: String) {
        openTools(); app.buttons["download-file"].tap()
        filesMenu("files-select")
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); replace(search, with: path)
        search.typeText("\n")
        let folder = entry(path)
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.tap()
        XCTAssertTrue(app.buttons["files-breadcrumb-" + path].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["files-picker-done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Opening the fixture folder must dismiss search before checking row positions")
    }

    private func chooseSort(chinese: String, english: String) {
        let sort = app.descendants(matching: .any).matching(identifier: "files-sort").firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 5)); sort.tap()
        let choice = nativeMenuItem(NSPredicate(format: "label == %@ OR label == %@", chinese, english))
        XCTAssertTrue(choice.waitForExistence(timeout: 3)); choice.tap()
    }

    private func openOptions() {
        let options = app.descendants(matching: .any).matching(identifier: "files-options").firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
    }

    private func nativeMenuItem(_ predicate: NSPredicate) -> XCUIElement {
        let button = app.buttons.matching(predicate).firstMatch
        if button.exists { return button }
        let item = app.menuItems.matching(predicate).firstMatch
        return item.exists ? item : button
    }

    private func assertVisibleOrder(_ names: [String], in directory: String) {
        let expectedIDs = names.map { "files-entry-" + directory + "/" + $0 }
        let displayed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "files-entry-" + directory + "/"))
        let ordered = NSPredicate { _, _ in
            guard displayed.count == expectedIDs.count else { return false }
            let rows = displayed.allElementsBoundByIndex
            guard rows.allSatisfy({ $0.exists && $0.isHittable && $0.frame.width > 0 && $0.frame.height > 0 && self.app.frame.contains($0.frame) }) else { return false }
            return rows.sorted { $0.frame.minY < $1.frame.minY }.map(\.identifier) == expectedIDs
        }
        let check = XCTNSPredicateExpectation(predicate: ordered, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 8), .completed, "Visible row order must be " + names.joined(separator: ", "))
        let rows = expectedIDs.map { app.buttons[$0] }
        for (before, after) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThanOrEqual(before.frame.maxY, after.frame.minY, "Each sorted row must appear below its predecessor")
        }
    }

    private func entry(_ path: String) -> XCUIElement { app.buttons["files-entry-" + path] }
    private func waitUntilGone(_ element: XCUIElement) {
        let check = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 8), .completed)
    }
    private func nonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func emit(_ marker: String) -> String {
        let split = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        return "{ printf '%s' " + quote(String(marker[..<split])) + "; printf '%s\\n' " + quote(String(marker[split...])) + "; }"
    }
}
