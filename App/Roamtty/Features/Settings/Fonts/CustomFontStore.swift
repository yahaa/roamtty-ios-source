import Foundation
import CoreGraphics
import CoreText

enum TerminalFontSelection {
    static let system = "system"
    static let custom = "custom"
    static let defaultFont = "JetBrainsMono-Regular"
    static let bundled = [defaultFont, "FiraCode-Regular", "SourceCodePro-Regular", "IBMPlexMono", "CascadiaMono-Regular"]

    static func restored(_ selection: String, customName: String?) -> String {
        if selection == "IBMPlexMono-Regular" { return "IBMPlexMono" }
        if selection == system || bundled.contains(selection) { return selection }
        if customName != nil, selection == custom || selection == customName { return custom }
        return defaultFont
    }

    static func afterClearingCustom(_ selection: String, customName: String?) -> String {
        selection == custom || (!bundled.contains(selection) && selection == customName) ? defaultFont : selection
    }
}

struct CustomFontRecord: Codable, Equatable {
    let fileName: String
    let postScriptName: String
    let displayName: String
}

struct LoadedCustomFont {
    let record: CustomFontRecord
    let graphicsFont: CGFont
}

enum CustomFontError: Error, LocalizedError, Equatable {
    case empty, tooLarge, unsupported, invalidMetadata
    var errorDescription: String? {
        switch self {
        case .empty: return "字体文件为空 / The font file is empty"
        case .tooLarge: return "字体文件不能超过 16 MiB / Font files must be at most 16 MiB"
        case .unsupported: return "不是有效的 TTF 或 OTF 字体 / Not a valid TTF or OTF font"
        case .invalidMetadata: return "自定义字体记录无效 / The custom font record is invalid"
        }
    }
}

/// The manifest is the commit point. New bytes are fully validated and written
/// under a unique name before replacing it, so failed imports retain the old slot.
final class CustomFontStore {
    static let byteLimit = 16 * 1024 * 1024
    let directory: URL
    private var manifest: URL { directory.appendingPathComponent("custom-font.json") }
    private let manager = FileManager.default

    init(directory: URL) { self.directory = directory }

    func load() throws -> LoadedCustomFont? {
        guard manager.fileExists(atPath: manifest.path) else { return nil }
        let metadata = try Self.readBounded(manifest, limit: 16 * 1024)
        let record = try JSONDecoder().decode(CustomFontRecord.self, from: metadata)
        guard isOwnedAsset(record.fileName), !record.displayName.isEmpty else { throw CustomFontError.invalidMetadata }
        let data = try Self.readBounded(directory.appendingPathComponent(record.fileName))
        let font = try Self.validate(data)
        guard font.name == record.postScriptName else { throw CustomFontError.invalidMetadata }
        prune(except: record.fileName)
        return LoadedCustomFont(record: record, graphicsFont: font.font)
    }

    func install(_ source: URL) throws -> LoadedCustomFont {
        let data = try Self.readBounded(source)
        let display = String(source.lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(160))
        return try commit(data, displayName: display)
    }

    /// Earlier versions retained UUID-named files without metadata. Preserve the
    /// selected face when possible; otherwise retain the most recent valid import.
    func migrateLegacy(selected: String) throws -> LoadedCustomFont? {
        guard !manager.fileExists(atPath: manifest.path) else { return try load() }
        let files = ((try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast)
            }
        var newest: (Data, String)?
        for file in files {
            guard let data = try? Self.readBounded(file), let valid = try? Self.validate(data) else { continue }
            if valid.name == selected { return try commit(data, displayName: valid.name) }
            if newest == nil { newest = (data, valid.name) }
        }
        if let newest { return try commit(newest.0, displayName: newest.1) }
        return nil
    }

    func clear() throws {
        // Removing the small manifest atomically unpublishes the custom choice.
        // Unreferenced assets can then be cleaned without exposing a partial slot.
        if manager.fileExists(atPath: manifest.path) { try manager.removeItem(at: manifest) }
        prune(except: nil)
    }

    static func readBounded(_ url: URL, limit: Int = byteLimit) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while true {
            let remaining = limit + 1 - data.count
            guard remaining > 0 else { throw CustomFontError.tooLarge }
            let chunk = try file.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= limit else { throw CustomFontError.tooLarge }
        }
        guard !data.isEmpty else { throw CustomFontError.empty }
        return data
    }

    private static func validate(_ data: Data) throws -> (font: CGFont, name: String) {
        guard !data.isEmpty else { throw CustomFontError.empty }
        guard data.count <= byteLimit else { throw CustomFontError.tooLarge }
        guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider), font.numberOfGlyphs > 0,
              let postScriptName = font.postScriptName as String?, !postScriptName.isEmpty,
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              descriptors.contains(where: { (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == postScriptName }) else {
            throw CustomFontError.unsupported
        }
        let resolved = CTFontCreateWithGraphicsFont(font, 13, nil, nil)
        guard CTFontCopyPostScriptName(resolved) as String == postScriptName, CTFontGetGlyphCount(resolved) > 0 else { throw CustomFontError.unsupported }
        return (font, postScriptName)
    }

    private func commit(_ data: Data, displayName: String) throws -> LoadedCustomFont {
        let valid = try Self.validate(data)
        let fileName = "custom-" + UUID().uuidString + ".font"
        let record = CustomFontRecord(fileName: fileName, postScriptName: valid.name, displayName: displayName.isEmpty ? valid.name : displayName)
        let encoded = try JSONEncoder().encode(record)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        var committed = false
        defer { if !committed { try? manager.removeItem(at: destination) } }
        try data.write(to: destination, options: .atomic)
        try encoded.write(to: manifest, options: .atomic)
        committed = true
        prune(except: fileName)
        return LoadedCustomFont(record: record, graphicsFont: valid.font)
    }

    private func isOwnedAsset(_ name: String) -> Bool {
        guard name.hasPrefix("custom-"), name.hasSuffix(".font") else { return false }
        return UUID(uuidString: String(name.dropFirst("custom-".count).dropLast(".font".count))) != nil
    }

    private func prune(except kept: String?) {
        for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard file.lastPathComponent != kept,
                  isOwnedAsset(file.lastPathComponent) || ["ttf", "otf"].contains(file.pathExtension.lowercased()) else { continue }
            try? manager.removeItem(at: file)
        }
    }
}
