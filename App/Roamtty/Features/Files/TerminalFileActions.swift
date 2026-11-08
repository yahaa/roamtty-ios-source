import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO
import RoamttyCore
import RoamttyTransport

enum TerminalFileAction: String, Identifiable {
    case upload, download
    var id: String { rawValue }
}

/// Each presentation captures its initiating terminal and directory. Pickers open only after a dock action.
struct TerminalFileActions: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let runtime: SessionRuntime
    let action: TerminalFileAction
    let onLaunchDirectory: (Bool, String) -> Void
    @State private var directory: String
    @State private var resolved = false
    @State private var connectionTarget: RemoteConnectionTarget
    @State private var started = false
    @State private var filePicker = false
    @State private var urls: [URL] = []
    @State private var transfers = false
    @State private var failure: String?

    init(runtime: SessionRuntime, action: TerminalFileAction, onLaunchDirectory: @escaping (Bool, String) -> Void) {
        self.runtime = runtime; self.action = action; _directory = State(initialValue: runtime.currentDirectory)
        self.onLaunchDirectory = onLaunchDirectory
        _connectionTarget = State(initialValue: .session(runtime))
    }

    var body: some View {
        Group {
            if action == .download && !resolved {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).pageBackground()
            } else if action == .download {
                NavigationStack {
                    FileBrowserScreen(host: runtime.host, sessionID: runtime.record.id, initialDirectory: directory, downloadSelection: true,
                        connectionTarget: connectionTarget, onLaunchDirectory: onLaunchDirectory)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("files-picker-done") } }
                }
            } else if action == .upload && !urls.isEmpty {
                UploadFilesSheet(host: runtime.host, urls: urls, initialDirectory: directory, sessionID: runtime.record.id, insertionRuntime: runtime,
                    connectionTarget: connectionTarget) { transfers = true }
            } else {
                NavigationStack {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.badge.arrow.up").font(.largeTitle).foregroundStyle(Palette.accent)
                        Text(model.text("选择要上传的文件，然后确认远程目录和文件名。", "Choose files, then confirm their remote folder and names.")).foregroundStyle(Palette.secondary)
                        if let failure { Text(failure).foregroundStyle(Palette.danger) }
                        Button(model.text("选择文件", "Choose files")) { filePicker = true }.buttonStyle(RoamButtonStyle(primary: true)).accessibilityIdentifier("terminal-file-choose")
                        Spacer()
                    }.padding(20).pageBackground().navigationTitle(model.text("上传文件", "Upload files"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { dismiss() } } }
                }
            }
        }
        .modifier(ChildModalPresence()).overlay { AuthenticationOverlay() }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { urls = try result.get() } catch { failure = error.localizedDescription }
        }
        .sheet(isPresented: $transfers, onDismiss: { dismiss() }) { TransferScreen(transfers: model.files).environmentObject(model) }
        .task {
            guard !started else { return }; started = true
            if action == .upload { filePicker = true }
            // The browser opens in the folder the terminal is in now, asked of the host.
            directory = await runtime.workingDirectory(); resolved = true
        }
    }
}

struct UploadFilesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let host: Host
    let urls: [URL]
    let sessionID: String?
    let insertionRuntime: SessionRuntime?
    let onStarted: () -> Void
    @State private var connectionTarget: RemoteConnectionTarget
    @State private var directory: String
    @State private var names: [String]
    @State private var chooseDirectory = false
    @State private var insertPath = false
    @State private var busy = false
    @State private var failure: String?
    @State private var cancellation: TransferCancellation?

    init(host: Host, urls: [URL], initialDirectory: String, sessionID: String? = nil, insertionRuntime: SessionRuntime? = nil,
         connectionTarget: RemoteConnectionTarget, onStarted: @escaping () -> Void) {
        self.host = host; self.urls = urls; self.sessionID = sessionID; self.insertionRuntime = insertionRuntime; self.onStarted = onStarted
        _connectionTarget = State(initialValue: connectionTarget)
        _directory = State(initialValue: initialDirectory); _names = State(initialValue: urls.map(\.lastPathComponent))
    }

    private var canInsert: Bool {
        guard let sessionID, let runtime = insertionRuntime, model.runtimes[sessionID] === runtime else { return false }
        guard runtime.host.id == host.id, connectionTarget.runtime === runtime else { return false }
        do { try model.validate(connectionTarget); return true } catch { return false }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(model.text("上传到", "Upload to") + " · " + host.name) {
                    TextField(model.text("远程目录", "Remote folder"), text: $directory)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("files-upload-destination").disabled(busy)
                    Button(model.text("浏览文件夹", "Browse folders"), systemImage: "folder") { chooseDirectory = true }.disabled(busy).accessibilityIdentifier("files-upload-browse")
                }
                Section(model.text("文件名（不会覆盖已有文件）", "File names (existing files are never overwritten)")) {
                    ForEach(urls.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(urls[index].lastPathComponent).font(.caption).foregroundStyle(Palette.secondary)
                            TextField(model.text("远程文件名", "Remote file name"), text: $names[index]).textInputAutocapitalization(.never)
                                .autocorrectionDisabled().disabled(busy).accessibilityIdentifier("files-upload-name-\(index)")
                        }
                    }
                }
                if canInsert { Section { Toggle(model.text("上传后将路径插入终端", "Insert paths in terminal after upload"), isOn: $insertPath).disabled(busy) } }
                if let failure { Section { Text(failure).foregroundStyle(Palette.danger).textSelection(.enabled).accessibilityIdentifier("files-upload-error") } }
                Section {
                    Button { startUpload() } label: {
                        HStack { if busy { ProgressView() }; Text(model.text("开始上传", "Upload")) }.frame(maxWidth: .infinity)
                    }.buttonStyle(RoamButtonStyle(primary: true))
                        .disabled(busy || directory.isEmpty || urls.isEmpty || !names.allSatisfy(isSafeRemoteEntryName)).accessibilityIdentifier("files-start-upload")
                }
            }.scrollContentBackground(.hidden).pageBackground().navigationTitle(model.text("上传文件", "Upload files")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { cancellation?.cancel(); dismiss() } } }
        }.modifier(ChildModalPresence()).overlay { AuthenticationOverlay() }
            .sheet(isPresented: $chooseDirectory) { UploadDirectoryPicker(connectionTarget: connectionTarget, initialDirectory: directory) { directory = $0 }.environmentObject(model) }
            .onDisappear { cancellation?.cancel() }
    }

    private func startUpload() {
        let destination = directory, selectedNames = names, token = TransferCancellation()
        cancellation?.cancel(); cancellation = token; failure = nil; busy = true
        Task {
            defer { if cancellation === token { busy = false; cancellation = nil } }
            do {
                let ssh = try await model.connection(for: connectionTarget)
                guard !token.isCancelled else { return }
                let listing = try await performInBackground { try uploadDirectory(destination, ssh: ssh, cancellation: token) }
                _ = try uploadTargets(directory: listing, names: selectedNames)
                guard !token.isCancelled, directory == destination, names == selectedNames else { return }
                try model.validate(connectionTarget)
                directory = listing.path
                for (index, url) in urls.enumerated() {
                    model.files.upload(url, directory: listing.path, host: host, model: model, insert: insertPath && canInsert,
                        targetSessionID: sessionID, name: selectedNames[index], targetRuntime: insertionRuntime, connectionTarget: connectionTarget)
                }
                onStarted()
            } catch { if !token.isCancelled { failure = error.localizedDescription } }
        }
    }
}

private struct UploadDirectoryPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let connectionTarget: RemoteConnectionTarget
    let initialDirectory: String
    let onSelect: (String) -> Void
    @State private var directory = ""
    @State private var draft = ""
    @State private var entries: [RemoteEntry] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var revision = UUID()
    @State private var cancellation: TransferCancellation?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField(model.text("远程目录", "Remote folder"), text: $draft).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { load(draft) }.accessibilityIdentifier("files-upload-folder-path")
                    Button(model.text("前往", "Go")) { load(draft) }
                }.padding(.horizontal, 16)
                HStack {
                    Button(model.text("主目录", "Home")) { load(".") }
                    Button(model.text("上一级", "Parent")) { load(parentRemotePath(directory)) }.disabled(directory.isEmpty || directory == "/")
                    Spacer(); if loading { ProgressView() }
                }.padding(.horizontal, 16)
                if let failure { Text(failure).foregroundStyle(Palette.danger).padding(.horizontal, 16) }
                List(entries.filter { $0.isDirectory && (model.settings.showHiddenFiles || !$0.name.hasPrefix(".")) }) { entry in
                    Button { load(entry.path) } label: { Label(entry.name, systemImage: "folder") }.accessibilityIdentifier("files-upload-folder-\(entry.path)")
                }.scrollContentBackground(.hidden)
                Button(model.text("选择此文件夹", "Use this folder")) {
                    onSelect(directory)
                    dismiss()
                }.buttonStyle(RoamButtonStyle(primary: true)).disabled(loading || failure != nil || directory.isEmpty || draft != directory)
                    .padding(16).accessibilityIdentifier("files-upload-use-folder")
            }.pageBackground().navigationTitle(model.text("选择文件夹", "Choose folder")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { dismiss() } } }
        }.modifier(ChildModalPresence()).overlay { AuthenticationOverlay() }
            .task { load(initialDirectory) }.onDisappear { cancellation?.cancel(); revision = UUID() }
    }

    private func load(_ path: String) {
        cancellation?.cancel(); let token = TransferCancellation(), request = UUID()
        cancellation = token; revision = request; loading = true; failure = nil
        Task {
            do {
                let ssh = try await model.connection(for: connectionTarget)
                guard !token.isCancelled else { return }
                let listing = try await performInBackground { try uploadDirectory(path, ssh: ssh, cancellation: token) }
                guard revision == request, !token.isCancelled else { return }
                try model.validate(connectionTarget)
                directory = listing.path; draft = listing.path; entries = listing.entries.sorted(by: remoteEntryPrecedes)
            } catch { if revision == request, !token.isCancelled { failure = error.localizedDescription } }
            if revision == request { loading = false }
        }
    }
}

private func uploadDirectory(_ requestedPath: String, ssh: SSHConnection, cancellation: TransferCancellation) throws -> RemoteDirectory {
    guard !cancellation.isCancelled else { throw RoamError.cancelled }
    let path: String
    if requestedPath == "~" || requestedPath == "." { path = "." } else if requestedPath.hasPrefix("~/") {
        let home = try ssh.listDirectory(".", cancellation: cancellation)
        path = joinRemotePath(directory: home.path, name: String(requestedPath.dropFirst(2)))
    } else { path = requestedPath }
    guard path == "." || isValidRemoteDirectory(path) else { throw RoamError.invalid("Enter an absolute remote folder or ~/path") }
    let result = try ssh.listDirectory(path, cancellation: cancellation)
    guard isValidRemoteDirectory(result.path) else { throw RoamError.invalid("The server did not return a valid destination") }
    return result
}

/// The provider URL lives only inside the import callback; keep our own copy for the transfer task.
struct PickedTerminalImage: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let size = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 64 * 1024 * 1024 else { throw RoamError.invalid("Choose an image smaller than 64 MiB") }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("roamtty-photo-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                let url = folder.appendingPathComponent("source." + received.file.pathExtension)
                try FileManager.default.copyItem(at: received.file, to: url)
                return PickedTerminalImage(url: url)
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        }
    }
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    func png(cancellation: TransferCancellation) throws -> URL {
        guard !cancellation.isCancelled else { throw RoamError.cancelled }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                  [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else {
                  throw RoamError.invalid("Unable to decode the selected image")
              }
        guard !cancellation.isCancelled else { throw RoamError.cancelled }
        let target = url.deletingLastPathComponent().appendingPathComponent("attachment.png")
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw RoamError.invalid("Unable to create PNG attachment") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), !cancellation.isCancelled else { throw RoamError.invalid("PNG conversion failed or was cancelled") }
        return target
    }
}
