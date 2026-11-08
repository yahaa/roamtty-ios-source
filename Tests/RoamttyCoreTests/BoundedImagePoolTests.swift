import XCTest
@testable import RoamttyCore

@MainActor final class BoundedImagePoolTests: XCTestCase {
    // Removing admission accounting would let C start while A and B still own the budget.
    func testActiveConsumersHoldBudgetUntilLastRelease() async throws {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 32, reservationBytes: 16, concurrencyLimit: 2)
        let a = ImageJob(), b = ImageJob(), c = ImageJob()
        let aDelivered = expectation(description: "Both A consumers received the shared handle")
        aDelivered.expectedFulfillmentCount = 2
        let bDelivered = expectation(description: "B delivered")
        let cDelivered = expectation(description: "C delivered")
        var first: TestImage?, duplicate: TestImage?, third: TestImage?
        let a1 = pool.request("a", load: a.load) { first = $0; aDelivered.fulfill() }
        let a2 = pool.request("a", load: a.load) { duplicate = $0; aDelivered.fulfill() }
        let b1 = pool.request("b", load: b.load) { _ in bDelivered.fulfill() }
        let c1 = pool.request("c", load: c.load) { third = $0; cDelivered.fulfill() }
        await fulfillment(of: [a.started, b.started], timeout: 2)
        XCTAssertEqual(a.starts, 1)
        XCTAssertEqual(b.starts, 1)
        XCTAssertEqual(c.starts, 0)
        let aImage = TestImage(bytes: 16), bImage = TestImage(bytes: 16)
        a.succeed(aImage); b.succeed(bImage)
        await fulfillment(of: [aDelivered, bDelivered], timeout: 2)
        XCTAssertTrue(first === duplicate)
        pool.release(a1)
        XCTAssertFalse(aImage.discarded)
        XCTAssertEqual(c.starts, 0)
        pool.release(a2)
        await fulfillment(of: [c.started], timeout: 2)
        XCTAssertTrue(aImage.discarded, "Even retained display-handle copies must be cleared before budget reuse")
        XCTAssertEqual(c.starts, 1)
        c.succeed(TestImage(bytes: 16))
        await fulfillment(of: [cDelivered], timeout: 2)
        let thirdImage = try XCTUnwrap(third)
        pool.release(b1); pool.release(c1)
        XCTAssertTrue(bImage.discarded)
        XCTAssertTrue(thirdImage.discarded)
    }

    // Releasing cancelled work's slot early breaks this when decode ignores cancellation.
    func testCancellationKeepsSlotUntilNonCooperativeWorkFinishesAndDoesNotDeliverStaleImage() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 64, reservationBytes: 16, concurrencyLimit: 2)
        let old = ImageJob(), b = ImageJob(), replacement = ImageJob()
        let newDelivered = expectation(description: "Replacement delivered")
        let bDelivered = expectation(description: "B delivered")
        var oldDelivered = false, newImage: TestImage?
        let oldToken = pool.request("same", load: old.load) { _ in oldDelivered = true }
        let bToken = pool.request("b", load: b.load) { _ in bDelivered.fulfill() }
        await fulfillment(of: [old.started, b.started], timeout: 2)
        pool.release(oldToken)
        let replacementToken = pool.request("same", load: replacement.load) { newImage = $0; newDelivered.fulfill() }
        XCTAssertEqual(replacement.starts, 0)
        let stale = TestImage(bytes: 16)
        old.succeed(stale)
        await fulfillment(of: [stale.didDiscard, replacement.started], timeout: 2)
        XCTAssertTrue(stale.discarded)
        XCTAssertFalse(oldDelivered)
        XCTAssertEqual(replacement.starts, 1)
        replacement.succeed(TestImage(bytes: 16)); b.succeed(TestImage(bytes: 16))
        await fulfillment(of: [newDelivered, bDelivered], timeout: 2)
        XCTAssertNotNil(newImage)
        pool.release(bToken); pool.release(replacementToken)
    }

    func testQueuedCancellationNeverStartsAndFailureFreesPermit() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 32, reservationBytes: 16, concurrencyLimit: 1)
        let failing = ImageJob(), cancelled = ImageJob(), next = ImageJob()
        let failureDelivered = expectation(description: "Failure delivered")
        let nextDelivered = expectation(description: "Next delivered")
        var receivedFailure = false
        _ = pool.request("failed", load: failing.load) { receivedFailure = $0 == nil; failureDelivered.fulfill() }
        let cancelToken = pool.request("cancelled", load: cancelled.load) { _ in XCTFail("Cancelled request delivered") }
        let nextToken = pool.request("next", load: next.load) { _ in nextDelivered.fulfill() }
        pool.release(cancelToken)
        await fulfillment(of: [failing.started], timeout: 2)
        failing.fail()
        await fulfillment(of: [failureDelivered, next.started], timeout: 2)
        XCTAssertTrue(receivedFailure)
        XCTAssertEqual(cancelled.starts, 0)
        XCTAssertEqual(next.starts, 1)
        next.succeed(TestImage(bytes: 4))
        await fulfillment(of: [nextDelivered], timeout: 2)
        pool.release(nextToken)
    }

    func testUsesRealCostAndRejectsResourceBeyondReservation() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 24, reservationBytes: 16, concurrencyLimit: 2)
        let a = ImageJob(), b = ImageJob()
        let aDelivered = expectation(description: "A delivered at real byte cost")
        let rejectedDelivery = expectation(description: "Oversized resource rejected")
        var rejected = false
        let aToken = pool.request("a", load: a.load) { _ in aDelivered.fulfill() }
        _ = pool.request("b", load: b.load) { rejected = $0 == nil; rejectedDelivery.fulfill() }
        await fulfillment(of: [a.started], timeout: 2)
        XCTAssertEqual(b.starts, 0)
        a.succeed(TestImage(bytes: 8))
        await fulfillment(of: [aDelivered, b.started], timeout: 2)
        XCTAssertEqual(b.starts, 1, "Actual 8-byte residency leaves room for a 16-byte reservation")
        let oversized = TestImage(bytes: 17)
        b.succeed(oversized)
        await fulfillment(of: [oversized.didDiscard, rejectedDelivery], timeout: 2)
        XCTAssertTrue(rejected)
        XCTAssertTrue(oversized.discarded)
        pool.release(aToken)
    }

    func testCompletedHitSharesHandleAndDropsLoaderCaptures() async throws {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 32, reservationBytes: 16, concurrencyLimit: 2)
        let job = ImageJob()
        let delivered = expectation(description: "First image delivered")
        var owner: LoaderOwner? = LoaderOwner()
        weak let weakOwner = owner
        var first: TestImage?, second: TestImage?
        let firstToken = pool.request("image", load: { [captured = try XCTUnwrap(owner)] in
            _ = captured
            return try await job.load()
        }) { first = $0; delivered.fulfill() }
        owner = nil
        await fulfillment(of: [job.started], timeout: 2)
        XCTAssertNotNil(weakOwner)
        job.succeed(TestImage(bytes: 4))
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertNil(weakOwner, "A completed image must not keep a loader's connection/model alive")
        let secondToken = pool.request("image", load: { XCTFail("Loaded duplicate refetched"); return TestImage(bytes: 4) }) { second = $0 }
        let image = try XCTUnwrap(first)
        XCTAssertTrue(first === second)
        pool.release(firstToken)
        XCTAssertFalse(image.discarded)
        pool.release(secondToken)
        XCTAssertTrue(image.discarded)
    }

    func testReplacementWaitsForCancelledIdenticalWorkEvenWithSpareSlot() async {
        let pool = BoundedImagePool<String, TestImage>(byteLimit: 64, reservationBytes: 16, concurrencyLimit: 2)
        let old = ImageJob(), replacement = ImageJob(), independent = ImageJob()
        let replacementDelivered = expectation(description: "Replacement delivered")
        let independentDelivered = expectation(description: "Independent image delivered")
        let oldToken = pool.request("same", load: old.load) { _ in XCTFail("Stale delivery") }
        await fulfillment(of: [old.started], timeout: 2)
        pool.release(oldToken)
        let replacementToken = pool.request("same", load: replacement.load) { _ in replacementDelivered.fulfill() }
        let independentToken = pool.request("other", load: independent.load) { _ in independentDelivered.fulfill() }
        await fulfillment(of: [independent.started], timeout: 2)
        XCTAssertEqual(replacement.starts, 0, "A fullscreen transition must not overlap identical fetch/decode work")
        XCTAssertEqual(independent.starts, 1, "An unrelated image can use the spare slot")
        let stale = TestImage(bytes: 16)
        old.succeed(stale)
        await fulfillment(of: [stale.didDiscard, replacement.started], timeout: 2)
        XCTAssertEqual(replacement.starts, 1)
        replacement.succeed(TestImage(bytes: 16)); independent.succeed(TestImage(bytes: 16))
        await fulfillment(of: [replacementDelivered, independentDelivered], timeout: 2)
        pool.release(replacementToken); pool.release(independentToken)
    }

    func testCompletedEntryDropsDeliveredCallbackCaptures() async throws {
        let pool = BoundedImagePool<String, TestImage>()
        let job = ImageJob()
        let delivered = expectation(description: "Image callback completed")
        var owner: LoaderOwner? = LoaderOwner()
        weak let weakOwner = owner
        let token = pool.request("image", load: job.load) { [captured = try XCTUnwrap(owner)] _ in _ = captured; delivered.fulfill() }
        owner = nil
        await fulfillment(of: [job.started], timeout: 2)
        XCTAssertNotNil(weakOwner)
        job.succeed(TestImage(bytes: 4))
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertNil(weakOwner, "A ready entry needs lease IDs, not a callback's authorization context")
        pool.release(token)
    }
}

@MainActor private final class TestImage: BudgetedImageResource {
    let decodedByteCount: Int
    let didDiscard = XCTestExpectation(description: "Image discarded by pool")
    var discarded = false
    init(bytes: Int) { decodedByteCount = bytes }
    func discard() { discarded = true; didDiscard.fulfill() }
}

@MainActor private final class ImageJob {
    let started = XCTestExpectation(description: "Loader entered and installed continuation")
    var starts = 0
    private var continuation: CheckedContinuation<TestImage, Error>?
    func load() async throws -> TestImage {
        starts += 1
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func succeed(_ image: TestImage, file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation else { XCTFail("Cannot complete image job before loader start or more than once", file: file, line: line); return }
        self.continuation = nil
        continuation.resume(returning: image)
    }
    func fail(file: StaticString = #filePath, line: UInt = #line) {
        guard let continuation else { XCTFail("Cannot fail image job before loader start or more than once", file: file, line: line); return }
        self.continuation = nil
        continuation.resume(throwing: NSError(domain: "TestDecode", code: 1))
    }
}

private final class LoaderOwner {}
