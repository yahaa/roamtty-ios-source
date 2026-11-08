import XCTest
import CNative

final class SSHHeapTests: XCTestCase {
    func testSessionAllocatesFromItsHeapAndDestroyReleasesWhatLibssh2LeftBehind() throws {
        let owner = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1), other = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { owner.deallocate(); other.deallocate() }
        let heap = try XCTUnwrap(roam_ssh_heap_create(owner))
        let session = try XCTUnwrap(roam_ssh_session_init(heap))
        XCTAssertGreaterThan(roam_ssh_heap_live(heap, nil), 0, "The session itself comes from the heap")
        let abstract = try XCTUnwrap(libssh2_session_abstract(session))
        XCTAssertEqual(roam_ssh_user(abstract), owner)
        // What libssh2 frees itself, as keyboard-interactive answers.
        let answer = try XCTUnwrap(roam_ssh_alloc(abstract, 48))
        XCTAssertEqual(Int(bitPattern: answer) % 16, 0)
        XCTAssertEqual(roam_ssh_set_user(session, other), owner)
        XCTAssertEqual(roam_ssh_user(abstract), other)
        XCTAssertEqual(libssh2_session_free(session), 0)
        // Only the block nobody freed is left: libssh2's own memory went back through the heap.
        var bytes = 0
        XCTAssertEqual(roam_ssh_heap_live(heap, &bytes), 1)
        XCTAssertEqual(bytes, 48)
        XCTAssertEqual(roam_ssh_heap_destroy(heap, &bytes), 1)
        XCTAssertEqual(bytes, 48)
    }

    func testDestroyWithNothingLeftReportsNothing() throws {
        let heap = try XCTUnwrap(roam_ssh_heap_create(nil))
        let session = try XCTUnwrap(roam_ssh_session_init(heap))
        XCTAssertEqual(libssh2_session_free(session), 0)
        var bytes = 1
        XCTAssertEqual(roam_ssh_heap_destroy(heap, &bytes), 0)
        XCTAssertEqual(bytes, 0)
    }
}
