// macOS: swiftc App/Roamtty/Features/Settings/Fonts/CustomFontStore.swift scripts/test-font-catalog.swift -o /tmp/roamtty-font-checks
// /tmp/roamtty-font-checks App/Roamtty/Resources/Fonts/JetBrainsMono-Regular.ttf App/Roamtty/Resources/Fonts/FiraCode-Regular.ttf
import Foundation
import CoreGraphics
import CoreText

@main enum FontCatalogChecks {
    private struct Failure: Error { let message: String }
    private static var checks = 0
    private static func require(_ result: Bool, _ message: String) throws {
        checks += 1
        if !result { throw Failure(message: message) }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw Failure(message: "Pass two real bundled font paths") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let other = URL(fileURLWithPath: CommandLine.arguments[2])
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("roamtty-font-check-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let directory = root.appendingPathComponent("slot", isDirectory: true)
        let store = CustomFontStore(directory: directory)
        let first = try store.install(source)
        try require(first.record.postScriptName == "JetBrainsMono-Regular", "Real font metadata must be read from its bytes")
        try require(first.record.displayName == source.lastPathComponent, "The picker filename must persist separately from the PostScript name")

        let ct = CTFontCreateWithGraphicsFont(first.graphicsFont, 13, nil, nil)
        let characters = Array("Wi".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: 2)
        try require(CTFontGetGlyphsForCharacters(ct, characters, &glyphs, 2), "The imported font must resolve actual glyphs")
        var advances = [CGSize](repeating: .zero, count: 2)
        _ = CTFontGetAdvancesForGlyphs(ct, .horizontal, glyphs, &advances, 2)
        try require(advances[0].width > 0 && abs(advances[0].width - advances[1].width) < 0.001, "CoreText must render the real monospace face")
        let fallback = CTFontDescriptorCreateWithNameAndSize("Helvetica" as CFString, 13)
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: [fallback]] as CFDictionary)
        let cascaded = CTFontCreateCopyWithAttributes(ct, 13, nil, descriptor)
        try require(CTFontCopyPostScriptName(cascaded) as String == first.record.postScriptName, "Adding the glyph cascade must preserve the imported face")

        // Reproduce the global CoreText registration collision that broke the
        // previous importer. The custom slot must still accept repeated imports.
        var registrationError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(source as CFURL, .process, &registrationError)
        _ = registrationError?.takeRetainedValue()
        defer { if registered { CTFontManagerUnregisterFontsForURL(source as CFURL, .process, nil) } }
        var duplicateError: Unmanaged<CFError>?
        let duplicateRegistration = CTFontManagerRegisterFontsForURL(source as CFURL, .process, &duplicateError)
        let duplicateCode = duplicateError.map { CFErrorGetCode($0.takeRetainedValue()) }
        try require(!duplicateRegistration && duplicateCode == CTFontManagerError.alreadyRegistered.rawValue, "The fixture must exercise an already-registered CoreText name")
        let repeated = try store.install(source)
        try require(repeated.record.postScriptName == first.record.postScriptName, "Repeated import of an already registered face must succeed")
        try require(!manager.fileExists(atPath: directory.appendingPathComponent(first.record.fileName).path), "Replacement must remove the previous slot asset")
        try require(try manager.contentsOfDirectory(atPath: directory.path).count == 2, "Repeated imports must leave one asset and one manifest")

        let manifest = directory.appendingPathComponent("custom-font.json")
        let previousManifest = try Data(contentsOf: manifest)
        let previousBytes = try Data(contentsOf: directory.appendingPathComponent(repeated.record.fileName))
        let invalid = root.appendingPathComponent("invalid.ttf")
        try Data("This is text, not a font".utf8).write(to: invalid)
        do {
            _ = try store.install(invalid)
            throw Failure(message: "Invalid font was accepted")
        } catch let error as CustomFontError {
            try require(error == .unsupported, "Invalid TTF bytes must be rejected by font validation")
        }
        try require(try Data(contentsOf: manifest) == previousManifest, "Invalid import must preserve the previous metadata atomically")
        try require(try Data(contentsOf: directory.appendingPathComponent(repeated.record.fileName)) == previousBytes, "Invalid import must preserve the previous font bytes")

        // A real filesystem write failure after validation must preserve the old
        // slot too. This test runs as the normal macOS user, not as root.
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        do {
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            do { _ = try store.install(other); throw Failure(message: "A read-only directory accepted replacement") } catch is CocoaError { checks += 1 }
        }
        try require(try Data(contentsOf: manifest) == previousManifest, "Failed publication must not change the active manifest")

        let boundary = root.appendingPathComponent("boundary.ttf")
        var padded = try Data(contentsOf: source)
        padded.append(Data(repeating: 0, count: CustomFontStore.byteLimit - padded.count))
        try padded.write(to: boundary)
        let exact = try store.install(boundary)
        try require(exact.record.postScriptName == first.record.postScriptName, "A valid font exactly 16 MiB must be accepted")
        let beforeOversize = try Data(contentsOf: manifest)
        let oversized = root.appendingPathComponent("too-large.ttf")
        padded.append(0); try padded.write(to: oversized)
        do {
            _ = try store.install(oversized)
            throw Failure(message: "Oversized font was accepted")
        } catch let error as CustomFontError {
            try require(error == .tooLarge, "16 MiB plus one byte must be rejected before publication")
        }
        try require(try Data(contentsOf: manifest) == beforeOversize, "Oversized import must preserve the existing custom slot")

        let orphan = directory.appendingPathComponent("custom-" + UUID().uuidString + ".font")
        try Data(contentsOf: source).write(to: orphan)
        let restored = try CustomFontStore(directory: directory).load()
        try require(restored?.record == exact.record, "A new store must restore the committed custom choice")
        try require(!manager.fileExists(atPath: orphan.path), "Restart must remove a pre-commit orphan without deleting the active asset")
        let second = try store.install(other)
        try require(second.record.postScriptName == "FiraCode-Regular", "A different valid font must replace the single custom slot")
        try require(!manager.fileExists(atPath: directory.appendingPathComponent(exact.record.fileName).path), "Replacement must release old custom bytes")

        try require(TerminalFontSelection.afterClearingCustom("custom", customName: second.record.postScriptName) == TerminalFontSelection.defaultFont,
            "Clearing the selected custom face must choose JetBrains Mono")
        try require(TerminalFontSelection.afterClearingCustom("FiraCode-Regular", customName: second.record.postScriptName) == "FiraCode-Regular",
            "Clearing custom must preserve an independently selected bundled face with the same PostScript name")
        try require(TerminalFontSelection.afterClearingCustom("system", customName: second.record.postScriptName) == "system", "Clearing custom must preserve system monospace selection")
        try store.clear()
        try require(try store.load() == nil, "Clearing must unpublish the custom choice")
        try require(try manager.contentsOfDirectory(atPath: directory.path).isEmpty, "Clearing must remove custom metadata and font assets")
        try require(TerminalFontSelection.restored("custom", customName: nil) == TerminalFontSelection.defaultFont, "A missing custom slot must recover to the default font")
        try require(TerminalFontSelection.restored("IBMPlexMono-Regular", customName: nil) == "IBMPlexMono", "Existing saved IBM font spelling must remain compatible")

        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        try manager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let old = legacyDirectory.appendingPathComponent(UUID().uuidString + ".ttf")
        let newer = legacyDirectory.appendingPathComponent(UUID().uuidString + ".ttf")
        try Data(contentsOf: source).write(to: old); try Data(contentsOf: other).write(to: newer)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: old.path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newer.path)
        let migrated = try CustomFontStore(directory: legacyDirectory).migrateLegacy(selected: first.record.postScriptName)
        try require(migrated?.record.postScriptName == first.record.postScriptName, "Migration must retain the selected legacy face even when another import is newer")
        try require(!manager.fileExists(atPath: old.path) && !manager.fileExists(atPath: newer.path), "Migration must remove obsolete UUID-named imports after committing")
        try require(TerminalFontSelection.restored("AndaleMono", customName: "AndaleMono") == "custom", "Older imported PostScript selections must map to the persistent custom slot")
        print("Font catalog checks passed: \(checks)")
    }
}
