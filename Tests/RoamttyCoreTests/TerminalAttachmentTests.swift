import XCTest
@testable import RoamttyCore

final class TerminalAttachmentTests: XCTestCase {
    func testUploadBatchRejectsCollisionsAndTraversalBeforeAnyTransferStarts() throws {
        let directory = RemoteDirectory(path: "/tmp/chosen", entries: [RemoteEntry(name: "existing.txt", path: "/tmp/chosen/existing.txt", isDirectory: false)])
        XCTAssertEqual(try uploadTargets(directory: directory, names: ["a b.txt", "second.txt"]), ["/tmp/chosen/a b.txt", "/tmp/chosen/second.txt"])
        XCTAssertThrowsError(try uploadTargets(directory: directory, names: ["new.txt", "existing.txt"]))
        XCTAssertThrowsError(try uploadTargets(directory: directory, names: ["same.txt", "same.txt"]))
        XCTAssertThrowsError(try uploadTargets(directory: directory, names: ["../escape"]))
        XCTAssertThrowsError(try uploadTargets(directory: directory, names: ["bad\nname"]))
        XCTAssertThrowsError(try uploadTargets(directory: RemoteDirectory(path: ".", entries: []), names: ["file"]))
    }
    func testImageAttachmentsUseIndependentPNGNamesAndNeverSubmitInput() throws {
        let id = try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let path = TerminalAttachment.remotePNGPath(id: id)
        XCTAssertEqual(path, "/tmp/roamtty-img-01234567-89ab-cdef-0123-456789abcdef.png")
        XCTAssertNotEqual(TerminalAttachment.remotePNGPath(), TerminalAttachment.remotePNGPath())
        XCTAssertEqual(try TerminalAttachment.imageInput(path, bracketed: false), " /tmp/roamtty-img-01234567-89ab-cdef-0123-456789abcdef.png ")
        XCTAssertEqual(try TerminalAttachment.imageInput(path, bracketed: true), "\u{1b}[200~ /tmp/roamtty-img-01234567-89ab-cdef-0123-456789abcdef.png \u{1b}[201~")
        XCTAssertThrowsError(try TerminalAttachment.imageInput("/tmp/image.png\nwhoami", bracketed: false))
        XCTAssertThrowsError(try TerminalAttachment.imageInput("/tmp/not-an-attachment.png", bracketed: false))
    }
}
