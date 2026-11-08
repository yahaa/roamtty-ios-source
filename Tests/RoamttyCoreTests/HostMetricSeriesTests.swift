import Foundation
import XCTest
@testable import RoamttyCore

final class HostMetricSeriesTests: XCTestCase {
    private func sample(cpu: Double? = nil, memory: Int64? = nil, rx: Int64? = nil, tx: Int64? = nil,
                        gpus: [HostMetrics.Gpu] = []) -> HostMetrics {
        var metrics = HostMetrics()
        metrics.cpuPercent = cpu
        if let memory { metrics.memTotalBytes = 100; metrics.memAvailableBytes = 100 - memory }
        metrics.netRxBytes = rx
        metrics.netTxBytes = tx
        metrics.gpus = gpus
        return metrics
    }

    func testAndroidFortySampleWindowAndUnavailableReadings() {
        var series = HostMetricSeries()
        for value in 0..<45 {
            series.observe(sample(cpu: Double(value), memory: Int64(value),
                                  gpus: [.init(index: 0, name: "GPU", utilPercent: Double(value * 2))]),
                           timestamp: Double(value))
        }
        XCTAssertEqual(HostMetricSeries.historyLimit, 40)
        XCTAssertEqual(series.cpuHistory, (5..<45).map(Double.init))
        XCTAssertEqual(series.memHistory, (5..<45).map(Double.init))
        XCTAssertEqual(series.gpuHistory[0], (5..<45).map { Double($0 * 2) })
        series.observe(sample(gpus: [.init(index: 0, name: "GPU")]), timestamp: 45)
        XCTAssertEqual(series.cpuHistory, (5..<45).map(Double.init))
        XCTAssertEqual(series.memHistory, (5..<45).map(Double.init))
        XCTAssertEqual(series.gpuHistory[0], (5..<45).map { Double($0 * 2) })
    }

    func testGPUIndicesKeepTheirOwnHistoryAndMissingDevicesAreRemoved() {
        var series = HostMetricSeries()
        series.observe(sample(gpus: [.init(index: 2, name: "RTX", utilPercent: 70),
                                     .init(index: 5, name: "Intel", utilPercent: 20)]), timestamp: 1)
        series.observe(sample(gpus: [.init(index: 5, name: "Intel", utilPercent: 30),
                                     .init(index: 2, name: "RTX"), .init(index: 8, name: "AMD")]), timestamp: 2)
        XCTAssertEqual(series.gpuHistory, [2: [70], 5: [20, 30], 8: []])
        series.observe(sample(gpus: [.init(index: 8, name: "AMD", utilPercent: 40)]), timestamp: 3)
        XCTAssertEqual(series.gpuHistory, [8: [40]])
        series.observe(sample(), timestamp: 4)
        XCTAssertTrue(series.gpuHistory.isEmpty)
        series.observe(sample(gpus: [.init(index: 2, name: "RTX", utilPercent: 10)]), timestamp: 5)
        XCTAssertEqual(series.gpuHistory, [2: [10]])
    }

    func testNetworkRateUsesElapsedSecondsAndNotCumulativeTotals() throws {
        var series = HostMetricSeries()
        series.observe(sample(rx: 1_000, tx: 2_000), timestamp: 50)
        XCTAssertNil(series.netRate)
        series.observe(sample(rx: 3_500, tx: 3_250), timestamp: 52.5)
        XCTAssertEqual(try XCTUnwrap(series.netRate).rxBytesPerSecond, 1_000)
        XCTAssertEqual(try XCTUnwrap(series.netRate).txBytesPerSecond, 500)
        series.observe(sample(rx: 3_500, tx: 3_250), timestamp: 55)
        XCTAssertEqual(try XCTUnwrap(series.netRate).rxBytesPerSecond, 0)
        XCTAssertEqual(try XCTUnwrap(series.netRate).txBytesPerSecond, 0)
    }

    func testInvalidCountersRetainBothRatesAndReplaceTheBaselineLikeAndroid() throws {
        var series = HostMetricSeries()
        series.observe(sample(rx: 100, tx: 200), timestamp: 1)
        series.observe(sample(rx: 500, tx: 1_000), timestamp: 3)
        let lastRate = try XCTUnwrap(series.netRate)
        XCTAssertEqual(lastRate.rxBytesPerSecond, 200)
        XCTAssertEqual(lastRate.txBytesPerSecond, 400)
        // One reset invalidates both directions; its counters become the next baseline.
        series.observe(sample(rx: 10, tx: 1_100), timestamp: 4)
        XCTAssertEqual(series.netRate, lastRate)
        series.observe(sample(rx: 110, tx: 1_200), timestamp: 5)
        XCTAssertEqual(try XCTUnwrap(series.netRate).rxBytesPerSecond, 100)
        XCTAssertEqual(try XCTUnwrap(series.netRate).txBytesPerSecond, 100)
        let resumed = series.netRate
        series.observe(sample(rx: nil, tx: 1_300), timestamp: 6)
        XCTAssertEqual(series.netRate, resumed)
        series.observe(sample(rx: 1_110, tx: 1_400), timestamp: 7)
        XCTAssertEqual(series.netRate, resumed, "A missing sample must not become a longer averaging window")
        series.observe(sample(rx: 1_160, tx: 1_450), timestamp: 8)
        XCTAssertEqual(try XCTUnwrap(series.netRate).rxBytesPerSecond, 50)
        XCTAssertEqual(try XCTUnwrap(series.netRate).txBytesPerSecond, 50)
        let valid = series.netRate
        series.observe(sample(rx: -1, tx: 1_500), timestamp: 9)
        series.observe(sample(rx: 10, tx: 1_550), timestamp: 10)
        XCTAssertEqual(series.netRate, valid, "Negative counters are unavailable, not received bytes")
    }

    func testNonIncreasingAndInvalidTimestampsDoNotProduceRates() throws {
        var series = HostMetricSeries()
        series.observe(sample(rx: 100, tx: 100), timestamp: 10)
        series.observe(sample(rx: 200, tx: 300), timestamp: 11)
        let rate = try XCTUnwrap(series.netRate)
        series.observe(sample(rx: 300, tx: 400), timestamp: 11)
        XCTAssertEqual(series.netRate, rate)
        series.observe(sample(rx: 400, tx: 500), timestamp: 9)
        XCTAssertEqual(series.netRate, rate)
        series.observe(sample(rx: 500, tx: 600), timestamp: .nan)
        series.observe(sample(rx: 600, tx: 700), timestamp: 12)
        XCTAssertEqual(series.netRate, rate)
        series.observe(sample(rx: 700, tx: 800), timestamp: .infinity)
        series.observe(sample(rx: 800, tx: 900), timestamp: 13)
        XCTAssertEqual(series.netRate, rate)
        series.observe(sample(rx: 900, tx: 1_000), timestamp: 15)
        XCTAssertEqual(try XCTUnwrap(series.netRate).rxBytesPerSecond, 50)
        XCTAssertEqual(try XCTUnwrap(series.netRate).txBytesPerSecond, 50)
    }

    func testLargeCountersKeepSmallDeltasWithoutIntegerOverflowOrDoubleRounding() throws {
        var series = HostMetricSeries()
        series.observe(sample(rx: Int64.max - 64, tx: Int64.max - 16), timestamp: 1)
        series.observe(sample(rx: Int64.max, tx: Int64.max), timestamp: 3)
        XCTAssertEqual(try XCTUnwrap(series.netRate).rxBytesPerSecond, 32)
        XCTAssertEqual(try XCTUnwrap(series.netRate).txBytesPerSecond, 8)
        let rate = series.netRate
        series.observe(sample(rx: Int64.min, tx: Int64.min), timestamp: 4)
        series.observe(sample(rx: Int64.max, tx: Int64.max), timestamp: 5)
        XCTAssertEqual(series.netRate, rate)
    }

    func testReconnectResetsOnlyNetworkBaselineAndNeedsTwoFreshSamples() throws {
        var series = HostMetricSeries()
        series.observe(sample(cpu: 10, memory: 20, rx: 100, tx: 100), timestamp: 1)
        series.observe(sample(cpu: 30, memory: 40, rx: 200, tx: 300), timestamp: 2)
        let rate = series.netRate
        series.resetNetworkBaseline()
        XCTAssertEqual(series.cpuHistory, [10, 30])
        XCTAssertEqual(series.memHistory, [20, 40])
        XCTAssertEqual(series.netRate, rate)
        series.observe(sample(rx: 10_000, tx: 20_000), timestamp: 20)
        XCTAssertEqual(series.netRate, rate)
        series.observe(sample(rx: 10_080, tx: 20_040), timestamp: 22)
        XCTAssertEqual(try XCTUnwrap(series.netRate).rxBytesPerSecond, 40)
        XCTAssertEqual(try XCTUnwrap(series.netRate).txBytesPerSecond, 20)
    }

    func testNonfiniteUtilizationDoesNotEnterChartHistory() {
        var series = HostMetricSeries()
        series.observe(sample(cpu: 10, gpus: [.init(index: 0, name: "GPU", utilPercent: 20)]), timestamp: 1)
        series.observe(sample(cpu: .nan, gpus: [.init(index: 0, name: "GPU", utilPercent: .infinity)]), timestamp: 2)
        XCTAssertEqual(series.cpuHistory, [10])
        XCTAssertEqual(series.gpuHistory[0], [20])
    }
}
