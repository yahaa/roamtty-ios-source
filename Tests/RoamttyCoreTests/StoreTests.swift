import XCTest
import CNative
@testable import RoamttyCore

final class StoreTests: XCTestCase {
    func testHostsKeepRecentUseOrderAfterReopeningStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hosts.sqlite")
        let store = try AppStore(url: url)
        // Saved order deliberately differs from recent-use order. Missing timestamps model older installs.
        for (id, usedAt) in [("unused-a", nil), ("older", 100.0), ("newest-a", 300.0),
                             ("unused-b", nil), ("newest-b", 300.0), ("middle", 200.0)] as [(String, Double?)] {
            let host = Host(id: id, name: id, address: "example.org", username: "test")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
            json["lastUsedAt"] = usedAt
            try store.saveHost(JSONDecoder().decode(Host.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        let expected = ["newest-a", "newest-b", "middle", "older", "unused-a", "unused-b"]
        XCTAssertEqual(try store.hosts().map(\.id), expected)
        XCTAssertEqual(try AppStore(url: url).hosts().map(\.id), expected)
    }

    func testDeletionRemovesJournalButRetainsIndependentTrust() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppStore(url: root.appendingPathComponent("test.sqlite"))
        let host = Host(name: "Test", address: "example.org", username: "alice")
        try store.saveHost(host)
        var journal = SessionJournal()
        _ = try journal.create(hostID: host.id, mode: .tmux)
        try store.saveJournal(journal)
        let pin = HostPin(endpoint: host.endpoint, algorithm: "ssh-ed25519", key: Data([1, 2, 3]))
        _ = try store.putIfAbsent(pin)
        try store.deleteHost(id: host.id)
        XCTAssertTrue(try store.hosts().isEmpty)
        XCTAssertTrue(try store.loadJournal().records.isEmpty)
        XCTAssertEqual(try store.pin(endpoint: host.endpoint), pin)
    }
    func testFirstWriterWinsAndMismatchCannotReplacePin() throws {
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let first = HostPin(endpoint: "[a]:22", algorithm: "ssh-ed25519", key: Data([1]))
        let second = HostPin(endpoint: "[a]:22", algorithm: "ssh-ed25519", key: Data([2]))
        try TrustPolicy(store: store).verify(first) { true }
        XCTAssertThrowsError(try TrustPolicy(store: store).verify(second) { true })
        XCTAssertEqual(try store.putIfAbsent(second), first)
        try store.forgetPin(endpoint: first.endpoint)
        XCTAssertThrowsError(try TrustPolicy(store: store).verify(second) { false })
        XCTAssertNil(try store.pin(endpoint: first.endpoint))
    }
    func testSettingsAndHostRoundTripWithoutSecrets() throws {
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        var host = Host(name: "中国", address: "::1", username: "test")
        host.savePassword = true
        try store.saveHost(host)
        XCTAssertEqual(try store.hosts(), [host])
        var settings = AppSettings(); settings.language = "en"; settings.theme = .light
        try store.saveSettings(settings)
        XCTAssertEqual(try store.loadSettings(), settings)
    }
    func testFingerprintMatchesKnownSHA256() {
        let pin = HostPin(endpoint: "x", algorithm: "x", key: Data("abc".utf8))
        XCTAssertEqual(pin.fingerprint, "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
    }
    func testLegacySQLiteSettingsKeepAllExistingPreferencesAfterUpgrade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.sqlite")
        let store = try AppStore(url: url)
        let legacy = #"{"theme":"light","language":"en","font":"FiraCode-Regular","fontSize":19,"showHiddenFiles":true,"toolboxPinned":true,"downloadBookmark":"AQID"}"#
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO settings(id,json) VALUES(1,'" + legacy + "')", nil, nil, nil), SQLITE_OK)
        var settings = try store.loadSettings()
        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(settings.language, "en")
        XCTAssertEqual(settings.font, "FiraCode-Regular")
        XCTAssertEqual(settings.fontSize, 19)
        XCTAssertTrue(settings.showHiddenFiles)
        XCTAssertTrue(settings.toolboxPinned)
        XCTAssertEqual(settings.downloadBookmark, Data([1, 2, 3]))
        XCTAssertEqual(settings.fileSort, .name)
        XCTAssertFalse(settings.fileSortDescending)
        XCTAssertFalse(settings.codeWrap)
        XCTAssertEqual(settings.codeFontSize, 13, "Preview size is independent of the terminal's size")
        settings.chooseFileSort(.type); settings.fileSortDescending = true
        settings.codeWrap = true; settings.codeFontSize = 17
        try store.saveSettings(settings)
        XCTAssertEqual(try AppStore(url: url).loadSettings(), settings)
    }
    func testMissingAndUnknownSettingsDefaultOnlyTheirOwnFields() throws {
        let data = Data(#"{"theme":"light","language":"en","fontSize":18,"fileSort":"future-order","codeFontSize":90,"codeWrap":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(settings.language, "en")
        XCTAssertEqual(settings.fontSize, 18)
        XCTAssertEqual(settings.font, "JetBrainsMono-Regular")
        XCTAssertEqual(settings.fileSort, .name)
        XCTAssertTrue(settings.codeWrap)
        XCTAssertEqual(settings.codeFontSize, 22)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"codeFontSize":3}"#.utf8)).codeFontSize, 9)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)), AppSettings())
    }

    /// Launch regression: pre-desktop settings blobs must decode, and so must blobs from builds with the old 实验功能 switch.
    func testDesktopSettingsDefaultsAndSurviveLegacyJSON() throws {
        let empty = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.desktopKeepAliveMinutes, 10)
        XCTAssertFalse(empty.desktopShowStats)
        XCTAssertTrue(empty.desktopHosts.isEmpty)
        XCTAssertEqual(empty.desktopPluginBaseUrl, "")

        // Legacy blob without any desktop keys (what existing installs have on disk).
        let legacy = Data(#"{"theme":"dark","language":"zh-Hans","font":"JetBrainsMono-Regular","fontSize":13}"#.utf8)
        let fromLegacy = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(fromLegacy.desktopKeepAliveMinutes, 10)

        // Corrupt desktop fields must not fail the whole decode (would surface as a launch error).
        let corrupt = Data(#"{"theme":"light","desktopEnabled":"yes","desktopKeepAliveMinutes":"forever","desktopHosts":[]}"#.utf8)
        let recovered = try JSONDecoder().decode(AppSettings.self, from: corrupt)
        XCTAssertEqual(recovered.theme, .light)
        XCTAssertEqual(recovered.desktopKeepAliveMinutes, 10)
        XCTAssertTrue(recovered.desktopHosts.isEmpty)

        // Per-host preferences saved before 声音 existed keep everything else, and sound is on.
        let beforeAudio = Data(#"{"desktopHosts":{"h1":{"pointerMode":"mouse","quality":"clear","fps":90,"lockOnClose":true}}}"#.utf8)
        let kept = try XCTUnwrap(try JSONDecoder().decode(AppSettings.self, from: beforeAudio).desktopHosts["h1"])
        XCTAssertEqual([kept.pointerMode, kept.quality], ["mouse", "clear"])
        XCTAssertEqual(kept.fps, 90)
        XCTAssertTrue(kept.lockOnClose)
        XCTAssertTrue(kept.audio)
        var muted = DesktopHostSettings(); muted.audio = false
        XCTAssertFalse(try JSONDecoder().decode(DesktopHostSettings.self, from: JSONEncoder().encode(muted)).audio)

        // Round-trip with desktop preferences set.
        var on = AppSettings()
        on.desktopKeepAliveMinutes = 30
        on.desktopShowStats = true
        var hostPrefs = DesktopHostSettings()
        hostPrefs.pointerMode = "mouse"; hostPrefs.quality = "clear"; hostPrefs.fps = 90; hostPrefs.lockOnClose = true
        on.desktopHosts["h1"] = hostPrefs
        let data = try JSONEncoder().encode(on)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back, on)
    }

    /// Android's M-01: a first launch follows the phone's language; a saved choice is kept.
    func testFirstLaunchFollowsThePhonesLanguage() throws {
        XCTAssertEqual(AppSettings.defaultLanguage(preferred: ["zh-Hans-CN", "en-US"]), "zh-Hans")
        XCTAssertEqual(AppSettings.defaultLanguage(preferred: ["zh-Hant-TW"]), "zh-Hans")
        XCTAssertEqual(AppSettings.defaultLanguage(preferred: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(AppSettings.defaultLanguage(preferred: ["fr-FR"]), "en")
        XCTAssertEqual(AppSettings.defaultLanguage(preferred: []), "en")
        let saved = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"language":"zh-Hans"}"#.utf8))
        XCTAssertEqual(saved.language, "zh-Hans")
    }
}
