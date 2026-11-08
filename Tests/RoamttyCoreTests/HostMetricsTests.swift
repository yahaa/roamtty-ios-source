import Foundation
import XCTest
@testable import RoamttyCore

final class HostMetricsTests: XCTestCase {
    func testLinuxCPUUsesIowaitAsIdleAndParsesProcessAndMountNames() {
        let metrics = HostMetrics.parse("""
        hostname=build-box
        os=Ubuntu 24.04.1 LTS
        cpus=8
        model=Intel(R) Xeon(R)   CPU @ 2.20GHz
        cpu1=cpu  100 0 100 700 100 0 0 0 0 0
        cpu2=cpu  150 0 150 780 120 0 0 0 0 0
        load=0.52 0.40 0.31 2/431
        uptime=356400.27
        kb_MemTotal=8000000
        kb_MemAvailable=6000000
        kb_SwapTotal=2000000
        kb_SwapFree=1500000
        net=1000 2000
        disk=100000 40000 60000 /
        disk=200000 50000 150000 /home/dev data
        users=2
        proc= 12.5  3.1 node
        proc=  0.4  0.2 /usr/sbin/sshd
        proc=bad row
        """)
        XCTAssertEqual(metrics.hostname, "build-box")
        XCTAssertEqual(metrics.cpuModel, "Intel(R) Xeon(R) CPU @ 2.20GHz")
        XCTAssertEqual(metrics.cpus, 8)
        XCTAssertEqual(metrics.cpuPercent, 50)
        XCTAssertEqual(metrics.load, [0.52, 0.40, 0.31])
        XCTAssertEqual(metrics.tasks, "2/431")
        XCTAssertEqual(metrics.uptimeSeconds, 356_400)
        XCTAssertEqual(metrics.memPercent, 25)
        XCTAssertEqual(metrics.swapUsedBytes, 512_000_000)
        XCTAssertEqual(metrics.disks.map(\.mount), ["/", "/home/dev data"])
        XCTAssertEqual(metrics.disks[0].percent, 40)
        XCTAssertEqual(metrics.netRxBytes, 1000)
        XCTAssertEqual(metrics.netTxBytes, 2000)
        XCTAssertEqual(metrics.processes.map(\.name), ["node", "sshd"])
    }

    func testDarwinUsesByteCountsAndMissingValuesRemainUnknown() {
        let metrics = HostMetrics.parse("idle=91.5\nload= 1.20 1.10 1.00 \nbytes_MemTotal=17179869184\nbytes_MemAvailable=4294967296")
        XCTAssertEqual(metrics.cpuPercent, 8.5)
        XCTAssertEqual(metrics.memPercent, 75)
        XCTAssertNil(metrics.tasks)
        let missing = HostMetrics.parse("hostname=\ncpus=0\ngarbage\nidle=NaN\nbytes_MemTotal=9223372036854775809")
        XCTAssertNil(missing.hostname)
        XCTAssertNil(missing.cpus)
        XCTAssertNil(missing.cpuPercent)
        XCTAssertNil(missing.memPercent)
        XCTAssertTrue(HostMetrics.parse("gpu=9223372036854775806, malformed, 1, 1, 1, 1, 1, 1").gpus.isEmpty)
    }

    func testGPUMetricsPreserveUnavailableValuesAndConvertVendorUnits() throws {
        let metrics = HostMetrics.parse("""
        gpu=0, NVIDIA GeForce RTX 4090, 35, 1024, 24564, 45, 120.50, 450.00
        gpu=1, Tesla T4, [N/A], 512, 15360, 38, [Not Supported], [Not Supported]
        gpu=NVIDIA-SMI has failed
        gpuproc=4242, /usr/bin/python3, 900
        gpuproc=17, Xorg, [N/A]
        gpuproc=99, /opt/app/train, v2, 2048
        amdgpu=12 1073741824 8589934592 51000 35000000 - AMD Radeon RX 6600
        amdgpu=0 - - - - -
        rc6a=card0 1000.00 50000
        rc6b=card0 1000.50 50400
        igpu=card0 300 1300 Intel Alder Lake-P Integrated Graphics Controller
        igpu=card1 - -
        macgpu=7 1073741824 Apple M2 Pro
        macgpu=- -
        """)
        XCTAssertEqual(metrics.gpus.map(\.index), Array(0...7))
        XCTAssertEqual(metrics.gpus[0].memUsedBytes, 1_073_741_824)
        XCTAssertEqual(metrics.gpus[0].powerWatts, 120.5)
        XCTAssertNil(metrics.gpus[1].utilPercent)
        XCTAssertEqual(try XCTUnwrap(metrics.gpus[1].memPercent), 3.33333, accuracy: 0.001)
        XCTAssertEqual(metrics.gpus[2].temperatureC, 51)
        XCTAssertEqual(metrics.gpus[2].powerWatts, 35)
        XCTAssertEqual(metrics.gpus[2].memPercent, 12.5)
        XCTAssertNil(metrics.gpus[3].memPercent)
        XCTAssertEqual(try XCTUnwrap(metrics.gpus[4].utilPercent), 20, accuracy: 0.001)
        XCTAssertEqual(metrics.gpus[4].freqMaxMHz, 1300)
        XCTAssertNil(metrics.gpus[5].utilPercent)
        XCTAssertEqual(metrics.gpus[6].name, "Apple M2 Pro")
        XCTAssertEqual(metrics.gpus[6].memUsedBytes, 1_073_741_824)
        XCTAssertNil(metrics.gpus[6].memPercent)
        XCTAssertEqual(metrics.gpus[7].name, "GPU")
        XCTAssertEqual(metrics.gpuProcesses.map(\.name), ["train, v2", "python3", "Xorg"])
    }

    #if os(Linux) || os(macOS)
    func testBundledScriptRunsAndProducesAParseableLocalSnapshot() throws {
        let process = Foundation.Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HostMetrics.script]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let metrics = HostMetrics.parse(String(decoding: data, as: UTF8.self))
        XCTAssertFalse(try XCTUnwrap(metrics.hostname).isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.cpus), 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.memTotalBytes), 0)
        XCTAssertFalse(metrics.disks.isEmpty)
    }
    #endif
}
