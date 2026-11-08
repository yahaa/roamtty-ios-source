import Foundation

struct AuthenticationRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let labels: [String]
    let echo: [Bool]
    let fingerprint: String?
    var owner: String?
    let answer: ([String]?) -> Void
}

/// The login questions for the user: the one on screen and those waiting behind it. Taking requests off never
/// answers them; callers answer what the queue hands back.
struct PromptQueue {
    private(set) var active: AuthenticationRequest?
    private var waiting: [AuthenticationRequest] = []
    /// A transport prompt's token → the request it put up, so the prompt can take it down once it has an answer.
    private var tokens: [UUID: UUID] = [:]

    /// Shows `request` now, or after the ones already waiting.
    mutating func present(_ request: AuthenticationRequest) {
        if active == nil { active = request } else { waiting.append(request) }
    }
    mutating func present(_ request: AuthenticationRequest, token: UUID) { tokens[token] = request.id; present(request) }
    /// Takes down the request a transport prompt put up, if it is still there.
    mutating func withdraw(token: UUID) {
        guard let id = tokens.removeValue(forKey: token) else { return }
        waiting.removeAll { $0.id == id }
        if active?.id == id { showNext() }
    }
    /// Replaces the request on screen with the next one waiting.
    mutating func showNext() { active = waiting.isEmpty ? nil : waiting.removeFirst() }
    func contains(owner: String) -> Bool { active?.owner == owner || waiting.contains { $0.owner == owner } }
    /// Takes off every request of `owner`: the waiting ones first, then the one on screen.
    mutating func removeAll(owner: String) -> [AuthenticationRequest] {
        var removed = waiting.filter { $0.owner == owner }
        waiting.removeAll { $0.owner == owner }
        if let shown = active, shown.owner == owner { showNext(); removed.append(shown) }
        return removed
    }
    /// Takes off every request: the one on screen first.
    mutating func removeAll() -> [AuthenticationRequest] {
        let removed = (active.map { [$0] } ?? []) + waiting
        active = nil; waiting = []
        return removed
    }
}

/// Hands the user's answer from the main thread to the transport thread blocked on a prompt; the first answer wins.
final class PromptAnswer {
    let signal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var completed = false
    private var value: [String]?
    func finish(_ answer: [String]?) { lock.lock(); defer { lock.unlock() }; guard !completed else { return }; completed = true; value = answer; signal.signal() }
    func result() -> [String]? { lock.lock(); defer { lock.unlock() }; return value }
}
