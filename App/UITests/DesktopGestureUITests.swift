import XCTest

/// The gesture table (docs/DESKTOP-GESTURES.md) against a real desktop host: every gesture is made with
/// real synthesized touches on the live page, and the input it sent is read back from the page's probe
/// (ROAMTTY_DESKTOP_INPUT_PROBE=1). Screenshots of the host's picture after each step show its effect.
/// Opt-in: `scripts/test-desktop-gestures.sh host.json` sets ROAMTTY_DESKTOP_GESTURE_HOST=1 and points
/// ROAMTTY_TEST_HOST / _PORT / _USERNAME / _PASSWORD at a disposable desktop host. The full suite's SSH
/// fixture has no desktop, so there these tests skip; `testSwipeBackFromOutsideThePicture` needs no host.
final class DesktopGestureUITests: XCTestCase {
    private var app: XCUIApplication!
    private var surface: CGRect = .zero

    private func launch(pointer: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ROAMTTY_DESKTOP_GESTURE_HOST"] == "1", let host = env["ROAMTTY_TEST_HOST"], !host.isEmpty,
              env["ROAMTTY_TEST_PASSWORD"] != nil else {
            throw XCTSkip("Needs a live desktop host: run scripts/test-desktop-gestures.sh host.json")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--desktop-gesture-fixture"]
        for key in ["ROAMTTY_TEST_HOST", "ROAMTTY_TEST_PORT", "ROAMTTY_TEST_USERNAME", "ROAMTTY_TEST_PASSWORD", "ROAMTTY_TAP_POINTS"] {
            if let value = env[key] { app.launchEnvironment[key] = value }
        }
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopGesture-\(UUID().uuidString)"
        app.launchEnvironment["ROAMTTY_DESKTOP_INPUT_PROBE"] = "1"
        app.launchEnvironment["ROAMTTY_DESKTOP_POINTER"] = pointer
        app.launch()
        // Connected once the stats show the picture's size (a still screen sends 0 fps).
        let frames = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+×[0-9]+ .*'")).firstMatch
        XCTAssertTrue(frames.waitForExistence(timeout: 90), "the live desktop must be connected")
        continueAfterFailure = true
        let gestures = app.otherElements["desktop-video-surface"]
        XCTAssertTrue(gestures.waitForExistence(timeout: 5))
        surface = gestures.frame
        Thread.sleep(forTimeInterval: 2)
    }

    // MARK: Probe

    private var probe: XCUIElement { app.staticTexts["desktop-input-probe"] }

    /// The tokens since the last gesture began.
    private func tokens() -> [String] {
        guard probe.exists else { return [] }
        return probe.label.split(separator: " ").dropFirst().map(String.init)
    }

    /// Waits until the tokens hold `expected` in order (prefix matches: "m" for any move).
    @discardableResult
    private func expect(_ expected: [String], within seconds: Double = 3, _ step: String,
                        file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var seen: [String] = []
        repeat {
            seen = tokens()
            if Self.ordered(expected, in: seen) { return seen }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTFail("\(step): expected \(expected) in order, got \(seen)", file: file, line: line)
        return seen
    }

    private static func ordered(_ expected: [String], in seen: [String]) -> Bool {
        var i = 0
        for token in seen where i < expected.count {
            if token == expected[i] || (expected[i].hasSuffix("*") && token.hasPrefix(expected[i].dropLast())) { i += 1 }
        }
        return i == expected.count
    }

    private func none(_ prefix: String, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let seen = tokens()
        XCTAssertFalse(seen.contains { $0.hasPrefix(prefix) }, "\(step): no \(prefix) expected, got \(seen)", file: file, line: line)
    }

    private func capture(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    // MARK: Points

    private func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: surface.minX + surface.width * fx, y: surface.minY + surface.height * fy)
    }

    /// A point inside the host's picture, as fractions of it (the view letterboxes it).
    private func pic(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        let width = min(surface.width, surface.height / remoteAspect), height = width * remoteAspect
        return CGPoint(x: surface.midX - width / 2 + width * fx, y: surface.midY - height / 2 + height * fy)
    }

    private func pause(_ s: Double = 0.8) { Thread.sleep(forTimeInterval: s) }

    /// Esc from the keyboard panel's shortcut bar: closes a menu or an overview on the host.
    private func escape() {
        withShortcutBar { tapBarKey("Esc") }
    }

    /// Opens the keyboard panel with its shortcut bar, runs `body`, and closes the panel again.
    private func withShortcutBar(_ body: () -> Void) {
        let keys = app.buttons.matching(NSPredicate(format: "label == '键盘' OR label == 'Keys'")).firstMatch
        guard keys.waitForExistence(timeout: 3) else { return XCTFail("no keyboard button") }
        keys.tap()
        let toggle = app.buttons["desktop-kb-toggle"]
        if toggle.waitForExistence(timeout: 3) { toggle.tap() }
        body()
        let close = app.buttons.matching(NSPredicate(format: "label == '关闭键盘' OR label == 'Close keyboard'")).firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        pause(1)
    }

    private func tapBarKey(_ label: String) {
        let key = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        if key.waitForExistence(timeout: 3) { key.tap() } else { XCTFail("no \(label) key") }
    }

    /// Trackpad mode: the cursor to the middle of the host's screen, from its bottom-left corner by a slow
    /// slide (slow enough for the lowest, constant pointer gain of 0.5).
    private func centerCursor() throws {
        let corner = pic(0, 1)
        try Touches.perform([[(CGPoint(x: corner.x + 4, y: corner.y - 4), 0), (CGPoint(x: corner.x + 30, y: corner.y - 20), 0.2)]])
        expect(["m0,*", "fshortcut"], "a swipe in from the picture's bottom-left corner")
        pause(0.3)
        // At a gain of 0.5, sliding the picture's own width moves the cursor half the host's width.
        let width = min(surface.width, surface.height / remoteAspect), height = width * remoteAspect
        let from = CGPoint(x: surface.minX + surface.width * 0.05, y: surface.midY + height * 0.45)
        let to = CGPoint(x: from.x + width * 0.9, y: from.y - height * 0.9)
        var path: [(CGPoint, Double)] = []
        for i in 0...40 { let f = CGFloat(i) / 40; path.append((CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f), 0.2 * Double(i))) }
        try Touches.perform([path])
        pause(0.5)
    }

    /// Height over width of the host's screen, from the stats' size line.
    private var fixedAspect: CGFloat?
    private var remoteAspect: CGFloat {
        if let fixedAspect { return fixedAspect }
        let size = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+×[0-9]+ .*'")).firstMatch.label
        let parts = size.split(separator: " ").first?.split(separator: "×").compactMap { Double($0) } ?? []
        return parts.count == 2 && parts[0] > 0 ? CGFloat(parts[1] / parts[0]) : 0.625
    }

    /// The middle of the host's picture, small and grey, to tell whether the host's screen changed.
    private func picture() -> [UInt8] {
        let shot = XCUIScreen.main.screenshot().image
        guard let cg = shot.cgImage else { return [] }
        let scale = CGFloat(cg.width) / shot.size.width
        let height = min(surface.height, surface.width * remoteAspect)
        let rect = CGRect(x: surface.minX + surface.width * 0.1, y: surface.midY - height * 0.3,
                          width: surface.width * 0.8, height: height * 0.6)
        guard let crop = cg.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)) else { return [] }
        let w = 96, h = 48
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    private func share(_ a: [UInt8], _ b: [UInt8]) -> Double {
        Double(zip(a, b).filter { abs(Int($0) - Int($1)) > 16 }.count) / Double(max(1, a.count))
    }

    private func assertChanged(_ before: [UInt8], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        // The host's picture takes a moment to come: wait up to three seconds for it.
        var changed = 0, share = 0.0
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let after = picture()
            // Sensitive enough for a dark menu over a dark window (macOS dark mode); a still host
            // changes under 0.2% of the samples (video noise, the clock).
            changed = zip(before, after).filter { abs(Int($0) - Int($1)) > 16 }.count
            share = Double(changed) / Double(max(1, before.count))
            if share > 0.004 { break }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        XCTAssertGreaterThan(share, 0.004, "\(what): the host's picture did not change (\(changed) of \(before.count) samples)", file: file, line: line)
    }

    /// Swiping back works from the black bars beside the picture, as on any page, while an edge swipe that
    /// starts on the picture stays the desktop's. The offline layout fixture: no host needed.
    func testSwipeBackFromOutsideThePicture() throws {
        for landscape in [false, true] {
            app = XCUIApplication()
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["--desktop-controls-fixture"]
            app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopControlsFixture"
            app.launchEnvironment["ROAMTTY_DESKTOP_STATUS_FIXTURE"] = "connected"
            app.launchEnvironment["ROAMTTY_DESKTOP_FIXTURE_LANGUAGE"] = "zh-Hans"
            app.launch()
            fixedAspect = 720.0 / 1280 // the fixture's picture
            if landscape {
                XCUIDevice.shared.orientation = .landscapeRight
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
                pause(1)
            }
            let ops = app.buttons["操作"]
            XCTAssertTrue(ops.waitForExistence(timeout: 10))
            surface = app.otherElements["desktop-video-surface"].frame
            let screen = app.frame
            let mode = landscape ? "landscape" : "portrait"

            // From the screen's left edge, on the picture: the desktop keeps it.
            let onPicture = pic(0, 0.5)
            if onPicture.x - screen.minX < 20 {
                edgeSwipe(from: CGPoint(x: screen.minX + 1, y: onPicture.y), to: CGPoint(x: screen.minX + screen.width * 0.8, y: onPicture.y))
                pause(1.5)
                XCTAssertTrue(ops.exists && ops.isHittable, "\(mode): an edge swipe on the picture does not leave the page")
            }

            // From the screen's left edge, on a black bar: back to the home page.
            let bar = landscape ? CGPoint(x: screen.minX + 2, y: screen.midY)
                                : CGPoint(x: screen.minX + 2, y: (surface.minY + pic(0, 0).y) / 2)
            XCTAssertFalse(app.otherElements["desktop-video-surface"].frame.isEmpty)
            edgeSwipe(from: bar, to: CGPoint(x: screen.minX + screen.width * 0.8, y: bar.y))
            let home = app.buttons["home-tab-hosts"].waitForExistence(timeout: 5)
            if !home { capture("\(mode): still on the desktop after swiping back") }
            XCTAssertTrue(home, "\(mode): swiping back from the black bar leaves the desktop")
            capture("\(mode): back from the black bar")
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// A swipe in from the screen's edge through XCUITest's own drag, which the system's screen-edge
    /// recognizers accept (touches from the event synthesizer above carry no screen-edge flag).
    private func edgeSwipe(from: CGPoint, to: CGPoint) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: from.x, dy: from.y))
        start.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)), withVelocity: 600, thenHoldForDuration: 0)
    }

    /// The rail's 显示桌面, tapped again and again: each tap must reach the host at once and change its picture.
    func testShowDesktopButtonEveryTap() throws {
        try launch(pointer: "touch")
        let button = app.buttons["显示桌面"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        var report: [String] = []
        for i in 1...6 {
            let before = picture(), sent = probeCount()
            let tapped = Date()
            button.tap()
            let tapMs = Int(Date().timeIntervalSince(tapped) * 1000)
            // The app sent it?
            var sentMs = -1
            while Date().timeIntervalSince(tapped) < 3 {
                if probeCount() > sent, tokens().last == "a1" { sentMs = Int(Date().timeIntervalSince(tapped) * 1000); break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            // The host's picture changed?
            var changedMs = -1
            while Date().timeIntervalSince(tapped) < 5 {
                let after = picture()
                let share = Double(zip(before, after).filter { abs(Int($0) - Int($1)) > 16 }.count) / Double(max(1, before.count))
                if share > 0.02 { changedMs = Int(Date().timeIntervalSince(tapped) * 1000); break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            report.append("tap \(i): tap() \(tapMs) ms, sent \(sentMs) ms, picture changed \(changedMs) ms")
            capture("show desktop tap \(i)")
            pause(2)
        }
        NSLog("RoamttyShowDesktop %@", report.joined(separator: " | "))
        let a = XCTAttachment(string: report.joined(separator: "\n")); a.name = "show desktop timings"; a.lifetime = .keepAlways; add(a)
        for line in report {
            XCTAssertFalse(line.contains("sent -1"), line)
            XCTAssertFalse(line.contains("changed -1"), line)
        }
    }

    /// A Mac with a full-screen app in front (the runner activates it first): 显示桌面 must answer at once with the slide, and a second, impatient tap must not undo it.
    func testShowDesktopFromFullScreenTappedTwice() throws {
        try launch(pointer: "touch")
        let button = app.buttons["显示桌面"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        pause(1)
        capture("full-screen app in front")
        let app0 = picture()
        let tapped = Date()
        button.tap()
        button.tap() // the impatient second tap, a moment later
        var samples: [(ms: Int, pic: [UInt8])] = []
        while Date().timeIntervalSince(tapped) < 4 {
            samples.append((Int(Date().timeIntervalSince(tapped) * 1000), picture()))
            Thread.sleep(forTimeInterval: 0.05)
        }
        func differs(_ a: [UInt8], _ b: [UInt8]) -> Double {
            Double(zip(a, b).filter { abs(Int($0) - Int($1)) > 16 }.count) / Double(max(1, a.count))
        }
        let first = samples.first { differs(app0, $0.pic) > 0.02 }?.ms ?? -1
        let moving = zip(samples, samples.dropFirst()).filter { differs($0.pic, $1.pic) > 0.02 }.map { $1.ms }
        pause(1)
        let end = picture()
        capture("after two taps")
        let report = "first change \(first) ms, picture changed at \(moving) ms, end differs from the app by \(String(format: "%.2f", differs(app0, end)))"
        NSLog("RoamttyShowDesktopFullScreen %@", report)
        let a = XCTAttachment(string: report); a.name = "timings"; a.lifetime = .keepAlways; add(a)
        XCTAssertGreaterThanOrEqual(first, 0, report)
        XCTAssertLessThan(first, 1200, "the slide starts at once, the picture does not freeze: \(report)")
        XCTAssertGreaterThan(differs(app0, end), 0.2, "the second tap did not undo the first: the desktop shows. \(report)")
        // Back where it started: the app's Space, the desktop shown again hidden.
        button.tap()
        pause(1.5)
    }

    /// ⌃⌘F on the host through the shortcut bar's latched modifiers: puts a Mac's front window in full screen, or
    /// takes it out. Not `typeKey("f", modifierFlags:)`: the simulator hands the page a plain F, and the host gets that.
    func testToggleHostFullScreen() throws {
        try launch(pointer: "touch")
        withShortcutBar {
            tapBarKey("⌃")
            tapBarKey("⌘")
            app.typeText("f")
        }
        pause(3)
        capture("after control-command-F")
    }

    /// Connects and looks, sending nothing: to see what is on a host before testing on it.
    func testLookAtHost() throws {
        try launch(pointer: "mouse")
        capture("host screen")
    }

    /// Taps the host's screen at ROAMTTY_TAP_POINTS ("x,y;x,y", fractions of the host's screen), in touch mode.
    func testTapHostPoints() throws {
        try launch(pointer: "touch")
        let width = min(surface.width, surface.height / remoteAspect), height = width * remoteAspect
        let left = surface.midX - width / 2, top = surface.midY - height / 2
        for pair in (ProcessInfo.processInfo.environment["ROAMTTY_TAP_POINTS"] ?? "").split(separator: ";") {
            // "d0.3,0.1": a double tap.
            let double = pair.hasPrefix("d")
            let f = pair.drop { $0 == "d" }.split(separator: ",").compactMap { Double($0) }
            guard f.count == 2 else { continue }
            let p = CGPoint(x: left + width * f[0], y: top + height * f[1])
            if double { try Touches.perform([[(p, 0), (p, 0.06)]], then: [[(p, 0.2), (p, 0.26)]]) } else { try Touches.tap([p]) }
            pause(1.5)
        }
        capture("after taps")
    }

    /// A host at its lock screen (a Mac whose login is the test login): types the password there.
    func testUnlockHost() throws {
        try launch(pointer: "mouse")
        let keys = app.buttons.matching(NSPredicate(format: "label == '键盘' OR label == 'Keys'")).firstMatch
        XCTAssertTrue(keys.waitForExistence(timeout: 5)); keys.tap()
        pause(1.5)
        app.typeText(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD"] ?? "")
        pause(0.5)
        app.typeText("\n")
        pause(3)
        let close = app.buttons.matching(NSPredicate(format: "label == '关闭键盘' OR label == 'Close keyboard'")).firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
        pause(1)
        capture("after unlocking")
    }

    // MARK: Trackpad mode

    func testTrackpadModeGestures() throws {
        try launch(pointer: "mouse")
        let mid = at(0.5, 0.5)
        // Wherever an earlier run left the cursor (on the Dock, say), the clicks start in the middle.
        try centerCursor()

        try Touches.tap([mid])
        expect(["b1d", "b1u"], "one-finger tap clicks at once")
        none("m", "a tap does not move the cursor")
        pause()

        try Touches.perform([[(mid, 0), (mid, 0.06)]], then: [[(mid, 0.2), (mid, 0.26)]])
        expect(["b1d", "b1u", "b1d", "b1u"], "double tap is a double click")
        pause()

        try Touches.perform([[(at(0.3, 0.5), 0), (at(0.6, 0.45), 0.35)]])
        expect(["m*"], "one finger moves the cursor")
        none("b", "moving presses nothing")
        pause()

        try centerCursor()
        var before = picture()
        try Touches.tap([at(0.45, 0.5), at(0.55, 0.5)])
        expect(["b2d", "b2u", "fclick"], within: 2, "two-finger tap right clicks")
        pause(0.5)
        assertChanged(before, "a menu opened on the host")
        capture("trackpad: right click menu")
        escape()

        try Touches.tap([at(0.4, 0.5), at(0.5, 0.5), at(0.6, 0.5)])
        expect(["b3d", "b3u", "fclick"], "three-finger tap middle clicks")
        pause()

        before = picture()
        try Touches.perform([[(mid, 0), (mid, 0.6)]])
        expect(["fhold", "b2d", "b2u", "fclick"], "hold and lift right clicks")
        pause(0.5)
        assertChanged(before, "a menu opened on the host")
        capture("trackpad: hold menu")
        escape()

        try Touches.perform([[(at(0.4, 0.4), 0), (at(0.4, 0.4), 0.5), (at(0.55, 0.5), 1.0)]])
        expect(["fhold", "b1d", "fpickup", "m*", "b1u"], "hold and move drags")
        pause()

        try Touches.perform([[(at(0.45, 0.4), 0), (at(0.45, 0.4), 0.7), (at(0.45, 0.55), 1.2)],
                             [(at(0.55, 0.4), 0), (at(0.55, 0.4), 0.7), (at(0.55, 0.55), 1.2)]])
        expect(["fhold", "b2d", "fpickup", "m*", "b2u"], "two-finger hold and move right drags")
        pause(1)
        escape()

        try centerCursor()
        try twoFingerScroll()
        try pinchAndSmartZoom(touch: false)
        try edgeSwipes(trackpad: true)
        try threeFingerSwipes()
    }

    // MARK: Touch mode

    func testTouchModeGestures() throws {
        try launch(pointer: "touch")
        let mid = at(0.5, 0.5)

        try Touches.tap([mid])
        let tap = expect(["m*", "b1d", "b1u"], "tap clicks where the finger is")
        pause()

        // A second tap a few points off lands on the same pixel.
        let jitter = CGPoint(x: mid.x + 4, y: mid.y + 3)
        try Touches.perform([[(mid, 0), (mid, 0.06)]], then: [[(jitter, 0.18), (jitter, 0.24)]])
        let double = expect(["m*", "b1d", "b1u", "m*", "b1d", "b1u"], "double tap")
        let moves = double.filter { $0.hasPrefix("m") }
        XCTAssertEqual(Set(moves).count, 1, "both clicks on one pixel: \(double)")
        XCTAssertEqual(moves.first, tap.first { $0.hasPrefix("m") })
        pause()

        // One finger flicks the document under it, as on a phone: the cursor goes there, then the
        // wheel, and the scroll carries on after lifting.
        let page = picture()
        try Touches.perform([[(pic(0.5, 0.75), 0), (pic(0.5, 0.25), 0.15)]])
        let slide = expect(["m*", "w*"], "one finger scrolls what is under it")
        none("b", "a slide presses nothing")
        none("z", "at full size a slide leaves the picture alone")
        XCTAssertLessThan(slide.first { $0.hasPrefix("w") }.flatMap { Int($0.split(separator: ",").last ?? "") } ?? 0, 0,
                          "finger going up scrolls down: \(slide)")
        let lifted = probeCount()
        pause(0.6)
        XCTAssertGreaterThan(probeCount(), lifted + 3, "a flick carries on after lifting")
        pause(1)
        if share(page, picture()) <= 0.004 {
            // At the end of the document already: the flick the other way must scroll it.
            let end = picture()
            try Touches.perform([[(pic(0.5, 0.25), 0), (pic(0.5, 0.75), 0.15)]])
            assertChanged(end, "the document under the finger scrolled (back from its end)")
        } else {
            capture("touch: one-finger scroll")
            pause(2)
            try Touches.perform([[(pic(0.5, 0.25), 0), (pic(0.5, 0.75), 0.15)]])
        }
        pause(2.5)

        var before = picture()
        try Touches.perform([[(mid, 0), (mid, 0.6)]])
        expect(["m*", "fhold", "b2d", "b2u", "fclick"], "hold and lift right clicks")
        pause(0.5)
        assertChanged(before, "a menu opened on the host")
        capture("touch: hold menu")
        pause(1)
        escape()

        try Touches.perform([[(at(0.4, 0.4), 0), (at(0.4, 0.4), 0.5), (at(0.55, 0.5), 1.0)]])
        expect(["fhold", "m*", "b1d", "fpickup", "m*", "b1u"], "hold and move drags from where the finger landed")
        pause()

        before = picture()
        try Touches.tap([at(0.45, 0.5), at(0.55, 0.5)])
        expect(["m*", "b2d", "b2u", "fclick"], within: 2, "two-finger tap right clicks at the middle")
        pause(0.5)
        assertChanged(before, "a menu opened on the host")
        capture("touch: right click menu")
        pause(1)
        escape()

        try Touches.tap([at(0.4, 0.5), at(0.5, 0.5), at(0.6, 0.5)])
        expect(["m*", "b3d", "b3u", "fclick"], "three-finger tap middle clicks")
        pause()

        try twoFingerScroll()
        try pinchAndSmartZoom(touch: true)
        try edgeSwipes(trackpad: false)
    }

    // MARK: Shared

    private func twoFingerScroll() throws {
        let before = picture()
        // A flick: the wheel keeps going after the fingers lift.
        try Touches.perform([[(pic(0.45, 0.75), 0), (pic(0.45, 0.25), 0.15)], [(pic(0.55, 0.75), 0), (pic(0.55, 0.25), 0.15)]])
        let during = expect(["w*"], "two fingers scroll")
        none("b", "scrolling presses nothing")
        none("z", "scrolling leaves the picture alone")
        let first = during.first { $0.hasPrefix("w") }.flatMap { Int($0.split(separator: ",").last ?? "") } ?? 0
        XCTAssertLessThan(first, 0, "fingers going up scroll down: \(during)")
        let countAtLift = probeCount()
        pause(0.6)
        XCTAssertGreaterThan(probeCount(), countAtLift + 3, "inertia carries the scroll on after lifting")
        pause(1)
        let back: [Touches.Finger] = [[(pic(0.45, 0.25), 0), (pic(0.45, 0.75), 0.15)], [(pic(0.55, 0.25), 0), (pic(0.55, 0.75), 0.15)]]
        if share(before, picture()) <= 0.004 {
            // At the end of the document already, as touch mode allows: the flick the other way must scroll it.
            let end = picture()
            try Touches.perform(back)
            assertChanged(end, "the document under the cursor scrolled (back from its end)")
        } else {
            capture("scrolled")
            pause(2)
            try Touches.perform(back)
        }
        pause(2.5)
    }

    private func probeCount() -> Int {
        guard probe.exists else { return 0 }
        return Int(probe.label.split(separator: " ").first?.dropFirst() ?? "") ?? 0
    }

    private func pinchAndSmartZoom(touch: Bool) throws {
        try Touches.perform([[(at(0.45, 0.5), 0), (at(0.3, 0.5), 0.4)], [(at(0.55, 0.5), 0), (at(0.7, 0.5), 0.4)]])
        let pinch = expect(["z*"], "pinch zooms")
        none("w", "pinching does not scroll")
        none("b", "pinching does not click")
        XCTAssertGreaterThan(Double(pinch.last { $0.hasPrefix("z") }?.dropFirst() ?? "") ?? 0, 1.5)
        capture("pinched")
        pause()
        // Zoomed in, two fingers still scroll the host.
        try Touches.perform([[(at(0.45, 0.6), 0), (at(0.45, 0.45), 0.4)], [(at(0.55, 0.6), 0), (at(0.55, 0.45), 0.4)]])
        expect(["w*"], "zoomed in, two fingers scroll")
        none("z", "zoomed in, scrolling leaves the picture alone")
        pause(1.5)
        if touch {
            // Zoomed in, one finger moves the picture, as a zoomed photo; the host does not scroll.
            // Sideways: in portrait the zoomed picture still fits the height, so only its width can move.
            try Touches.perform([[(at(0.5, 0.5), 0), (at(0.4, 0.5), 0.5)]])
            expect(["m*", "z*"], "zoomed in, one finger moves the picture")
            none("w", "inside the zoomed picture, a slide does not scroll the host")
            none("b", "moving the picture presses nothing")
            capture("touch: zoomed picture moved")
            pause()
        }
        // Two-finger double tap: out to the whole screen, then in to 2.5×, then out.
        let a = at(0.45, 0.4), b = at(0.55, 0.4)
        for (step, zoom) in [("smart zoom out", "z1.00"), ("smart zoom in", "z2.50"), ("smart zoom back out", "z1.00")] {
            try Touches.perform([[(a, 0), (a, 0.06)], [(b, 0), (b, 0.06)]], then: [[(a, 0.2), (a, 0.26)], [(b, 0.2), (b, 0.26)]])
            expect([zoom, "fshortcut"], step)
            none("b", "\(step) does not right click")
            pause()
        }
    }

    private func edgeSwipes(trackpad: Bool) throws {
        let left = pic(0, 0.5)
        try Touches.perform([[(CGPoint(x: left.x + 4, y: left.y), 0), (CGPoint(x: left.x + 80, y: left.y), 0.2)]])
        expect(["m0,*", "fshortcut"], "a swipe in from the left edge puts the cursor on the host's left edge")
        pause()
        let bottom = pic(0.5, 1)
        try Touches.perform([[(CGPoint(x: bottom.x, y: bottom.y - 4), 0), (CGPoint(x: bottom.x, y: bottom.y - 80), 0.2)]])
        expect(["m*", "fshortcut"], "a swipe up from the bottom edge reaches the host's bottom edge")
        capture(trackpad ? "trackpad: cursor on the bottom edge" : "touch: cursor on the bottom edge")
        pause()
    }

    private func threeFingerSwipes() throws {
        for (dx, dy, token) in [(CGFloat(0), CGFloat(-0.25), "sup"), (0, 0.25, "sdown"), (-0.3, 0, "sleft"), (0.3, 0, "sright")] {
            let fingers = [0.4, 0.5, 0.6].map { fx -> [(CGPoint, Double)] in
                [(at(fx, 0.5), 0), (at(fx + dx, 0.5 + dy), 0.3)]
            }
            try Touches.perform(fingers)
            expect([token, "fshortcut"], "three-finger swipe \(token)")
            capture("three-finger \(token)")
            pause(1.5)
            if token == "sup" { escape() }
            if token == "sdown" {
                // Showing the desktop again brings the windows back.
                try Touches.perform(fingers)
                pause(1.5)
            }
        }
    }
}

/// Multi-finger touches through XCTest's event synthesizer (what WebDriverAgent uses): XCUITest's public
/// API has no two-finger slide, hold or three-finger swipe.
enum Touches {
    typealias Finger = [(CGPoint, Double)]

    static func tap(_ points: [CGPoint]) throws {
        try perform(points.map { [($0, 0), ($0, 0.06)] })
    }

    /// Each finger lands at its first point, moves through the rest at their offsets (seconds), and lifts at the last.
    /// `then`: a second set of fingers in the same record, offsets counted from the same start.
    static func perform(_ fingers: [Finger], then more: [Finger] = []) throws {
        guard let recordClass = NSClassFromString("XCSynthesizedEventRecord"),
              let pathClass = NSClassFromString("XCPointerEventPath") else { throw XCTSkip("No XCTest event synthesizer") }
        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>
        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>
        typealias MoveTo = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias LiftUp = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias AddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synthesize = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool

        func alloc(_ cls: AnyClass) -> AnyObject {
            (cls as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        }
        func imp<T>(_ object: AnyObject, _ name: String, _: T.Type) -> (T, Selector) {
            let sel = NSSelectorFromString(name)
            return (unsafeBitCast(object.method(for: sel), to: T.self), sel)
        }
        let recordAlloc = alloc(recordClass)
        let (initRecord, initRecordSel) = imp(recordAlloc, "initWithName:interfaceOrientation:", InitRecord.self)
        let record = initRecord(recordAlloc, initRecordSel, "roamtty gesture", 1).takeUnretainedValue()
        for finger in fingers + more {
            guard let first = finger.first, let last = finger.last else { continue }
            let pathAlloc = alloc(pathClass)
            let (initPath, initPathSel) = imp(pathAlloc, "initForTouchAtPoint:offset:", InitPath.self)
            let path = initPath(pathAlloc, initPathSel, first.0, first.1).takeUnretainedValue()
            let (moveTo, moveSel) = imp(path, "moveToPoint:atOffset:", MoveTo.self)
            for point in finger.dropFirst() { moveTo(path, moveSel, point.0, point.1) }
            let (lift, liftSel) = imp(path, "liftUpAtOffset:", LiftUp.self)
            lift(path, liftSel, last.1)
            let (add, addSel) = imp(record, "addPointerEventPath:", AddPath.self)
            add(record, addSel, path)
        }
        let (synthesize, synthesizeSel) = imp(record, "synthesizeWithError:", Synthesize.self)
        var error: NSError?
        if !synthesize(record, synthesizeSel, &error) { throw error ?? NSError(domain: "Touches", code: 1) }
    }
}
