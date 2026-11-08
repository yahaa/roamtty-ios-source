import Foundation
import RoamttyCore

/// SSP bookkeeping is confined to the UDP worker. Each state number identifies
/// all input events up to a count, so retransmissions cannot type input twice.
struct MoshState {
    struct Accepted {
        var output = [Data]()
        var releasedBytes = 0
        var releasedWrites = 0
        var serverShutdown = false
    }

    private struct Event {
        var encoded: Data
        let inputBytes: Int
        let writes: Int
    }

    private let start: TimeInterval
    private var events = [Event]()
    private var eventBase: UInt64 = 0
    private var totalEvents: UInt64 { eventBase + UInt64(events.count) }
    private var sentStates: [(number: UInt64, count: UInt64)] = [(0, 0)]
    private var ackedNumber: UInt64 = 0
    private var ackedCount: UInt64 = 0
    private var lastSentCount: UInt64 = 0
    private var remoteNumber: UInt64 = 0
    private var ackDue: TimeInterval?
    private var lastSend: TimeInterval = -.infinity
    private(set) var lastHeard: TimeInterval = 0
    private(set) var heardAny = false
    private var unappliedSince: TimeInterval?
    private var inputPendingSince: TimeInterval?
    private var probeSince: TimeInterval?
    private var savedTimestamp: UInt16?
    private var savedTimestampAt: TimeInterval = 0
    private var latestPacketSequence: UInt64?
    private var srtt: TimeInterval = 1
    private var rttvar: TimeInterval = 0.5
    var pendingEventCount: Int { events.count }
    private var rto: TimeInterval { min(1, max(0.05, srtt + 4 * rttvar)) }

    init(start: TimeInterval) { self.start = start }

    mutating func enqueue(_ event: Mosh.UserEvent, at now: TimeInterval) {
        let bytes: Int, writes: Int
        switch event {
        case .keys(let data): bytes = data.count; writes = 1
        case .resize: bytes = 0; writes = 0
        }
        events.append(Event(encoded: event.encode(), inputBytes: bytes, writes: writes))
        if inputPendingSince == nil { inputPendingSince = now }
    }

    func nextSendAt(_ now: TimeInterval) -> TimeInterval {
        if totalEvents > lastSentCount { return now }
        if let ackDue { return ackDue }
        return lastSend + (totalEvents > ackedCount ? rto : 3)
    }

    mutating func instruction(at now: TimeInterval, shutdown: Bool = false) throws -> Mosh.Instruction {
        guard let latest = sentStates.last, shutdown || latest.number < UInt64.max - 1 else {
            throw RoamError.transport("Mosh state limit reached")
        }
        let number = shutdown ? Mosh.shutdownNumber : latest.number + 1
        let diff = Mosh.userMessage(events.dropFirst(Int(ackedCount - eventBase)).map(\.encoded))
        let instruction = Mosh.Instruction(oldNum: ackedNumber, newNum: number,
                                           ackNum: remoteNumber, throwawayNum: ackedNumber, diff: diff)
        if !shutdown {
            sentStates.append((number, totalEvents))
            // Retain the acknowledged base while bounding redundant resend states.
            if sentStates.count > 256 { sentStates.remove(at: 1) }
        }
        lastSentCount = totalEvents
        lastSend = now
        ackDue = nil
        return instruction
    }

    mutating func heard(at now: TimeInterval, timestamp: UInt16, reply: UInt16, sequence: UInt64) {
        // Out-of-order payloads may still complete fragments, but replayed
        // datagrams cannot refresh connection liveness or RTT timestamps.
        if let latestPacketSequence, sequence <= latestPacketSequence { return }
        latestPacketSequence = sequence
        if timestamp != .max {
            savedTimestamp = timestamp
            savedTimestampAt = now
        }
        if reply != .max {
            let rtt = TimeInterval(Self.timestamp(now) &- reply) / 1000
            if rtt < 5 {
                if !heardAny { srtt = rtt; rttvar = rtt / 2 } else { rttvar = 0.75 * rttvar + 0.25 * abs(srtt - rtt); srtt = 0.875 * srtt + 0.125 * rtt }
            }
        }
        if unappliedSince == nil { unappliedSince = now }
        lastHeard = now
        probeSince = nil
        heardAny = true
    }

    mutating func timestampReply(at now: TimeInterval) -> UInt16 {
        guard let savedTimestamp, now - savedTimestampAt <= 1 else { return .max }
        self.savedTimestamp = nil
        return savedTimestamp &+ UInt16(truncatingIfNeeded: Int64((now - savedTimestampAt) * 1000))
    }

    static func timestamp(_ now: TimeInterval) -> UInt16 {
        let value = UInt16(truncatingIfNeeded: UInt64(max(0, now * 1000)))
        return value == .max ? 0 : value // 0xffff means "no timestamp" on the wire.
    }

    mutating func requestProbe(at now: TimeInterval) {
        if heardAny, probeSince == nil { probeSince = now }
    }

    /// The worker did not run since well before `now`: iOS suspended the app. Input and a probe still waiting get
    /// a whole stall limit from here, as the network could not answer while nothing was sent or read.
    mutating func thawed(at now: TimeInterval) {
        if inputPendingSince != nil { inputPendingSince = now }
        if probeSince != nil { probeSince = now }
    }

    /// The earliest moment `timeoutReason` can give up while nothing is heard; the worker waits no longer than this.
    func nextTimeoutAt(firstContact: TimeInterval, silence: TimeInterval, stall: TimeInterval?) -> TimeInterval {
        guard heardAny else { return start + firstContact }
        var at = lastHeard + silence
        if let stall, let waiting = [probeSince, inputPendingSince].compactMap({ $0 }).min() { at = min(at, max(waiting, lastHeard) + stall) }
        return at
    }

    /// Why the session should give up now, for the diagnostics log; nil while it may keep waiting.
    func timeoutReason(at now: TimeInterval, firstContact: TimeInterval, silence: TimeInterval, stall: TimeInterval?) -> String? {
        func seconds(_ value: TimeInterval) -> String { String(format: "%.1fs", value) }
        if !heardAny, now - start > firstContact { return "no first contact in " + seconds(now - start) }
        if heardAny, now - lastHeard > silence { return "silent for " + seconds(now - lastHeard) }
        guard heardAny, let stall else { return nil }
        if let waiting = [probeSince, inputPendingSince].compactMap({ $0 }).min(),
           now - waiting > stall, now - lastHeard > stall {
            return "stalled: probe=\(probeSince.map { seconds(now - $0) } ?? "-") input=\(inputPendingSince.map { seconds(now - $0) } ?? "-") heard=" + seconds(now - lastHeard)
        }
        // Start the desync timer when a packet first fails to apply, not at the
        // last accepted state; otherwise a sleeping phone immediately fails.
        if let unappliedSince, lastHeard - unappliedSince > 30 { return "unapplied for " + seconds(lastHeard - unappliedSince) }
        return nil
    }

    mutating func receive(_ instruction: Mosh.Instruction, at now: TimeInterval) throws -> Accepted {
        guard instruction.protocolVersion == Mosh.protocolVersion else {
            throw RoamError.transport("Mosh protocol version mismatch")
        }
        var result = acknowledge(instruction.ackNum)
        if instruction.newNum == remoteNumber { unappliedSince = nil }
        guard instruction.newNum != remoteNumber, instruction.oldNum == remoteNumber else {
            scheduleAck(at: now)
            return result
        }
        // Parse the whole diff before advancing state or emitting terminal data.
        for event in try Mosh.hostMessage(instruction.diff) {
            if case .bytes(let bytes) = event, !bytes.isEmpty { result.output.append(bytes) }
        }
        remoteNumber = instruction.newNum
        unappliedSince = nil
        result.serverShutdown = remoteNumber == Mosh.shutdownNumber
        scheduleAck(at: now)
        return result
    }

    mutating func clear() {
        for index in events.indices { events[index].encoded.resetBytes(in: 0..<events[index].encoded.count) }
        events.removeAll()
    }

    private mutating func scheduleAck(at now: TimeInterval) {
        if ackDue == nil { ackDue = now + 0.02 }
    }

    private mutating func acknowledge(_ number: UInt64) -> Accepted {
        var result = Accepted()
        guard number != Mosh.shutdownNumber, number > ackedNumber,
              let index = sentStates.firstIndex(where: { $0.number == number }) else { return result }
        let count = sentStates[index].count
        sentStates.removeFirst(index)
        ackedNumber = number
        ackedCount = count
        let drop = Int(count - eventBase)
        for index in 0..<drop {
            result.releasedBytes += events[index].inputBytes
            result.releasedWrites += events[index].writes
            events[index].encoded.resetBytes(in: 0..<events[index].encoded.count)
        }
        events.removeFirst(drop)
        eventBase = count
        if ackedCount >= totalEvents { inputPendingSince = nil }
        return result
    }
}
