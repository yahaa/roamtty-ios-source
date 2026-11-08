import Foundation
import RoamttyCore
import RoamttyTransport

/// Logins, the questions they ask the user, and the connections that a host's tools (files, plugins, metrics) share.
extension AppModel {
    // MARK: Staleness

    /// Whether the host still exists and neither it nor the attempt's owner moved on since the attempt started.
    func isCurrent(_ attempt: ConnectionAttempt) -> Bool { host(attempt.host) != nil && generations.isCurrent(attempt) }
    /// Drops everything under way for the host: its shared connection, metadata probes, monitor and logins.
    func invalidateHostConnections(_ hostID: String) {
        generations.invalidateHost(hostID)
        stopMonitor(hostID); cancelLaunch(hostID)
        connectionTokens.removeValue(forKey: hostID)
        connectionTasks.removeValue(forKey: hostID)?.cancel()
        metadataJobs.removeValue(forKey: hostID)?.cancel()
        connectingSSH.removeValue(forKey: hostID)?.disconnectInBackground()
        connections.removeValue(forKey: hostID)?.disconnectInBackground()
        for record in records where record.hostID == hostID {
            cancelLaunch(record.id)
            if let runtime = runtimes[record.id], runtime.phase.active && runtime.phase != .connected { runtime.close() }
        }
        hostPhases[hostID] = .disconnected
    }

    // MARK: Credentials

    /// The login for `host`: cached, saved, or asked for. A session kept on its original login passes the
    /// `retained` credentials and does not touch the saved ones. `asking: false` fails instead of asking.
    func credentials(for host: Host, owner: String? = nil, retained: Credentials? = nil, useSavedCredentials: Bool = true, asking: Bool = true) async throws -> Credentials {
        let attempt = generations.attempt(host: host.id, owner: owner)
        try Task.checkCancellation()
        guard foreground else { throw RoamError.cancelled }
        if useSavedCredentials, let existing = credentialCache[host.id] { return existing }
        var credentials = useSavedCredentials
            ? Credentials(password: credentialCache.savedPasswordRejected(host.id) ? nil : try vault.read(hostID: host.id, purpose: .password),
                privateKey: try vault.read(hostID: host.id, purpose: .key), passphrase: nil)
            : retained ?? Credentials()
        let originalTarget = useSavedCredentials ? "" : "\(host.username)@\(host.address):\(host.port)\n"
        func stillWanted() -> Bool { foreground && !Task.isCancelled && isCurrent(attempt) }
        if host.auth == .password && credentials.password == nil {
            guard asking else { throw RoamError.cancelled }
            let answer = await ask(title: host.name, message: originalTarget + text("密码仅用于本次连接", "Password is used for this connection"), labels: [text("密码", "Password")], echo: [false], owner: owner)
            guard let password = answer?.first else { throw RoamError.cancelled }
            guard stillWanted() else { throw RoamError.cancelled }
            credentials.password = Data(password.utf8)
        }
        if host.auth == .key && credentials.privateKey == nil {
            throw RoamError.invalid(useSavedCredentials ? text("请编辑主机并导入私钥",
                "Edit this host and import a private key") : text("原会话的私钥凭据已清除。请恢复原主机并导入它的私钥后重连。",
                "The original session's private key credentials have expired. Restore the original host and import its key before reconnecting."))
        }
        if host.auth == .key && credentials.passphrase == nil, let key = credentials.privateKey, PrivateKeys.needsPassphrase(key) {
            guard asking else { throw RoamError.cancelled }
            let answer = await ask(title: host.name,
                message: originalTarget + text("私钥已加密时请输入口令；未加密可留空。口令仅保存在内存。", "Enter the key passphrase, or leave it blank for an unencrypted key. Passphrases stay in memory only."),
                labels: [text("私钥口令", "Key passphrase")], echo: [false], owner: owner)
            guard let passphrase = answer?.first else { throw RoamError.cancelled }
            guard stillWanted() else { throw RoamError.cancelled }
            credentials.passphrase = passphrase.isEmpty ? nil : passphrase
        }
        guard stillWanted() else { throw RoamError.cancelled }
        if useSavedCredentials { credentialCache.store(credentials, for: host.id) }
        return credentials
    }

    // MARK: Questions for the user

    func answerPrompt(_ answer: [String]?) {
        guard let request = prompts.active else { return }
        request.answer(answer); prompts.showNext()
    }
    func ask(title: String, message: String, labels: [String], echo: [Bool], owner: String? = nil) async -> [String]? {
        await withCheckedContinuation { continuation in
            var request = AuthenticationRequest(title: title, message: message, labels: labels, echo: echo, fingerprint: nil) { continuation.resume(returning: $0) }
            request.owner = owner
            prompts.present(request)
        }
    }

    // MARK: Connections

    /// A connection whose host-key and keyboard-interactive questions go to the user while the attempt is current.
    func makeConnection(_ host: Host, credentials: Credentials, owner: String? = nil) throws -> SSHConnection {
        guard let store else { throw RoamError.invalid("Storage unavailable") }
        let attempt = generations.attempt(host: host.id, owner: owner)
        return SSHConnection(host: host, credentials: credentials, pinStore: store) { [weak self] prompt in
            let answer = PromptAnswer()
            let id = UUID()
            DispatchQueue.main.async {
                guard let self, self.foreground, self.isCurrent(attempt) else { answer.finish(nil); return }
                let respond: ([String]?) -> Void = { [weak self] values in
                    guard let self, self.foreground, self.isCurrent(attempt) else { answer.finish(nil); return }
                    answer.finish(values)
                }
                var request: AuthenticationRequest
                switch prompt {
                case .verifyHost(let pin):
                    request = AuthenticationRequest(title: self.text("信任这台主机？", "Trust this host?"), message: "\(pin.endpoint)\n\(pin.algorithm)",
                        labels: [], echo: [], fingerprint: pin.fingerprint, answer: respond)
                case .keyboard(let instruction, let labels, let echo):
                    request = AuthenticationRequest(title: host.name, message: instruction, labels: labels, echo: echo, fingerprint: nil, answer: respond)
                }
                request.owner = owner
                self.prompts.present(request, token: id)
            }
            if answer.signal.wait(timeout: .now() + 120) == .timedOut { answer.finish(nil) }
            DispatchQueue.main.async { self?.prompts.withdraw(token: id) }
            return answer.result()
        }
    }
    func connectionTarget(hostID: String, sessionID: String? = nil) -> RemoteConnectionTarget {
        guard let sessionID else { return .host(hostID) }
        let runtime = runtimes[sessionID].flatMap { $0.host.id == hostID ? $0 : nil }
        return .session(sessionID, SessionConnectionSnapshot(session: runtime, connection: runtime?.ssh))
    }
    /// Validates ownership without looking up a replacement host connection.
    func validate(_ target: RemoteConnectionTarget) throws {
        if case .session(let id, let snapshot) = target { _ = try resolve(snapshot, session: id) }
    }
    func connection(for target: RemoteConnectionTarget) async throws -> SSHConnection {
        try Task.checkCancellation()
        switch target {
        case .host(let id): return try await connection(for: id)
        case .session(let id, let snapshot): return try resolve(snapshot, session: id)
        }
    }
    private func resolve(_ snapshot: SessionConnectionSnapshot<SessionRuntime, SSHConnection>, session id: String) throws -> SSHConnection {
        let current = runtimes[id]
        return try snapshot.resolve(currentSession: current, currentConnection: current?.ssh,
                                    connected: current?.phase == .connected && current?.ssh?.isConnected == true)
    }
    /// The host's shared connection, opened once for everything that asks at the same time.
    func connection(for hostID: String) async throws -> SSHConnection {
        if let task = connectionTasks[hostID] { return try await task.value }
        if let ssh = connections[hostID], hostPhases[hostID] == .connected, ssh.isConnected { return ssh }
        guard let host = host(hostID) else { throw RoamError.invalid("Host no longer exists") }
        connections.removeValue(forKey: hostID)?.disconnectInBackground()
        let attempt = generations.attempt(host: hostID, owner: hostID), token = UUID()
        connectionTokens[hostID] = token
        func current() -> Bool { connectionTokens[hostID] == token && isCurrent(attempt) }
        let task = Task<SSHConnection, Error> {
            let credentials = try await self.credentials(for: host, owner: hostID)
            guard !Task.isCancelled, current() else { throw RoamError.cancelled }
            let ssh = try self.makeConnection(host, credentials: credentials, owner: hostID)
            self.connectingSSH[hostID] = ssh
            ssh.onPhase = { [weak self] phase in
                DispatchQueue.main.async {
                    guard let self, self.connectionTokens[hostID] == token, self.isCurrent(attempt) else { return }
                    self.hostPhases[hostID] = phase
                }
            }
            do {
                try await ssh.connectInBackground()
                guard !Task.isCancelled, current() else { throw RoamError.cancelled }
                self.connections[hostID] = ssh
                self.hostPhases[hostID] = .connected
                self.detectMetadata(host: host, ssh: ssh, attempt: attempt, token: token)
                return ssh
            } catch { ssh.disconnectInBackground(); throw error }
        }
        connectionTasks[hostID] = task
        defer { if connectionTokens[hostID] == token { connectionTasks.removeValue(forKey: hostID); connectingSSH.removeValue(forKey: hostID) } }
        do { return try await task.value } catch {
            if current(), (error as? RoamError) == .authentication { credentialCache.rejectLogin(hostID) }
            throw error
        }
    }
    /// Probes a newly connected host for its plugins and system, which the host's page shows.
    private func detectMetadata(host: Host, ssh: SSHConnection, attempt: ConnectionAttempt, token: UUID) {
        metadataJobs[host.id]?.cancel()
        let cancellation = TransferCancellation()
        let task = Task { [weak self] in
            await withTaskCancellationHandler(operation: {
                guard let self else { return }
                defer { if self.connectionTokens[host.id] == token { self.metadataJobs.removeValue(forKey: host.id) } }
                @MainActor func current() -> Bool { !Task.isCancelled && self.connectionTokens[host.id] == token && self.connections[host.id] === ssh && self.isCurrent(attempt) }
                do {
                    guard current() else { return }
                    let plugins = try await ssh.probePlugins(timeout: 8, cancellation: cancellation)
                    guard current() else { return }
                    if let plugins, let latest = self.host(host.id) {
                        self.updateMetadata(host: host, plugins: plugins.map(\.rawValue).sorted(), system: latest.system)
                    }
                    let system = try await ssh.probeSystem(timeout: 8, cancellation: cancellation) {
                        guard current() else { throw RoamError.cancelled }
                    }
                    if system != .UNKNOWN, let latest = self.host(host.id) { self.updateMetadata(host: host, plugins: latest.plugins, system: system.rawValue) }
                } catch { /* Metadata probes are optional; an authenticated terminal remains usable. */ }
            }, onCancel: { cancellation.cancel() })
        }
        metadataJobs[host.id] = TrackedTask(token: token, task: task, cancellation: cancellation)
    }
}
