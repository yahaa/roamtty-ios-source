import SwiftUI
import UniformTypeIdentifiers
import RoamttyCore
import RoamttyTransport

struct FileBrowserScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    let host: Host
    var sessionID: String?
    var initialDirectory = "."
    var downloadSelection = false
    var onLaunchDirectory: ((Bool, String) -> Void)?
    @State private var connectionTarget: RemoteConnectionTarget
    @State private var directory = "."
    @State private var entries: [RemoteEntry] = []
    /// Names in this folder that are not UTF-8; they are left out, since no path built from them would be exact.
    @State private var unreadableNames = 0
    @State private var loading = false
    @State private var failure: String?
    @State private var actionError: String?
    @State private var filter = ""
    @State private var searchDismissal = 0
    @FocusState private var searchFocused: Bool
    @State private var preview: RemoteEntry?
    @State private var renameEntry: RemoteEntry?
    @State private var newName = ""
    @State private var deleteEntry: RemoteEntry?
    @State private var importer = false
    @State private var folderImporter = false
    @State private var transfers = false
    @State private var uploadURLs: [URL] = []
    @State private var showTransfersAfterUpload = false
    @State private var sharedUploadID: UUID?
    @State private var visible = false
    @State private var revision = 0
    @State private var searchEntries: [RemoteEntry] = []
    @State private var searching = false
    @State private var searchWarning: String?
    @State private var selecting = false
    @State private var selected: [RemoteEntry] = []
    @State private var selectedOnly = false
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var mutationID: UUID?
    @State private var mutationLabel = ""
    @State private var mutationCancellation: TransferCancellation?
    @State private var mutationTask: Task<Void, Never>?
    @State private var mutationCancelling = false
    init(host: Host, sessionID: String? = nil, initialDirectory: String = ".", downloadSelection: Bool = false,
         connectionTarget: RemoteConnectionTarget, onLaunchDirectory: ((Bool, String) -> Void)? = nil) {
        self.host = host; self.sessionID = sessionID; self.initialDirectory = initialDirectory; self.downloadSelection = downloadSelection
        self.onLaunchDirectory = onLaunchDirectory
        _connectionTarget = State(initialValue: connectionTarget)
    }
    private struct SearchRequest: Equatable {
        let directory: String
        let prefix: String
        let hidden: Bool
        let revision: Int
    }
    private var searchPrefix: String { filter.lastIndex(of: "/").map { String(filter[...$0]) } ?? "" }
    private var searchRequest: SearchRequest { SearchRequest(directory: directory, prefix: searchPrefix, hidden: model.settings.showHiddenFiles, revision: revision) }
    private var targetRuntime: SessionRuntime? {
        guard let sessionID, let runtime = connectionTarget.runtime, runtime.record.id == sessionID, runtime.host.id == host.id else { return nil }
        do { try model.validate(connectionTarget) } catch { return nil }
        return runtime
    }
    /// The entries on screen: filtered, ranked and sorted, which walks every entry of a large folder.
    private var shown: [RemoteEntry] {
        let source = selectedOnly ? selected : searchPrefix.isEmpty ? entries : searchEntries
        let query = selectedOnly ? filter : remotePathSearch(directory: directory, query: filter).name
        return source.compactMap { entry -> (RemoteEntry, Int)? in
            guard selectedOnly || model.settings.showHiddenFiles || !entry.name.hasPrefix("."),
                  let rank = remoteNameMatchRank(name: selectedOnly ? entry.path : entry.name, query: query) else { return nil }
            return (entry, rank)
        }.sorted { lhs, rhs in
            if !query.isEmpty, lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return model.settings.fileSort.orders(lhs.0, before: rhs.0, descending: model.settings.fileSortDescending)
        }.map { $0.0 }
    }
    var body: some View {
        // Worked out once per update: the summary, the list and its empty state all show the same entries.
        let shown = self.shown
        let compact = verticalSizeClass == .compact
        VStack(spacing: 0) {
            if compact { landscapeBar(shown) } else { listingSummary(shown) }
            if mutationID != nil { mutationProgress }
            if let actionError {
                HStack(alignment: .top, spacing: 12) {
                    Text(actionError).font(.footnote).foregroundStyle(Palette.warning).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("files-operation-error")
                    Button {
                        self.actionError = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }.accessibilityLabel(model.text("关闭错误", "Dismiss error")).accessibilityIdentifier("files-operation-error-dismiss")
                }.padding(12).background(Palette.panel)
            }
            if let searchWarning { Text(searchWarning).font(.caption).foregroundStyle(Palette.warning).padding(.horizontal, 16).accessibilityIdentifier("files-search-warning") }
            if let failure {
                VStack(spacing: 8) {
                    Text(failure).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    Button(model.text("重试", "Retry")) { navigate(directory) }.buttonStyle(TextActionStyle())
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { entry in
                    HStack(spacing: 0) {
                        Button { if entry.isDirectory { navigate(entry.path) } else if selecting { toggleSelection(entry) } else { preview = entry } } label: {
                            if compact { landscapeRow(entry) } else {
                            HStack(spacing: 16) {
                                if selecting && !entry.isDirectory {
                                    Image(systemName: selected.contains(where: { $0.path == entry.path }) ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.accent)
                                }
                                RemoteFileIcon(name: entry.name, directory: entry.isDirectory, permissions: entry.isSymlink ? 0 : entry.permissions, link: entry.isSymlink, size: 28)
                                    .opacity(entry.name.hasPrefix(".") ? 0.6 : 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).foregroundStyle(Palette.foreground.opacity(entry.name.hasPrefix(".") ? 0.7 : 1)).font(.body).lineLimit(1).truncationMode(.middle)
                                    if selectedOnly || !searchPrefix.isEmpty { Text(parentRemotePath(entry.path)).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1) }
                                    let meta = entryMeta(entry)
                                    if !meta.isEmpty { Text(meta).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 4)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                            }
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("files-entry-\(entry.path)").accessibilityValue(selected.contains(where: { $0.path == entry.path }) ? model.text("已选择", "Selected") : "")
                        Menu { entryActions(entry) } label: { AppIcon("ic_more").foregroundStyle(Palette.secondary).frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .accessibilityLabel(model.text("文件操作：", "File actions: ") + entry.name).accessibilityIdentifier("files-row-menu-\(entry.name)")
                    }.listRowBackground(Palette.background).listRowSeparator(compact ? .visible : .hidden).listRowSeparatorTint(Palette.outline)
                        .listRowInsets(compact ? EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 0) : EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 4))
                        .contextMenu { entryActions(entry) }.swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteEntry = entry } label: { Label(model.text("删除", "Delete"), systemImage: "trash") }
                        Button {
                            model.files.download(entry, host: host, model: model, connectionTarget: connectionTarget)
                            transfers = true
                        } label: {
                            Label(model.text("下载", "Download"), systemImage: "arrow.down.circle")
                        }.tint(Palette.accent)
                        }
                }.listStyle(.plain).scrollContentBackground(.hidden).disabled(mutationID != nil).refreshable { if mutationID == nil { await load(directory) } }
                    .overlay {
                        if !loading && !searching && shown.isEmpty {
                            VStack(spacing: 12) {
                                RemoteFileIcon(name: "", directory: true, size: 56).opacity(0.5)
                                Text(entries.isEmpty ? model.text("此目录为空", "This folder is empty") : !filter.isEmpty ? model.text("没有匹配的项目",
                                    "No matching items") : model.text("没有可显示的项目", "Nothing to show"))
                                    .font(.subheadline).foregroundStyle(Palette.secondary)
                            }
                        } else if loading && entries.isEmpty {
                            VStack(spacing: 16) { ProgressView(); Text(model.text("正在读取远端目录…", "Reading the remote folder…")).font(.subheadline).foregroundStyle(Palette.secondary) }
                        }
                    }
            }
            if selecting { selectionBar }
        }.pageBackground().navigationTitle(model.text("文件", "Files")).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.background, for: .navigationBar)
            // Landscape has its own bar, with the search field in it.
            .toolbar(compact ? .hidden : .visible, for: .navigationBar)
            .modifier(FileBrowserSearchDismissal(request: searchDismissal))
            .modifier(FileBrowserSearchField(enabled: !compact, text: $filter, prompt: model.text("搜索文件或路径", "Search files or paths")))
            .modifier(FileBrowserSearchToolbarBehavior())
            .onChange(of: searchDismissal) { _ in searchFocused = false }
            .toolbar {
                ToolbarItem(placement: .principal) { pathBar.disabled(mutationID != nil) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu { optionsMenu } label: { AppIcon("ic_more", size: 24) }.accessibilityLabel(model.text("更多", "More")).accessibilityIdentifier("files-options")
                }
            }
            .task { if downloadSelection { selecting = true }; await load(initialDirectory == "~" ? "." : initialDirectory) }
            .onAppear { visible = true; receiveSharedUpload() }
            .onDisappear { visible = false; cancelMutation() }
            .onReceive(model.files.$pendingSharedUploads) { _ in
                // @Published emits before storage changes. Receive on the next main-queue turn.
                DispatchQueue.main.async { receiveSharedUpload() }
            }
            .onChange(of: model.path) { _ in receiveSharedUpload() }
            .onChange(of: model.sheet?.id) { _ in receiveSharedUpload() }
            .onChange(of: model.childModalCount) { _ in receiveSharedUpload() }
            .onChange(of: model.authentication?.id) { _ in receiveSharedUpload() }
            .task(id: searchRequest) { await search(searchRequest) }
            .fileImporter(isPresented: $importer, allowedContentTypes: folderImporter ? [.folder] : [.item], allowsMultipleSelection: true) { result in folderImporter = false; receiveImport(result) }
            .onChange(of: importer) { if !$0 { folderImporter = false } }
            .sheet(item: $preview, onDismiss: receiveSharedUpload) { entry in FilePreviewScreen(host: host, entry: entry, connectionTarget: connectionTarget).environmentObject(model) }
            .sheet(isPresented: $transfers, onDismiss: { navigate(directory); receiveSharedUpload() }) { TransferScreen(transfers: model.files).environmentObject(model) }
            .sheet(isPresented: Binding(get: { !uploadURLs.isEmpty }, set: { if !$0 { uploadURLs = [] } }), onDismiss: {
                if let sharedUploadID { model.files.finishSharedUpload(sharedUploadID); self.sharedUploadID = nil }
                if showTransfersAfterUpload { showTransfersAfterUpload = false; transfers = true } else { receiveSharedUpload() }
            }) {
                UploadFilesSheet(host: host, urls: uploadURLs, initialDirectory: directory == "." ? initialDirectory : directory,
                    sessionID: sessionID, insertionRuntime: targetRuntime, connectionTarget: connectionTarget) {
                    showTransfersAfterUpload = true
                    uploadURLs = []
                }.environmentObject(model)
            }
            .alert(model.text("重命名", "Rename"), isPresented: Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })) {
                TextField(model.text("文件名", "Name"), text: $newName).accessibilityIdentifier("files-rename-name")
                Button(model.text("保存", "Save")) { if let entry = renameEntry { rename(entry) } }.accessibilityIdentifier("files-rename-save")
                Button(model.text("取消", "Cancel"), role: .cancel) { renameEntry = nil }
            }
            .alert(model.text("新建文件夹", "New folder"), isPresented: $creatingFolder) {
                TextField(model.text("文件夹名称", "Folder name"), text: $newFolderName).accessibilityIdentifier("files-folder-name")
                Button(model.text("创建", "Create")) { createFolder() }.disabled(!isSafeRemoteEntryName(newFolderName)).accessibilityIdentifier("files-create-folder")
                Button(model.text("取消", "Cancel"), role: .cancel) { newFolderName = "" }
            }
            .alert(deleteEntry?.isDirectory == true ? model.text("删除文件夹？", "Delete folder?") : model.text("删除文件？", "Delete file?"),
                isPresented: Binding(get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }),
                presenting: deleteEntry) { entry in
                Button(model.text("取消", "Cancel"), role: .cancel) { deleteEntry = nil }
                Button(model.text("删除", "Delete"), role: .destructive) { remove(entry) }.accessibilityIdentifier("files-delete-confirm")
            } message: { entry in
                Text(entry.path + "\n\n" + (entry.isDirectory ? model.text("将永久删除远端目录及其全部内容，此操作不可撤销。",
                    "The remote folder and everything in it will be deleted permanently. This cannot be undone.") : model.text("将永久删除远端文件，此操作不可撤销。",
                    "The remote file will be deleted permanently. This cannot be undone.")))
            }
    }
    @ViewBuilder private var optionsMenu: some View {
        Button { launchHere(agent: false) } label: { Label { Text(model.text("打开终端", "Open terminal")) } icon: { Image("ic_sessions") } }.accessibilityIdentifier("files-open-terminal")
        Button { launchHere(agent: true) } label: { Label { Text("Agent") } icon: { Image("ic_agent") } }.accessibilityIdentifier("files-open-agent")
        Divider()
        Button { navigate(directory) } label: { Label { Text(model.text("刷新", "Refresh")) } icon: { Image("ic_refresh") } }.disabled(loading || mutationID != nil)
        Button {
            newFolderName = ""
            creatingFolder = true
        } label: {
            Label { Text(model.text("新建文件夹", "New folder")) } icon: { Image("ic_folder_add") }
        }.disabled(mutationID != nil).accessibilityIdentifier("files-new-folder")
        Menu {
            Button(model.text("上传文件", "Upload files")) { folderImporter = false; importer = true }
            Button(model.text("上传文件夹", "Upload folder")) { folderImporter = true; importer = true }
        } label: { Label { Text(model.text("上传", "Upload")) } icon: { Image("ic_upload") } }.accessibilityIdentifier("files-upload")
        Button {
            selecting.toggle()
            if !selecting { selectedOnly = false }
        } label: {
            Label { Text(selecting ? model.text("结束批量下载", "Finish batch download") : model.text("批量下载", "Batch download")) } icon: { Image("ic_download") }
        }.accessibilityIdentifier("files-select")
        Button { transfers = true } label: { Label { Text(model.text("传输", "Transfers")) } icon: { Image("ic_cloud_download") } }.accessibilityIdentifier("files-transfers")
        Button {
            UIPasteboard.general.string = directory
        } label: {
            Label { Text(model.text("复制当前路径", "Copy current path")) } icon: { Image("ic_copy") }
        }.accessibilityIdentifier("files-copy-current-path")
        if !downloadSelection && model.path.contains(.host(host.id)) {
            Button { model.path = [.host(host.id)] } label: { Label { Text(model.text("返回主机详情", "Back to host details")) } icon: { Image("ic_close") } }.accessibilityIdentifier("files-close")
        }
        Divider()
        Toggle(model.text("显示隐藏文件", "Show hidden files"), isOn: $model.settings.showHiddenFiles).onChange(of: model.settings.showHiddenFiles) { _ in
            model.saveSettings()
        }.accessibilityIdentifier("files-show-hidden")
    }
    private func receiveSharedUpload() {
        // Only the host-only browser selected by Root can receive this handoff. A terminal's
        // download picker or a covered browser for another host must leave the request queued.
        guard visible, !downloadSelection, sessionID == nil, initialDirectory == ".",
              model.path.last == .files(host.id), model.sheet == nil, model.authentication == nil,
              model.incomingFiles.isEmpty, model.childModalCount == 0,
              uploadURLs.isEmpty, sharedUploadID == nil, preview == nil, !transfers,
              !importer, !folderImporter, renameEntry == nil, deleteEntry == nil, !creatingFolder, mutationID == nil,
              let request = model.files.claimSharedUpload(hostID: host.id) else { return }
        sharedUploadID = request.id
        uploadURLs = request.urls
    }
    private func launchHere(agent: Bool) {
        if let onLaunchDirectory { onLaunchDirectory(agent, directory) } else { model.sheet = .launch(host, agent, directory: directory) }
    }
    /// Two lines in portrait; one in landscape, where the height is short.
    private var selectionBar: some View {
        let compact = verticalSizeClass == .compact
        let layout = compact ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 8))
        return layout {
            HStack {
                Button(model.text("全选", "Select all")) {
                    for entry in shown where !entry.isDirectory && !selected.contains(where: { $0.path == entry.path }) { selected.append(entry) }
                }.accessibilityIdentifier("files-select-all")
                Button(model.text("清空", "Clear")) { selected = [] }.disabled(selected.isEmpty)
                Spacer()
                Toggle(model.text("仅已选", "Selected only"), isOn: $selectedOnly).fixedSize().accessibilityIdentifier("files-selected-only")
            }.font(.subheadline)
            Button {
                let names = downloadNames(paths: selected.map(\.path))
                for entry in selected { model.files.download(entry, host: host, model: model, name: names[entry.path], connectionTarget: connectionTarget) }
                transfers = true
            } label: {
                Label(model.text("下载已选文件 (\(selected.count))", "Download selected (\(selected.count))"), systemImage: "arrow.down.circle")
            }.buttonStyle(RoamButtonStyle(primary: true)).frame(maxWidth: compact ? 280 : .infinity).disabled(selected.isEmpty).accessibilityIdentifier("files-download-selected")
        }.padding(.horizontal, 12).padding(.vertical, compact ? 6 : 12).background(Palette.panel)
    }
    private func toggleSelection(_ entry: RemoteEntry) {
        if selected.contains(where: { $0.path == entry.path }) { selected.removeAll { $0.path == entry.path } } else { selected.append(entry) }
    }
    /// Android `FileBrowserPathBar`: the host as the root crumb, quiet parent folders, the current folder in title weight.
    private var pathBar: some View {
        let components = directory.split(separator: "/").map(String.init)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    crumb(index: 0, current: components.isEmpty, path: "/") {
                        HStack(spacing: 6) { AppIcon("ic_os_server", size: 16).foregroundStyle(Palette.secondary); Text(host.name) }
                    }
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        AppIcon("ic_chevron_right", size: 14).foregroundStyle(Palette.adaptive(0x827A70, 0x9A9890))
                        crumb(index: index + 1, current: index == components.count - 1, path: "/" + components.prefix(index + 1).joined(separator: "/")) { Text(component) }
                    }
                }
            }.onChange(of: directory) { _ in DispatchQueue.main.async { proxy.scrollTo(components.count, anchor: .trailing) } }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(components.count, anchor: .trailing) } }
        }.frame(maxWidth: 260)
    }
    private func crumb<Label: View>(index: Int, current: Bool, path: String, @ViewBuilder label: () -> Label) -> some View {
        Button { if !current { navigate(path) } } label: {
            label().font(current ? .system(size: 16, weight: .semibold) : .subheadline)
                .foregroundStyle(current ? Palette.foreground : Palette.secondary).lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 10)
        }.buttonStyle(.plain).id(index).accessibilityAddTraits(current ? .isHeader : [])
            .accessibilityIdentifier("files-breadcrumb-" + path)
    }
    /// Android `ListingSummary`: what is shown, what is hidden, and the sort control.
    private func listingSummary(_ shown: [RemoteEntry]) -> some View {
        HStack(spacing: 8) {
            Text(summary(shown)).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1).accessibilityIdentifier("files-summary")
            if loading || searching { ProgressView().scaleEffect(0.7) }
            Spacer()
            sortMenu
        }.padding(.leading, 20).padding(.trailing, 8)
    }
    /// What is shown and what is hidden: `33 个文件夹 · 31 个文件 · 64 项未显示`.
    private func summary(_ shown: [RemoteEntry]) -> String {
        let folders = shown.filter(\.isDirectory).count, files = shown.count - folders
        let hidden = max(0, (searchPrefix.isEmpty && !selectedOnly ? entries.count : shown.count) - shown.count)
        let parts = [folders > 0 ? model.text("\(folders) 个文件夹", "\(folders) folders") : nil,
                     files > 0 ? model.text("\(files) 个文件", "\(files) files") : nil,
                     hidden > 0 ? model.text("\(hidden) 项未显示", "\(hidden) hidden") : nil,
                     unreadableNames > 0 ? model.text("\(unreadableNames) 个非 UTF-8 文件名未列出", "\(unreadableNames) non-UTF-8 names not listed") : nil].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
    private var sortMenu: some View {
        Menu {
            sortChoice(.name, chinese: "名称", english: "Name")
            sortChoice(.modified, chinese: "修改时间", english: "Modified")
            sortChoice(.size, chinese: "大小", english: "Size")
            sortChoice(.type, chinese: "类型", english: "Type")
        } label: {
            HStack(spacing: 6) {
                AppIcon("ic_sort", size: 16)
                Text(sortLabel(model.settings.fileSort) + (model.settings.fileSortDescending ? " ↓" : " ↑")).font(.system(size: 12, weight: .medium))
            }.foregroundStyle(Palette.accent).padding(.horizontal, 10).frame(minHeight: 36)
        }.accessibilityIdentifier("files-sort")
    }

    // MARK: Landscape

    /// Landscape, like the host page there: one flat bar with back, the path, the summary (cut short when it does not
    /// fit), the sort, the search field and the menu, in place of the navigation bar and the floating search.
    private func landscapeBar(_ shown: [RemoteEntry]) -> some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                if downloadSelection {
                    Text(model.text("完成", "Done")).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accent).padding(.horizontal, 10).frame(height: 44)
                } else {
                    AppIcon("ic_chevron_left", size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle())
                }
            }.buttonStyle(.plain).accessibilityLabel(downloadSelection ? model.text("完成", "Done") : model.text("返回", "Back"))
                .accessibilityIdentifier(downloadSelection ? "files-picker-done" : "files-back")
            pathBar.disabled(mutationID != nil).layoutPriority(1)
            Spacer(minLength: 4)
            if loading || searching { ProgressView().scaleEffect(0.7) }
            Text(summary(shown)).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1).accessibilityIdentifier("files-summary")
            sortMenu.fixedSize()
            HStack(spacing: 6) {
                AppIcon("ic_search", size: 16).foregroundStyle(Palette.secondary)
                TextField(model.text("搜索文件或路径", "Search files or paths"), text: $filter).font(.subheadline).focused($searchFocused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).accessibilityIdentifier("files-search")
                if !filter.isEmpty {
                    Button { filter = "" } label: { AppIcon("ic_clear", size: 16).foregroundStyle(Palette.secondary).frame(width: 28, height: 34) }.buttonStyle(.plain)
                        .accessibilityLabel(model.text("清除搜索", "Clear search"))
                }
            }.padding(.leading, 12).padding(.trailing, filter.isEmpty ? 12 : 4).frame(width: 210, height: 34)
                .background(Palette.foreground.opacity(0.08), in: Capsule())
            Menu { optionsMenu } label: { AppIcon("ic_more", size: 24).foregroundStyle(Palette.foreground).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel(model.text("更多", "More")).accessibilityIdentifier("files-options")
        }.padding(.horizontal, 6).frame(height: 48)
    }
    /// A compact table row: the name takes the width, then the size and the modified time in their own columns.
    private func landscapeRow(_ entry: RemoteEntry) -> some View {
        let hidden = entry.name.hasPrefix(".")
        return HStack(spacing: 12) {
            if selecting && !entry.isDirectory { Image(systemName: selected.contains(where: { $0.path == entry.path }) ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.accent) }
            RemoteFileIcon(name: entry.name, directory: entry.isDirectory, permissions: entry.isSymlink ? 0 : entry.permissions, link: entry.isSymlink, size: 24)
                .opacity(hidden ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).foregroundStyle(Palette.foreground.opacity(hidden ? 0.7 : 1)).font(.body).lineLimit(1).truncationMode(.middle)
                if selectedOnly || !searchPrefix.isEmpty { Text(parentRemotePath(entry.path)).font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isSymlink ? model.text("链接", "Link") : entry.isDirectory ? "" : sizeLabel(entry.size)).frame(width: 84, alignment: .trailing)
            Text(entry.mtime > 0 ? Self.mtimeFormat.string(from: Date(timeIntervalSince1970: TimeInterval(entry.mtime))) : "").frame(width: 128, alignment: .trailing)
        }.font(.footnote.monospacedDigit()).foregroundStyle(Palette.secondary).lineLimit(1).frame(minHeight: 40).contentShape(Rectangle())
    }
    private func sortLabel(_ sort: RemoteFileSort) -> String {
        switch sort {
        case .name: return model.text("名称", "Name")
        case .modified: return model.text("修改时间", "Modified")
        case .size: return model.text("大小", "Size")
        case .type: return model.text("类型", "Type")
        }
    }
    private static let mtimeFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
    /// Android `RemoteFileRow` meta: 链接 · size · yyyy-MM-dd HH:mm.
    private func entryMeta(_ entry: RemoteEntry) -> String {
        var parts: [String] = []
        if entry.isSymlink { parts.append(model.text("链接", "Link")) }
        if !entry.isDirectory && !entry.isSymlink, let size = entry.size, size >= 0 { parts.append(sizeLabel(size)) }
        if entry.mtime > 0 { parts.append(Self.mtimeFormat.string(from: Date(timeIntervalSince1970: TimeInterval(entry.mtime)))) }
        return parts.joined(separator: " · ")
    }
    private func sizeLabel(_ size: Int64?) -> String {
        guard let size, size >= 0 else { return "" }
        let value = Double(size)
        return size < 1024 ? "\(size) B" : size < 1 << 20 ? "\(size / 1024) KiB" : size < 1 << 30 ? String(format: "%.1f MiB", value / 1048576) : String(format: "%.1f GiB", value / 1073741824)
    }
    @ViewBuilder private func entryActions(_ entry: RemoteEntry) -> some View {
        Button(entry.isDirectory ? model.text("打开", "Open") : model.text("查看内容", "View")) {
            if entry.isDirectory { navigate(entry.path) } else { preview = entry }
        }.accessibilityIdentifier("files-action-open")
        if entry.isDirectory && !downloadSelection {
            Button {
                if let onLaunchDirectory { onLaunchDirectory(false, entry.path) } else { model.sheet = .launch(host, false, directory: entry.path) }
            } label: {
                Label { Text(model.text("打开终端", "Open terminal")) } icon: { Image("ic_sessions") }
            }.accessibilityIdentifier("files-action-open-terminal")
            Button {
                if let onLaunchDirectory { onLaunchDirectory(true, entry.path) } else { model.sheet = .launch(host, true, directory: entry.path) }
            } label: {
                Label { Text("Agent") } icon: { Image("ic_agent") }
            }.accessibilityIdentifier("files-action-open-agent")
        }
        // iOS also downloads folders recursively, so 下载 is offered for both.
        Button(model.text("下载", "Download")) {
            model.files.download(entry, host: host, model: model, connectionTarget: connectionTarget)
            transfers = true
        }.accessibilityIdentifier("files-action-download")
        if !entry.isDirectory { Button(model.text("选择", "Select")) { selecting = true; toggleSelection(entry) } }
        Button(model.text("复制路径", "Copy path")) { UIPasteboard.general.string = entry.path }.accessibilityIdentifier("files-action-copy-path")
        if let runtime = targetRuntime {
            Button(model.text("插入终端", "Insert in terminal")) { insertInTerminal(entry, runtime: runtime) }
        }
        Button(model.text("重命名", "Rename")) { newName = entry.name; renameEntry = entry }.accessibilityIdentifier("files-action-rename")
        Divider()
        Button(model.text("删除", "Delete"), role: .destructive) { deleteEntry = entry }.accessibilityIdentifier("files-action-delete")
    }
    /// Typed as a paste, so the shell takes the path as text; a control character in the name is refused rather than
    /// dropped, since the path left without it would name another file.
    private func insertInTerminal(_ entry: RemoteEntry, runtime: SessionRuntime) {
        guard let text = terminalPathText(entry.path) else {
            actionError = model.text("路径含控制字符，无法插入终端", "The path holds control characters, so it can't be inserted in the terminal"); return
        }
        if runtime.pasteText(text) { model.path = [.host(host.id), .terminal(runtime.record.id)] }
    }
    private func receiveImport(_ result: Result<[URL], Error>) {
        do { uploadURLs = try result.get() } catch { if (error as NSError).code != NSUserCancelledError { actionError = error.localizedDescription } }
    }
    private func navigate(_ path: String) { searchDismissal += 1; filter = ""; selectedOnly = false; Task { await load(path) } }
    private func search(_ request: SearchRequest) async {
        searchWarning = nil
        guard !request.prefix.isEmpty else { searchEntries = []; searching = false; return }
        searching = true; searchEntries = []
        do {
            try await Task.sleep(for: .milliseconds(200))
            let ssh = try await model.connection(for: connectionTarget)
            try model.validate(connectionTarget)
            // One SFTP session for every folder the search reads, instead of a new subsystem per folder.
            let sftp = try await performInBackground { try ssh.holdSFTPSession() }
            defer { DispatchQueue.global(qos: .utility).async { sftp.close() } }
            let result = try await resolveRemoteSearchDirectories(directory: request.directory, prefix: request.prefix, showHidden: request.hidden) { path in
                try model.validate(connectionTarget)
                return try await performInBackground { try sftp.listDirectory(path) }
            }
            try Task.checkCancellation()
            try model.validate(connectionTarget)
            guard searchRequest == request else { return }
            var seen = Set<String>()
            searchEntries = result.directories.flatMap(\.entries).filter { seen.insert($0.path).inserted }
            if result.limited {
                searchWarning = model.text("搜索达到目录读取上限，请缩小路径范围。", "Search reached its folder limit. Refine the path.")
            } else if result.unreadable {
                searchWarning = model.text("部分目录无法读取。", "Some folders could not be read.")
            }
        } catch is CancellationError { return } catch { guard searchRequest == request else { return }; searchWarning = error.localizedDescription }
        if searchRequest == request { searching = false }
    }
    private func load(_ path: String) async {
        revision += 1; let token = revision; loading = true; failure = nil
        do {
            let ssh = try await model.connection(for: connectionTarget)
            try Task.checkCancellation()
            let listing = try await performInBackground { try ssh.listDirectory(path) }
            guard token == revision, !Task.isCancelled else { return }
            try model.validate(connectionTarget)
            directory = listing.path; entries = listing.entries; unreadableNames = listing.unreadableNames
        } catch { if token == revision { failure = error.localizedDescription } }
        if token == revision { loading = false }
    }
    private func rename(_ entry: RemoteEntry) {
        let name = newName; renameEntry = nil
        guard isSafeRemoteEntryName(name) else { actionError = model.text("文件名不能包含路径分隔符或空名称", "Enter a file name without path separators"); return }
        let destination = joinRemotePath(directory: parentRemotePath(entry.path), name: name)
        startMutation(label: model.text("正在重命名…", "Renaming…"), removingSelection: entry.path) { ssh, token in
            try ssh.rename(entry.path, to: destination, cancellation: token)
        }
    }
    private func createFolder() {
        let name = newFolderName, parent = directory
        guard isSafeRemoteEntryName(name) else { return }
        startMutation(label: model.text("正在创建文件夹…", "Creating folder…")) { ssh, token in
            try ssh.createDirectory(joinRemotePath(directory: parent, name: name), cancellation: token)
        }
    }
    private func remove(_ entry: RemoteEntry) {
        deleteEntry = nil
        startMutation(label: model.text("正在删除…", "Deleting…"), removingSelection: entry.path) { ssh, token in
            try ssh.remove(entry.path, recursive: entry.isDirectory, cancellation: token)
        }
    }
    private func sortChoice(_ sort: RemoteFileSort, chinese: String, english: String) -> some View {
        Button { model.settings.chooseFileSort(sort); model.saveSettings() } label: {
            if model.settings.fileSort == sort { Label(model.text(chinese, english), systemImage: "checkmark") } else { Text(model.text(chinese, english)) }
        }.accessibilityIdentifier("files-sort-" + sort.rawValue)
    }
    private var mutationProgress: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(mutationCancelling ? model.text("正在取消…", "Cancelling…") : mutationLabel).font(.subheadline).accessibilityIdentifier("files-operation-status")
            Spacer()
            Button(model.text("取消", "Cancel")) { cancelMutation() }.disabled(mutationCancelling).accessibilityIdentifier("files-operation-cancel")
        }.padding(12).background(Palette.panel)
    }
    private func cancelMutation() {
        guard mutationID != nil else { return }
        mutationCancelling = true
        mutationCancellation?.cancel()
        mutationTask?.cancel()
    }
    private func startMutation(label: String, removingSelection: String? = nil,
                               operation: @escaping (SSHConnection, TransferCancellation) throws -> Void) {
        guard mutationID == nil else { return }
        let id = UUID(), token = TransferCancellation(), target = connectionTarget
        mutationID = id; mutationLabel = label; mutationCancellation = token; mutationCancelling = false; actionError = nil
        mutationTask = Task { @MainActor in
            await withTaskCancellationHandler(operation: {
                do {
                    let ssh = try await model.connection(for: target)
                    try Task.checkCancellation()
                    try model.validate(target)
                    try await performInBackground { try operation(ssh, token) }
                    try Task.checkCancellation()
                    try model.validate(target)
                    if let removingSelection { selected.removeAll { $0.path == removingSelection } }
                } catch {
                    if !Task.isCancelled, !token.isCancelled, mutationID == id { actionError = error.localizedDescription }
                }
            }, onCancel: { token.cancel() })
            guard mutationID == id else { return }
            mutationID = nil; mutationCancellation = nil; mutationTask = nil; mutationCancelling = false
            // Cancellation stops remaining work; a server operation already acknowledged
            // may have completed. Refresh the actual folder rather than pretending rollback.
            if visible { Task { await load(directory); receiveSharedUpload() } }
        }
    }
}

/// Read the search environment inside `.searchable`; clearing its text alone leaves
/// native search active and can hide both the folder tools and the picker's Done button.
private struct FileBrowserSearchDismissal: ViewModifier {
    @Environment(\.dismissSearch) private var dismissSearch
    let request: Int
    func body(content: Content) -> some View {
        content.onChange(of: request) { _ in dismissSearch() }
    }
}

/// The system search, in portrait only; landscape has a field in its bar.
private struct FileBrowserSearchField: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let prompt: String
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.searchable(text: $text, prompt: prompt) } else { content }
    }
}

private struct FileBrowserSearchToolbarBehavior: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.1, *) {
            content.searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            content
        }
    }
}
