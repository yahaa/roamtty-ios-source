import Foundation
import RoamttyCore
import RoamttyTransport

/// The blocking libssh2 calls, made off the main thread for the screens and the model.
extension SSHConnection {
    /// Logs in.
    func connectInBackground() async throws { try await performInBackground { try self.connect() } }

    /// Lets go of the connection: closing waits on the network, so it never holds up the caller.
    func disconnectInBackground() { DispatchQueue.global(qos: .utility).async { self.disconnect() } }

    /// Runs `command` on the host. `input` goes to its standard input, followed by end of file.
    func run(_ command: String, input: Data = Data(), timeout: TimeInterval = 20, cancellation: TransferCancellation? = nil,
             onOutput: ((Data) -> Void)? = nil) async throws -> CommandResult {
        try await performInBackground {
            try self.exec(command, input: input, timeout: timeout, cancellation: cancellation, onOutput: onOutput)
        }
    }

    /// Runs a `/bin/sh` script sent on standard input, so it stays out of the command line.
    func runScript(_ script: String, timeout: TimeInterval = 20, cancellation: TransferCancellation? = nil) async throws -> CommandResult {
        try await run(RemoteCommands.stdinShell, input: Data(script.utf8), timeout: timeout, cancellation: cancellation)
    }

    // MARK: What the host has

    /// The plugins installed on the host; nil when its answer could not be read.
    func probePlugins(timeout: TimeInterval, cancellation: TransferCancellation) async throws -> Set<HostPlugin>? {
        HostPluginProbe.parse(try await runScript(HostPluginProbe.script, timeout: timeout, cancellation: cancellation).text)
    }

    /// The host's system: a Unix one by `uname` and os-release, else Windows by `ver`. `checkpoint` runs after each
    /// answer and throws when the result is no longer wanted.
    func probeSystem(timeout: TimeInterval, cancellation: TransferCancellation,
                     checkpoint: @MainActor () throws -> Void) async throws -> HostSystem {
        let unix = try await runScript(HostSystemProbe.script, timeout: timeout, cancellation: cancellation)
        try await checkpoint()
        let system = HostSystemProbe.parse(unix: unix.text)
        guard system == .UNKNOWN else { return system }
        let windows = try await run(HostSystemProbe.windowsCommand, timeout: timeout, cancellation: cancellation)
        try await checkpoint()
        return HostSystemProbe.parse(unix: nil, windows: windows.text)
    }
}
