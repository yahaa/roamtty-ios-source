import SwiftUI

/// Asks which saved host the files shared into the app go to; cancelling drops them.
struct ShareUploadHostPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let onPick: (Host) -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if verticalSizeClass == .compact {
                    LandscapeBar(title: title) { cancelButton.buttonStyle(TextActionStyle()) } trailing: { EmptyView() }
                }
                List {
                    Section(model.text("选择上传主机", "Choose an upload host")) {
                        ForEach(model.hosts) { host in
                            Button(host.name) { onPick(host) }.accessibilityIdentifier("share-host-\(host.id)")
                        }
                    }
                }
            }.navigationTitle(title)
                .toolbar(verticalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .cancellationAction) { cancelButton } }
        }
    }
    private var title: String { model.text("共享文件", "Shared files") }
    private var cancelButton: some View { Button(model.text("取消", "Cancel")) { model.incomingFiles = [] } }
}
