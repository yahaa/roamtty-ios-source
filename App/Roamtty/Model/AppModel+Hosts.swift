import Foundation
import RoamttyCore

/// Saved hosts: editing and deleting them, their stored secrets, and whether they can be reached.
extension AppModel {
    func host(_ id: String) -> Host? { hosts.first { $0.id == id } }
    func savedKey(_ hostID: String) -> Data? { try? vault.read(hostID: hostID, purpose: .key) }
    func loginPassword(for hostID: String) -> String? { credentialCache[hostID]?.password.flatMap { String(data: $0, encoding: .utf8) } }

    /// Navigation records user intent; background probes and automatic reconnects never change recency.
    func recordHostUse(for route: AppRoute) {
        let hostID: String
        switch route {
        case .host(let id), .desktop(let id), .files(let id, _, _): hostID = id
        case .terminal(let sessionID):
            guard let record = records.first(where: { $0.id == sessionID }) else { return }
            hostID = record.hostID
        }
        guard let store, var current = host(hostID) else { return }
        current.lastUsedAt = Date()
        do {
            try store.saveHost(current)
            hosts = try store.hosts()
        } catch { self.error = error.localizedDescription }
    }

    func saveHost(_ host: Host, password: String, key: Data?, passphrase: String) throws {
        guard let store else { throw RoamError.invalid(text("存储不可用", "Storage unavailable")) }
        var validated = try host.validated()
        let previousHost = self.host(host.id)
        // An editor may have been opened before the latest visit; keep the current usage time.
        validated.lastUsedAt = previousHost?.lastUsedAt
        let previousPassword = try vault.read(hostID: host.id, purpose: .password)
        let previousKey = try vault.read(hostID: host.id, purpose: .key)
        let nextKey = key ?? previousKey
        if validated.auth == .key && nextKey == nil { throw RoamError.invalid(text("请选择 SSH 私钥", "Choose an SSH private key")) }
        let nextPassword = validated.savePassword ? (password.isEmpty ? previousPassword : Data(password.utf8)) : nil
        var passwordChanged = false, keyChanged = false
        do {
            if nextPassword != previousPassword { try vault.save(data: nextPassword, hostID: host.id, purpose: .password); passwordChanged = true }
            if nextKey != previousKey { try vault.save(data: nextKey, hostID: host.id, purpose: .key); keyChanged = true }
            // The database row is committed only after its credentials are available.
            try store.saveHost(validated)
        } catch {
            let original = error
            do {
                if passwordChanged { try vault.save(data: previousPassword, hostID: host.id, purpose: .password) }
                if keyChanged { try vault.save(data: previousKey, hostID: host.id, purpose: .key) }
            } catch {
                throw RoamError.invalid(original.localizedDescription + text("；凭据恢复失败：", "; credential recovery failed: ") + error.localizedDescription)
            }
            throw original
        }
        let changesConnection = previousHost?.hasSameLoginIdentity(as: validated) != true
            || nextPassword != previousPassword || nextKey != previousKey || !password.isEmpty || !passphrase.isEmpty
        if changesConnection {
            invalidateHostConnections(host.id)
            credentialCache.forget(host.id)
            credentialCache.acceptSavedPassword(host.id)
            if !password.isEmpty || !passphrase.isEmpty {
                credentialCache.store(Credentials(password: password.isEmpty ? nextPassword : Data(password.utf8), privateKey: nextKey, passphrase: passphrase.isEmpty ? nil : passphrase),
                    for: host.id)
            }
        }
        hosts = try store.hosts()
        if changesConnection { restartVisibleMonitor() }
    }
    /// Records what a probe found on the host, unless the host was pointed elsewhere meanwhile.
    func updateMetadata(host previous: Host, plugins: [String]?, system: String) {
        guard var current = host(previous.id), current.address == previous.address, current.port == previous.port, current.username == previous.username else { return }
        current.plugins = plugins; current.system = system
        do { try store?.saveHost(current); if let index = hosts.firstIndex(where: { $0.id == current.id }) { hosts[index] = current } } catch { self.error = error.localizedDescription }
    }
    func deleteHost(_ host: Host) {
        do {
            invalidateHostConnections(host.id)
            for record in records where record.hostID == host.id { cancelLaunch(record.id); dropRuntime(record.id) }
            credentialCache.forget(host.id)
            try vault.remove(hostID: host.id); try store?.deleteHost(id: host.id)
            closeDesktop(host.id)
            desktopThumbnails.remove(host.id)
            metrics.removeValue(forKey: host.id); metricSeries.removeValue(forKey: host.id); monitorStates.removeValue(forKey: host.id)
            journal.removeHost(host.id); persistJournal(); hosts.removeAll { $0.id == host.id }; path = []
        } catch { self.error = error.localizedDescription }
    }
    func forgetPin(_ host: Host) {
        do {
            try store?.forgetPin(endpoint: host.endpoint)
            notice = text("已移除指纹，下次连接时重新验证", "Fingerprint removed. Verify it on the next connection.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A host whose login needs nothing typed: a saved password, a key without a passphrase, or a login still cached.
    func canLoginSilently(_ host: Host) -> Bool {
        if credentialCache[host.id] != nil { return true }
        switch host.auth {
        case .password: return !credentialCache.savedPasswordRejected(host.id) && (try? vault.read(hostID: host.id, purpose: .password)) != nil
        case .key: return savedKey(host.id).map { !PrivateKeys.needsPassphrase($0) } ?? false
        case .interactive: return false
        }
    }

    // MARK: Reachability

    func probeHosts(_ hosts: [Host]) async {
        for host in hosts where reachability[host.id] == nil { reachability[host.id] = .checking }
        await withTaskGroup(of: (String, HostReachability).self) { group in
            for host in hosts { group.addTask { (host.id, await ReachabilityProbe.measure(address: host.hostname, port: host.port)) } }
            for await (id, result) in group { if !Task.isCancelled, self.host(id) != nil { reachability[id] = result; reachabilityCheckedAt[id] = Date() } }
        }
    }
    /// A live session to the same endpoint already shows the host is up, without probing it.
    func hostConnected(_ host: Host) -> Bool {
        runtimes.values.contains { $0.host.id == host.id && $0.host.address == host.address && $0.host.port == host.port && $0.phase == .connected }
    }
    /// Shown on a session's card while it waits for its host: the last probe found sshd silent.
    func hostOffline(_ record: SessionRecord) -> Bool {
        guard let host = host(record.hostID), runtimes[record.id]?.phase.active != true, !hostConnected(host) else { return false }
        return reachability[host.id]?.isOffline == true
    }
}
