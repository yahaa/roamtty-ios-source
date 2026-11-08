import Foundation
import MetricKit
import UIKit

/// What iOS reports about the app's crashes, hangs and exits (MetricKit), plus a short event log with the app's
/// memory footprint, kept on this device so the user can share them from About. The app sends nothing itself.
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = Diagnostics()
    let folder: URL
    private let queue = DispatchQueue(label: "roamtty.diagnostics")
    private var events: URL { folder.appendingPathComponent("events.log") }
    private static let reportLimit = 20
    private static let eventLimit = 400
    /// One formatter for every line and report name: making one costs more than the line it stamps.
    private static let timestamps = ISO8601DateFormatter()

    override private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("Diagnostics", isDirectory: true)
        super.init()
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        MXMetricManager.shared.add(self)
        // Reports that arrived while the app was not running.
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in self?.log("memory-warning") }
        log("launch")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), name: "diagnostic", end: payload.timeStampEnd) }
    }
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), name: "metrics", end: payload.timeStampEnd) }
    }

    /// One line with the time, the event and the memory footprint; an exit iOS forces leaves no line of its own,
    /// so the last lines before a `launch` show what the app was doing.
    func log(_ event: String, _ detail: String = "") {
        let line = "\(Self.timestamps.string(from: Date())) \(event) footprint=\(Self.footprintMiB().map { "\($0)MiB" } ?? "?") \(detail)\n"
        queue.async { [events] in
            var text = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
            text += line
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if lines.count > Self.eventLimit { text = lines.suffix(Self.eventLimit).joined(separator: "\n") + "\n" }
            try? text.write(to: events, atomically: true, encoding: .utf8)
        }
    }

    /// Newest first, the event log last.
    var files: [URL] {
        let reports = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        return reports + (FileManager.default.fileExists(atPath: events.path) ? [events] : [])
    }

    private func save(_ json: Data, name: String, end: Date) {
        queue.async { [folder] in
            let stamp = Self.timestamps.string(from: end).replacingOccurrences(of: ":", with: "")
            try? json.write(to: folder.appendingPathComponent("\(stamp)-\(name).json"), options: .atomic)
            let reports = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in reports.dropFirst(Self.reportLimit) { try? FileManager.default.removeItem(at: old) }
        }
    }

    static func footprintMiB() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint / 1_048_576 : nil
    }
}
