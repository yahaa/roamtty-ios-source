import XCTest
@testable import RoamttyCore

final class RemoteFileOptionsTests: XCTestCase {
    // Literal expectations ported from Android FileBrowserModelTest, including
    // directory dates that differ from their name order.
    private let entries = [
        RemoteEntry(name: "b.txt", path: "/b.txt", isDirectory: false, size: 10, mtime: 300),
        RemoteEntry(name: "A.md", path: "/A.md", isDirectory: false, size: 500, mtime: 100),
        RemoteEntry(name: "zeta", path: "/zeta", isDirectory: true, mtime: 50),
        RemoteEntry(name: "alpha", path: "/alpha", isDirectory: true, mtime: 400),
        RemoteEntry(name: "c.kt", path: "/c.kt", isDirectory: false, size: 200, mtime: 200)
    ]

    func testAndroidSortFixturesAndDirectoriesFirstInEveryDirection() {
        for sort in RemoteFileSort.allCases {
            for descending in [false, true] {
                XCTAssertEqual(sorted(entries, sort: sort, descending: descending).map(\.isDirectory), [true, true, false, false, false])
            }
        }
        XCTAssertEqual(names(.name), ["alpha", "zeta", "A.md", "b.txt", "c.kt"])
        XCTAssertEqual(names(.name, true), ["zeta", "alpha", "c.kt", "b.txt", "A.md"])
        XCTAssertEqual(names(.modified, true), ["alpha", "zeta", "b.txt", "c.kt", "A.md"])
        XCTAssertEqual(names(.size, true), ["alpha", "zeta", "A.md", "c.kt", "b.txt"])
        XCTAssertEqual(names(.type), ["alpha", "zeta", "c.kt", "A.md", "b.txt"])
    }

    func testDescendingPrimaryTiesStillUseAscendingCaseInsensitiveNames() {
        let tied = ["z.txt", "B.TXT", "a.txt"].map { RemoteEntry(name: $0, path: "/" + $0, isDirectory: false, size: 20, mtime: 300) }
        for sort in [RemoteFileSort.size, .modified, .type] {
            XCTAssertEqual(sorted(tied, sort: sort, descending: true).map(\.name), ["a.txt", "B.TXT", "z.txt"])
        }
        let noNaturalOrdering = ["file2", "file10"].map { RemoteEntry(name: $0, path: "/" + $0, isDirectory: false) }
        XCTAssertEqual(sorted(noNaturalOrdering, sort: .name, descending: false).map(\.name), ["file10", "file2"])
    }

    func testTypeUsesLastDotIncludingDotfilesAndDirectorySizeIsZero() {
        let values = ["z.tar.gz", ".profile", "b", "A.", "c.GZ"].map { RemoteEntry(name: $0, path: "/" + $0, isDirectory: false) }
        XCTAssertEqual(sorted(values, sort: .type, descending: false).map(\.name), ["A.", "b", "c.GZ", "z.tar.gz", ".profile"])
        let folders = [RemoteEntry(name: "z", path: "/z", isDirectory: true, size: 999), RemoteEntry(name: "a", path: "/a", isDirectory: true, size: 1)]
        XCTAssertEqual(sorted(folders, sort: .size, descending: true).map(\.name), ["a", "z"])
    }

    func testSortSelectionDefaultsAndRepeatedSelectionMatchAndroid() {
        var settings = AppSettings()
        settings.chooseFileSort(.name)
        XCTAssertTrue(settings.fileSortDescending)
        settings.chooseFileSort(.size)
        XCTAssertTrue(settings.fileSortDescending)
        settings.chooseFileSort(.size)
        XCTAssertFalse(settings.fileSortDescending)
        settings.chooseFileSort(.modified)
        XCTAssertTrue(settings.fileSortDescending)
        settings.chooseFileSort(.type)
        XCTAssertFalse(settings.fileSortDescending)
    }

    private func names(_ sort: RemoteFileSort, _ descending: Bool = false) -> [String] {
        sorted(entries, sort: sort, descending: descending).map(\.name)
    }
    /// How the file list orders entries (`FileBrowserScreen.shown` sorts with `RemoteFileSort.orders`).
    private func sorted(_ entries: [RemoteEntry], sort: RemoteFileSort, descending: Bool) -> [RemoteEntry] {
        entries.sorted { sort.orders($0, before: $1, descending: descending) }
    }
}
