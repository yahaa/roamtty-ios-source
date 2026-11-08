import Foundation

public enum RemoteFileSort: String, Codable, CaseIterable, Sendable {
    case name, modified, size, type

    /// Android RemoteFileOptions: folders stay first; primary ties always use A→Z names.
    public func orders(_ lhs: RemoteEntry, before rhs: RemoteEntry, descending: Bool) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let primary: ComparisonResult
        switch self {
        case .name: primary = Self.compareNames(lhs.name, rhs.name)
        case .modified: primary = Self.compareNumbers(lhs.mtime, rhs.mtime)
        case .size: primary = Self.compareNumbers(lhs.isDirectory ? 0 : lhs.size ?? 0, rhs.isDirectory ? 0 : rhs.size ?? 0)
        case .type: primary = Self.compareNames(Self.extensionOf(lhs), Self.extensionOf(rhs))
        }
        if primary != .orderedSame { return primary == (descending ? .orderedDescending : .orderedAscending) }
        return Self.compareNames(lhs.name, rhs.name) == .orderedAscending
    }

    private static func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
        // Locale collation (and natural numeric ordering) changes the Android
        // file order. Compare folded UTF-16 values instead.
        let a = lhs.lowercased().utf16, b = rhs.lowercased().utf16
        if a.elementsEqual(b) { return .orderedSame }
        return a.lexicographicallyPrecedes(b) ? .orderedAscending : .orderedDescending
    }
    private static func compareNumbers(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
        lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
    }
    private static func extensionOf(_ entry: RemoteEntry) -> String {
        guard !entry.isDirectory, let dot = entry.name.lastIndex(of: ".") else { return "" }
        return String(entry.name[entry.name.index(after: dot)...])
    }
}

public extension AppSettings {
    mutating func chooseFileSort(_ value: RemoteFileSort) {
        fileSortDescending = value == fileSort ? !fileSortDescending : value == .modified || value == .size
        fileSort = value
    }
}
