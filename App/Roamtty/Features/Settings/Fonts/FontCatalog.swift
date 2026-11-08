import UIKit
import Combine
import CoreText

@MainActor final class FontCatalog: ObservableObject {
    static let shared = FontCatalog()
    @Published private(set) var custom: CustomFontRecord?
    @Published private(set) var revision = 0
    private var graphicsFont: CGFont?
    private let store: CustomFontStore

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fonts", isDirectory: true)
        store = CustomFontStore(directory: directory)
    }

    func restore(selection: String) -> String {
        let loaded = (try? store.load()) ?? (try? store.migrateLegacy(selected: selection))
        custom = loaded?.record; graphicsFont = loaded?.graphicsFont; revision += 1
        return TerminalFontSelection.restored(selection, customName: custom?.postScriptName)
    }

    @discardableResult func install(_ source: URL) throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let loaded = try store.install(source)
        custom = loaded.record; graphicsFont = loaded.graphicsFont; revision += 1
        return TerminalFontSelection.custom
    }

    func clear(selection: String) throws -> String {
        let next = TerminalFontSelection.afterClearingCustom(selection, customName: custom?.postScriptName)
        try store.clear()
        custom = nil; graphicsFont = nil; revision += 1
        return next
    }

    func valueLabel(_ selection: String, english: Bool) -> String {
        if selection == TerminalFontSelection.system { return english ? "System monospace" : "系统等宽" }
        let name = selection == TerminalFontSelection.custom ? custom?.postScriptName ?? TerminalFontSelection.defaultFont : selection
        return name.replacingOccurrences(of: "-Regular", with: "")
    }

    func font(selection: String, size: Double) -> UIFont {
        let size = CGFloat(size)
        let base: UIFont
        if selection == TerminalFontSelection.system {
            base = .monospacedSystemFont(ofSize: size, weight: .regular)
        } else if selection == TerminalFontSelection.custom, let graphicsFont {
            // UIFont/CTFont are toll-free bridged. Render the chosen file's own
            // face, even when its PostScript name is already registered elsewhere.
            base = CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil) as UIFont
        } else {
            let name = selection == "IBMPlexMono-Regular" ? "IBMPlexMono" : selection == TerminalFontSelection.custom ? TerminalFontSelection.defaultFont : selection
            base = UIFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let fallbacks = ["SymbolsNFM", "NotoSansSymbols2-Regular"].map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, size) }
        // Keep the original CTFont (including its private imported data provider)
        // while adding the shared glyph cascade, instead of resolving by name.
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: fallbacks] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base as CTFont, size, nil, descriptor) as UIFont
    }
}
