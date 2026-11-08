import XCTest

/// Opt-in regression against a saved desktop host and its existing credentials.
/// Does not reset the user's store or create/edit hosts.
final class DesktopLaunchUITests: XCTestCase {
    func testDesktopNetworkStatsRestorePortraitAndMatchAndroidLandscape() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for english in [false, true] {
            launchStatusFixture(app, phase: "stats", english: english, showStats: true)
            for landscape in [false, true] {
                rotate(app, landscape: landscape)
                let rtt = app.staticTexts["UDP 15 ms"]
                XCTAssertTrue(rtt.waitForExistence(timeout: 10))
                let picture = app.otherElements["desktop-video-surface"].frame
                for label in ["UDP 15 ms", "60 fps  2.4 Mbps", english ? "End-to-end 22 ms" : "端到端 22 ms",
                              english ? "Host 6 · Network 15 · Phone 1" : "主机端 6 · 网络 15 · 手机端 1",
                              english ? "Loss 0.0%" : "丢包 0.0%", "1920×1246 videotoolbox"] {
                    let value = app.staticTexts[label]
                    XCTAssertTrue(value.exists, "Keep every metric: \(label)")
                    XCTAssertTrue(picture.contains(value.frame), "Keep \(label) inside the desktop overlay")
                    XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(value.frame))
                }
                // Android: 8 outer + 7 horizontal / 4 vertical panel padding.
                XCTAssertEqual(rtt.frame.minY, picture.minY + 12, accuracy: 1)
                let ops = app.buttons[english ? "Ops" : "操作"]
                if landscape {
                    XCTAssertEqual(rtt.frame.minX, picture.minX + 15, accuracy: 1)
                    XCTAssertEqual(ops.frame.width, 54, accuracy: 1, "Landscape buttons are as deep as portrait ones")
                    XCTAssertGreaterThanOrEqual(ops.frame.minX, picture.maxX - 1)
                } else {
                    XCTAssertGreaterThanOrEqual(ops.frame.minY, picture.maxY - 1)
                    XCTAssertLessThanOrEqual(ops.frame.minY, picture.maxY + 5, "No new statistics strip above portrait controls")
                }
                capture(app, "Android stats overlay \(english ? "English" : "Chinese") \(landscape ? "landscape" : "portrait")")
            }
        }
    }

    func testDesktopNetworkStatsTogglePreservesViewportAndKeyboard() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        launchStatusFixture(app, phase: "stats", showStats: true)
        for landscape in [false, true] {
            rotate(app, landscape: landscape)
            let picture = app.otherElements["desktop-video-surface"]
            let withStats = picture.frame
            toggleNetworkStats(app)
            XCTAssertFalse(app.staticTexts["UDP 15 ms"].exists)
            XCTAssertEqual(picture.frame.width, withStats.width, accuracy: 1)
            XCTAssertEqual(picture.frame.height, withStats.height, accuracy: 1)
            toggleNetworkStats(app)
            XCTAssertTrue(app.staticTexts["UDP 15 ms"].waitForExistence(timeout: 5))
            XCTAssertEqual(picture.frame.width, withStats.width, accuracy: 1)
            XCTAssertEqual(picture.frame.height, withStats.height, accuracy: 1)
            app.buttons["键盘"].tap()
            Thread.sleep(forTimeInterval: 1)
            if app.buttons["Continue"].waitForExistence(timeout: 1) { app.buttons["Continue"].tap() }
            let hideKeyboard = app.buttons["关闭键盘"]
            XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 5))
            if landscape {
                // The landscape picture is short already: rather than shrinking above the keyboard,
                // it keeps running under the floating keyboard bar.
                XCTAssertGreaterThan(picture.frame.maxY, hideKeyboard.frame.maxY,
                                     "The landscape keyboard floats over the picture instead of shrinking it")
            } else {
                assertPictureAboveControls(app, controls: hideKeyboard)
            }
            let rtt = app.staticTexts["UDP 15 ms"]
            if landscape { XCTAssertEqual(rtt.frame.minX, picture.frame.minX + 15, accuracy: 1) }
            XCTAssertEqual(rtt.frame.minY, picture.frame.minY + 12, accuracy: 1)
            XCTAssertTrue(picture.frame.contains(app.staticTexts["1920×1246 videotoolbox"].frame))
            capture(app, landscape ? "Landscape overlay with keyboard" : "Portrait overlay with keyboard")
            // A tap that lands while the keyboard is still settling can be dropped; the next rotation needs it down.
            for _ in 0..<2 where hideKeyboard.exists { hideKeyboard.tap(); _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3) }
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Closing the keyboard must put it away")
        }
    }

    func testLandscapeRailAndPictureUseTheSideWithoutTheIsland() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        launchStatusFixture(app, phase: "stats", showStats: true)
        var landscapeRail: [Bool: (depth: CGFloat, fromEdge: CGFloat)] = [:]
        // Device landscape left puts the top of the phone, and its island, on the left.
        for (orientation, islandLeft) in [(UIDeviceOrientation.landscapeLeft, true), (.landscapeRight, false)] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            Thread.sleep(forTimeInterval: 1)
            let screen = app.frame
            let picture = app.otherElements["desktop-video-surface"].frame
            let ops = app.buttons["操作"].frame
            let rtt = app.staticTexts["UDP 15 ms"].frame
            if islandLeft {
                XCTAssertGreaterThan(picture.minX, screen.minX + 20, "The picture keeps clear of the island")
                XCTAssertGreaterThan(ops.maxX, screen.maxX - 12, "The buttons sit by the screen edge")
            } else {
                XCTAssertEqual(picture.minX, screen.minX, accuracy: 1, "The picture runs to the screen edge")
                XCTAssertLessThan(ops.maxX, screen.maxX - 20, "The rail's buttons keep clear of the island")
                XCTAssertGreaterThan(rtt.minX, screen.minX + 30, "The stats stay out of the rounded corner")
            }
            XCTAssertLessThanOrEqual(picture.maxX, ops.minX + 1)
            XCTAssertEqual(picture.maxY, screen.maxY, accuracy: 1, "The picture runs under the home indicator")
            XCTAssertGreaterThan(ops.minY, app.buttons["所有窗口"].frame.maxY - 1, "操作 is the lowest button")
            landscapeRail[islandLeft] = (ops.width, screen.maxX - ops.minX)
            capture(app, islandLeft ? "Landscape, island left" : "Landscape, island right")
        }
        XCUIDevice.shared.orientation = .portrait
        let upright = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width < app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [upright], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 1)
        let ops = app.buttons["操作"].frame
        XCTAssertLessThan(ops.maxX, app.buttons["所有窗口"].frame.minX, "操作 is the leftmost button")
        XCTAssertGreaterThan(ops.maxY, app.frame.maxY - 20, "The buttons sit just above the home indicator")
        // Lying down, the rail is as thick as standing up, with only the island's side kept clear.
        for (islandLeft, rail) in landscapeRail {
            XCTAssertEqual(rail.depth, ops.height, accuracy: 1, "Landscape buttons are as deep as portrait ones")
            if islandLeft { XCTAssertEqual(rail.fromEdge, app.frame.maxY - ops.minY, accuracy: 1, "The landscape rail is as thick as the portrait one") }
        }
        XCTAssertEqual(landscapeRail.count, 2)
        capture(app, "Portrait rail")
    }

    func testPinchZoomsThePicture() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        launchStatusFixture(app, phase: "stats", showStats: true)
        let picture = app.otherElements["desktop-video-surface"]
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        func drawnWidth() -> Int { Int((picture.value as? String)?.split(separator: "x").first ?? "") ?? 0 }
        let before = drawnWidth()
        XCTAssertGreaterThan(before, 0)
        // XCUIElement.pinch rests both fingers before spreading them, which the page takes for a two-finger hold (as
        // Android does); a pinch spreads them at once.
        let frame = picture.frame
        func at(_ x: CGFloat) -> CGPoint { CGPoint(x: frame.minX + frame.width * x, y: frame.midY) }
        try Touches.perform([[(at(0.45), 0), (at(0.15), 0.4)], [(at(0.55), 0), (at(0.85), 0.4)]])
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in drawnWidth() > before + 20 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed, "A pinch enlarges the picture: \(before) -> \(drawnWidth())")
        capture(app, "Pinch zoomed")
    }

    /// The figures: a tap on them still reaches the desktop, a still long press moves them (and nothing of it
    /// reaches the desktop), their ✕ hides them, and turned back on they come back where they were left.
    func testDesktopNetworkStatsCloseAndDragKeepGestures() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for landscape in [false, true] {
            app.launchEnvironment["ROAMTTY_DESKTOP_INPUT_PROBE"] = "1"
            launchStatusFixture(app, phase: "stats", showStats: true)
            rotate(app, landscape: landscape)
            let stats = app.otherElements["desktop-stats"]
            XCTAssertTrue(app.staticTexts["UDP 15 ms"].waitForExistence(timeout: 10))
            let picture = app.otherElements["desktop-video-surface"].frame
            let home = stats.frame
            let probe = app.staticTexts["desktop-input-probe"]
            func probeText() -> String { probe.exists ? probe.label : "" }

            // A tap on the figures is the desktop's.
            stats.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
            let clicked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in probeText().contains("b1d") }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [clicked], timeout: 5), .completed, "A tap on the figures clicks the host: \(probeText())")
            XCTAssertEqual(stats.frame, home, "A tap does not move the figures")

            // A still long press picks them up and drags them; the desktop sees none of it.
            stats.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: picture.minX + picture.width * 0.75, dy: picture.minY + picture.height * 0.75)))
            Thread.sleep(forTimeInterval: 0.5)
            let moved = stats.frame
            XCTAssertGreaterThan(moved.minX, home.minX + picture.width * 0.1, "Dragged right: \(home) -> \(moved), probe \(probeText())")
            XCTAssertGreaterThan(moved.minY, home.minY + picture.height * 0.1, "Dragged down: \(home) -> \(moved)")
            XCTAssertTrue(picture.insetBy(dx: -1, dy: -1).contains(moved), "Kept inside the picture: \(moved) in \(picture)")
            XCTAssertNotNil(probeText().range(of: #"^#\d+ $"#, options: .regularExpression), "The drag sends nothing to the host: \(probeText())")
            capture(app, "Stats dragged \(landscape ? "landscape" : "portrait")")

            // ✕ hides them and says where they come back from.
            app.buttons["desktop-stats-close"].tap()
            XCTAssertTrue(stats.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.otherElements["desktop-stats-hint"].exists || app.staticTexts["网络状态已隐藏，可在「操作」中重新打开"].exists)
            capture(app, "Stats closed \(landscape ? "landscape" : "portrait")")
            toggleNetworkStats(app)
            XCTAssertTrue(stats.waitForExistence(timeout: 5))
            XCTAssertEqual(stats.frame.minX, moved.minX, accuracy: 2, "Back where it was left")
            XCTAssertEqual(stats.frame.minY, moved.minY, accuracy: 2, "Back where it was left")
        }
    }

    private func toggleNetworkStats(_ app: XCUIApplication) {
        app.buttons["操作"].tap()
        let scroll = app.scrollViews["desktop-operations-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let row = app.switches.matching(NSPredicate(format: "label BEGINSWITH '显示网络状态'")).firstMatch
        // SwiftUI exposes both the labeled row and its UISwitch. Tap the actual
        // control; querying the offscreen row's hit point can fail in XCTest.
        let toggle = row.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // swipeUp/swipeDown do not move this panel in landscape; drag explicitly within the visible scroll area.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<6 where !scroll.frame.contains(toggle.frame) {
            let frame = scroll.frame, up = toggle.frame.minY > frame.minY
            let (from, to) = up ? (frame.minY + frame.height * 0.8, frame.minY + frame.height * 0.25)
                                : (frame.minY + frame.height * 0.25, frame.minY + frame.height * 0.8)
            origin.withOffset(CGVector(dx: frame.midX, dy: from))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: to)))
        }
        // The operations sheet may still be sliding in; wait for the switch to settle under a finger.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed, "The network stats switch must be tappable: \(toggle.frame) in \(scroll.frame), window \(app.frame)")
        toggle.tap()
        app.buttons["desktop-op-close"].tap()
    }

    func testDesktopPoorNetworkWarningMatchesAndroidTopLeft() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        launchStatusFixture(app, phase: "poor-network")
        for landscape in [false, true] {
            rotate(app, landscape: landscape)
            let warning = app.staticTexts["网络较差"]
            XCTAssertTrue(warning.waitForExistence(timeout: 5))
            let picture = app.otherElements["desktop-video-surface"].frame
            XCTAssertTrue(picture.contains(warning.frame))
            if landscape { XCTAssertLessThan(warning.frame.minX, picture.minX + 40) }
            XCTAssertLessThan(warning.frame.minY, picture.minY + 24)
            XCTAssertFalse(app.staticTexts["60 fps  2.4 Mbps"].exists)
            capture(app, landscape ? "Landscape Android network warning" : "Portrait Android network warning")
        }
    }

    func testDesktopOpeningShowsAndroidStepsAndStableCard() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        var previousSize: CGSize?
        for (phase, plugin, expectedStates) in [
            ("login", "启动桌面插件", ["进行中", "等待中", "等待中"]),
            ("install", "安装桌面插件", ["已完成", "进行中", "等待中"]),
            ("start", "启动桌面插件", ["已完成", "进行中", "等待中"]),
            ("first-frame", "启动桌面插件", ["已完成", "已完成", "进行中"])
        ] {
            launchStatusFixture(app, phase: phase)
            XCTAssertTrue(app.staticTexts["正在打开桌面"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["MacBook"].exists)
            for (index, label) in ["登录主机", plugin, "等待画面"].enumerated() {
                let step = app.otherElements["desktop-step-\(index)"]
                XCTAssertTrue(step.exists)
                XCTAssertEqual(step.label, label)
                XCTAssertEqual(step.value as? String, expectedStates[index])
            }
            let card = app.otherElements["desktop-status"]
            XCTAssertEqual(card.frame.width, 296, accuracy: 1)
            XCTAssertEqual(card.frame.height, 244, accuracy: 1)
            if let previousSize { XCTAssertEqual(card.frame.size, previousSize) }
            previousSize = card.frame.size
            XCTAssertTrue(app.staticTexts["desktop-log"].exists)
            XCTAssertFalse(app.buttons["desktop-retry"].exists)
            capture(app, "Android parity opening \(phase)")
        }
    }

    func testDesktopNeedsUseReadableInstructionsInBothLanguages() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for english in [false, true] {
            launchStatusFixture(app, phase: "needs-screen-recording", english: english)
            let message = app.staticTexts["desktop-needs"]
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            XCTAssertTrue(message.label.contains(english ? "Allow Screen Recording on the Mac" : "请在 Mac 上允许“屏幕录制”"))
            XCTAssertTrue(app.staticTexts[english ? "It connects by itself once done" : "满足后会自动连接"].exists)
            XCTAssertFalse(app.staticTexts["screen-recording"].exists)
            capture(app, english ? "English permission guide" : "Chinese permission guide")
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(message.isHittable)
            assertStatusInsideViewport(app)
            capture(app, english ? "English permission guide landscape" : "Chinese permission guide landscape")
            XCUIDevice.shared.orientation = .portrait
            Thread.sleep(forTimeInterval: 1)
        }
        launchStatusFixture(app, phase: "needs-windows")
        XCTAssertTrue(app.staticTexts["请先在这台电脑上登录桌面"].waitForExistence(timeout: 10))
        let copy = app.buttons["desktop-service-copy"]
        for _ in 0..<4 where !copy.isHittable { app.scrollViews["desktop-status-body"].swipeUp() }
        XCTAssertTrue(copy.isHittable, "Long Windows instructions must scroll to the copy command")
        copy.tap()
        capture(app, "Windows service command")
    }

    func testDesktopFailureAndRecoveryMatchAndroid() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        launchStatusFixture(app, phase: "failed")
        XCTAssertTrue(app.staticTexts["无法打开桌面"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["这台主机没有图形桌面"].exists)
        let retry = app.buttons["desktop-retry"], close = app.buttons["desktop-close"]
        XCTAssertTrue(retry.isHittable); XCTAssertTrue(close.isHittable)
        XCTAssertEqual(retry.frame.midY, close.frame.midY, accuracy: 1)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
        capture(app, "Android parity failure")
        launchStatusFixture(app, phase: "recovering")
        XCTAssertTrue(app.staticTexts["连接中断"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["正在恢复…"].exists)
        XCTAssertTrue(app.staticTexts["网络恢复后画面会自动回来"].exists)
        capture(app, "Android parity recovery over last frame")
        launchStatusFixture(app, phase: "connected")
        XCTAssertTrue(app.otherElements["desktop-video-surface"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["desktop-status"].exists)
        XCTAssertFalse(app.otherElements["desktop-recovering"].exists)
    }

    func testDesktopRecoveryWaitsAndCancelsWhenPictureReturns() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        launchStatusFixture(app, phase: "recovery-sequence")
        let loseLink = app.buttons["所有窗口"], restoreLink = app.buttons["显示桌面"]
        XCTAssertTrue(loseLink.waitForExistence(timeout: 10))
        let recovery = app.otherElements["desktop-recovering"]
        loseLink.tap()
        XCTAssertFalse(recovery.exists, "Brief interruptions must not flash a recovery card")
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        restoreLink.tap()
        XCTAssertFalse(recovery.exists)
        loseLink.tap()
        restoreLink.tap()
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(recovery.exists, "A cancelled timer must not cover a restored picture")
        loseLink.tap()
        XCTAssertFalse(recovery.exists, "A new recovery episode gets its own delay")
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
    }

    /// Run on the compact simulator at default and accessibility sizes as well as the normal phone.
    func testDesktopStatusFitsViewportWithScrollableInstructions() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for phase in ["first-frame", "needs-windows", "failed"] {
            launchStatusFixture(app, phase: phase, english: true)
            XCTAssertTrue(app.otherElements["desktop-status"].waitForExistence(timeout: 10))
            for landscape in [false, true] {
                XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
                Thread.sleep(forTimeInterval: 1)
                assertStatusInsideViewport(app)
                if phase == "needs-windows" {
                    let copy = app.buttons["desktop-service-copy"]
                    for _ in 0..<8 where !copy.isHittable { app.scrollViews["desktop-status-body"].swipeUp() }
                    XCTAssertTrue(copy.isHittable)
                } else if phase == "failed" {
                    XCTAssertTrue(app.buttons["desktop-retry"].isHittable)
                    XCTAssertTrue(app.buttons["desktop-close"].isHittable)
                }
                capture(app, "Status \(phase) fits \(landscape ? "landscape" : "portrait")")
            }
            XCUIDevice.shared.orientation = .portrait
        }
    }

    private func assertStatusInsideViewport(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.otherElements["desktop-status"].frame
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(card), "Card \(card) must fit \(app.frame)", file: file, line: line)
        XCTAssertGreaterThan(card.width, 200, file: file, line: line)
        XCTAssertGreaterThan(card.height, 150, file: file, line: line)
    }

    private func launchStatusFixture(_ app: XCUIApplication, phase: String, english: Bool = false, showStats: Bool = false) {
        continueAfterFailure = false
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--desktop-controls-fixture"]
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopControlsFixture"
        app.launchEnvironment["ROAMTTY_DESKTOP_STATUS_FIXTURE"] = phase
        app.launchEnvironment["ROAMTTY_DESKTOP_FIXTURE_LANGUAGE"] = english ? "en" : "zh-Hans"
        app.launchEnvironment["ROAMTTY_DESKTOP_STATS_FIXTURE"] = showStats ? "1" : "0"
        app.launch()
    }

    private func rotate(_ app: XCUIApplication, landscape: Bool) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let orientation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (app.frame.width > app.frame.height) == landscape
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [orientation], timeout: 5), .completed,
                       "Wait for the application window to finish rotating")
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Real SSH to a headless fixture, with a deliberately stale positive desktop cache.
    func testHeadlessHostStopsRetryingAndUpdatesCard() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_HEADLESS_DESKTOP_FIXTURE"] == "1" else {
            throw XCTSkip("Requires seed-headless-desktop-fixture.py and a headless SSH fixture")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopHeadlessRegression"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        app.buttons["home-tab-hosts"].tap()
        let screen = app.buttons["host-screen-ui-live-host"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        screen.tap()
        let failure = app.staticTexts["这台主机没有图形桌面"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        let retry = app.buttons["重试"]
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(failure.exists, "The terminal failure must stay visible instead of reopening the desktop")
            XCTAssertTrue(retry.exists)
        }
        capture(app, "Headless desktop failure stays visible")
        // A retry is explicit, and another negative probe returns to the same stable failure page.
        retry.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        app.buttons["关闭"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["没有图形桌面"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        app.buttons["home-tab-hosts"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["没有图形桌面"].exists)
        screen.tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 10))
        XCTAssertFalse(failure.exists)
        capture(app, "Headless host opens details after relaunch")
    }

    func testDesktopControlsLayoutAndKeyboard() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_DESKTOP_CONTROLS_FIXTURE"] == "1" else {
            throw XCTSkip("Requires isolated desktop controls fixture")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--desktop-controls-fixture"]
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopControlsFixture"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 15))
        for landscape in [false, true] {
            XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
            Thread.sleep(forTimeInterval: 1)
            ops.tap()
            XCTAssertTrue(app.buttons["desktop-op-close"].waitForExistence(timeout: 5))
            let mode = app.buttons.matching(NSPredicate(format: "label == '鼠标指针' OR label == 'Trackpad'")).firstMatch
            XCTAssertTrue(mode.exists); mode.tap(); XCTAssertTrue(mode.isSelected)
            capture(app, landscape ? "Landscape operations" : "Portrait operations")
            app.buttons["desktop-op-close"].tap()
            let fullPictureHeight = app.otherElements["desktop-video-surface"].frame.height
            app.buttons.matching(NSPredicate(format: "label == '键盘' OR label == 'Keys'")).firstMatch.tap()
            Thread.sleep(forTimeInterval: 1)
            let keyboardContinue = app.buttons["Continue"]
            if keyboardContinue.waitForExistence(timeout: 2) { keyboardContinue.tap() }
            let toggle = app.buttons["desktop-kb-toggle"]
            if toggle.waitForExistence(timeout: 3) {
                assertPictureClearsKeyboard(app, landscape: landscape, fullHeight: fullPictureHeight, controls: toggle)
                if landscape { capture(app, "Landscape before shortcut toggle") }
                toggle.tap()
            }
            XCTAssertTrue(app.buttons["desktop-kb-more"].waitForExistence(timeout: 5))
            if !landscape { XCTAssertFalse(ops.exists, "Portrait rail is replaced by the keyboard") }
            assertPictureClearsKeyboard(app, landscape: landscape, fullHeight: fullPictureHeight, controls: app.buttons["desktop-kb-more"])

            let modifier = app.buttons.matching(NSPredicate(format: "label == 'Ctrl' OR label == '⌃'")).firstMatch
            XCTAssertTrue(modifier.exists)
            modifier.press(forDuration: 0.7)
            XCTAssertTrue(["已锁定", "Locked"].contains(modifier.value as? String ?? ""))
            modifier.tap()
            modifier.tap()
            XCTAssertTrue(["单次生效", "Once"].contains(modifier.value as? String ?? ""))
            app.buttons["Esc"].tap()
            XCTAssertEqual(modifier.value as? String ?? "", "")
            capture(app, landscape ? "Landscape shortcuts and IME" : "Portrait shortcuts and IME")
            app.buttons["desktop-kb-more"].tap()
            Thread.sleep(forTimeInterval: 0.5)
            let f12 = app.buttons["F12"]
            XCTAssertTrue(f12.waitForExistence(timeout: 5)); XCTAssertTrue(f12.isHittable)
            assertPictureClearsKeyboard(app, landscape: landscape, fullHeight: fullPictureHeight, controls: app.buttons["desktop-kb-more"])
            f12.tap()
            let shift = app.buttons["Shift"]
            XCTAssertTrue(shift.isHittable); shift.tap()
            capture(app, landscape ? "Landscape PC keys" : "Portrait PC keys")
            app.buttons["desktop-kb-more"].tap()
            Thread.sleep(forTimeInterval: 0.5)
            app.buttons["desktop-kb-hide-bar"].tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
            modifier.press(forDuration: 0.7)
            app.buttons.matching(NSPredicate(format: "label == '关闭键盘' OR label == 'Close keyboard'")).firstMatch.tap()
            XCTAssertTrue(ops.waitForExistence(timeout: 5))
            XCTAssertEqual(app.otherElements["desktop-video-surface"].frame.height, fullPictureHeight, accuracy: 1)
            app.buttons.matching(NSPredicate(format: "label == '键盘' OR label == 'Keys'")).firstMatch.tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
            XCTAssertEqual(modifier.value as? String ?? "", "", "Closing the keyboard must clear locked modifiers")
            app.buttons.matching(NSPredicate(format: "label == '关闭键盘' OR label == 'Close keyboard'")).firstMatch.tap()
        }
    }

    /// Portrait: the picture shrinks to fit above the keyboard. Landscape: the picture is short already, so it keeps
    /// its full height and the keyboard floats over its lower part.
    private func assertPictureClearsKeyboard(_ app: XCUIApplication, landscape: Bool, fullHeight: CGFloat, controls: XCUIElement) {
        guard landscape else { return assertPictureAboveControls(app, controls: controls) }
        let picture = app.otherElements["desktop-video-surface"]
        XCTAssertEqual(picture.frame.height, fullHeight, accuracy: 1, "The landscape keyboard does not shrink the picture")
        XCTAssertGreaterThan(picture.frame.maxY, controls.frame.maxY,
                             "The landscape keyboard floats over the picture instead of shrinking it")
    }

    private func assertPictureAboveControls(_ app: XCUIApplication, controls: XCUIElement) {
        let picture = app.otherElements["desktop-video-surface"]
        XCTAssertTrue(picture.exists)
        XCTAssertGreaterThan(picture.frame.height, 20)
        XCTAssertLessThanOrEqual(picture.frame.maxY, controls.frame.minY + 1,
                                 "The complete remote picture must fit above the keyboard and shortcuts")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// The host's sound on the phone (Android `E2eAudioTest`): the host loops a 440 Hz / 660 Hz tone
    /// (the runner starts it), the app decodes 440 Hz on the left at the tone's level, near live and
    /// without drops; 声音 off stops the packets and on brings them back. Played at volume 0: a simulator
    /// would play it through the Mac's speakers.
    func testLiveDesktopPlaysTheHostsSound() throws {
        guard let host = ProcessInfo.processInfo.environment["ROAMTTY_LIVE_DESKTOP_HOST"], !host.isEmpty,
              ProcessInfo.processInfo.environment["ROAMTTY_LIVE_DESKTOP_TONE"] == "1" else {
            throw XCTSkip("Set ROAMTTY_LIVE_DESKTOP_HOST and ROAMTTY_LIVE_DESKTOP_TONE=1 with a tone playing on the host")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ROAMTTY_DESKTOP_AUDIO_PROBE"] = "1"
        app.launchEnvironment["ROAMTTY_DESKTOP_AUDIO_MUTE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        app.buttons["home-tab-hosts"].tap()
        let card = app.buttons["host-screen-" + host]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let online = NSPredicate(format: "label CONTAINS[c] '打开桌面' OR label CONTAINS[c] 'Open desktop'")
        expectation(for: online, evaluatedWith: card)
        waitForExpectations(timeout: 20)
        card.tap()
        let probe = app.staticTexts["desktop-audio-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 60), "the player decoded something")
        func value(_ key: String) -> Int {
            let label = probe.label
            guard let r = label.range(of: key + "=") else { return -1 }
            return Int(label[r.upperBound...].prefix { $0.isNumber }) ?? -1
        }
        // 440 Hz crosses zero 880 times a second; the tone's RMS is 8000 / √2.
        let tone = NSPredicate { _, _ in (860...900).contains(value("crossings")) && (5000...6300).contains(value("rms")) }
        expectation(for: tone, evaluatedWith: probe)
        waitForExpectations(timeout: 30)
        // Settled: a few seconds of steady play, near live, without drops.
        Thread.sleep(forTimeInterval: 10)
        let dropped = value("dropped"), packets = value("packets")
        var queued: [Int] = []
        for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.3); queued.append(value("queued")) }
        let state = "\(probe.label), queued \(queued)"
        // As deep as the network's jitter, never past the drop line above it.
        XCTAssertLessThanOrEqual(queued.max() ?? 999, value("target") + 120, state)
        XCTAssertLessThanOrEqual(value("target"), 300, state)
        XCTAssertLessThanOrEqual((value("dropped") - dropped) * 50, max(1, value("packets") - packets), state)
        NSLog("RoamttyAudioProbe %@", state)
        capture(app, "Sound playing")

        // 声音 off: no more packets; on again: they come back.
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        let sound = app.switches.matching(NSPredicate(format: "label BEGINSWITH '声音' OR label BEGINSWITH 'Sound'")).firstMatch
        ops.tap()
        XCTAssertTrue(sound.waitForExistence(timeout: 5))
        XCTAssertEqual(sound.value as? String, "1")
        sound.tap()
        app.buttons["desktop-op-close"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        let off = value("packets")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(value("packets"), off, "no packets while sound is off")
        ops.tap()
        XCTAssertTrue(sound.waitForExistence(timeout: 5))
        sound.tap()
        app.buttons["desktop-op-close"].tap()
        let back = NSPredicate { _, _ in value("packets") > off + 50 }
        expectation(for: back, evaluatedWith: probe)
        waitForExpectations(timeout: 15)
    }

    func testColdLaunchAndLiveDesktopStayRunning() throws {
        guard let host = ProcessInfo.processInfo.environment["ROAMTTY_LIVE_DESKTOP_HOST"], !host.isEmpty else {
            throw XCTSkip("Set ROAMTTY_LIVE_DESKTOP_HOST to a saved, desktop-enabled host")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        for _ in 0..<2 {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.state, .runningForeground)
        }
        app.buttons["home-tab-hosts"].tap()
        // The card's picture opens the desktop once the host is reachable.
        let card = app.buttons["host-screen-" + host]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let online = NSPredicate(format: "label CONTAINS[c] '打开桌面' OR label CONTAINS[c] 'Open desktop'")
        expectation(for: online, evaluatedWith: card)
        waitForExpectations(timeout: 20)
        card.tap()
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 15))
        ops.tap()
        let stats = app.switches.matching(NSPredicate(format: "label BEGINSWITH '显示网络状态' OR label BEGINSWITH 'Show network stats'")).firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        let wasOff = (stats.value as? String) == "0"
        if wasOff { stats.tap() }
        app.buttons["desktop-op-close"].tap()
        let frames = app.staticTexts.matching(NSPredicate(format: "label MATCHES '.*[1-9][0-9]* fps.*'")).firstMatch
        XCTAssertTrue(frames.waitForExistence(timeout: 30), "Must receive live desktop frames")
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 5)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(frames.exists, "Live video stats must remain visible")
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Live desktop after 30 seconds"
        attachment.lifetime = .keepAlways
        add(attachment)
        if wasOff { ops.tap(); stats.tap(); app.buttons["desktop-op-close"].tap() }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
