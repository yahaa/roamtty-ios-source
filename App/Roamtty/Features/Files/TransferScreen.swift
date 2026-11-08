import SwiftUI
import UIKit

struct TransferScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ObservedObject var transfers: FileTransferModel
    @State private var share: SharedArtifact?
    @State private var export: SharedArtifact?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        NavigationStack {
            Group {
                if verticalSizeClass == .compact { landscape } else { portrait }
            }.pageBackground().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar(verticalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { clearButton }
                    ToolbarItem(placement: .confirmationAction) { doneButton }
                }
        }.modifier(ChildModalPresence()).overlay { AuthenticationOverlay() }
            .sheet(item: $share) { ShareActivity(items: [$0.url]) }.sheet(item: $export) { ExportDocuments(urls: [$0.url]) }
    }
    private var title: String { model.text("传输", "Transfers") }
    private var clearButton: some View { Button(model.text("清除已完成", "Clear finished")) { transfers.clearFinished() } }
    private var doneButton: some View { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("transfer-done") }
    private var empty: some View { EmptyMessage(icon: "arrow.up.arrow.down", title: model.text("暂无传输", "No transfers"), message: model.text("上传和下载的进度将显示在这里。", "Uploads and downloads appear here.")) }
    private var portrait: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if transfers.jobs.isEmpty { empty }
                ForEach(transfers.jobs) { job in card(job) }
            }.padding(16)
        }
    }
    /// Landscape: the flat bar, and the transfers as two columns of cards.
    private var landscape: some View {
        VStack(spacing: 0) {
            LandscapeBar(title: title, detail: transfers.jobs.isEmpty ? nil : "\(transfers.jobs.count)") { EmptyView() } trailing: {
                clearButton.buttonStyle(TextActionStyle())
                doneButton.buttonStyle(TextActionStyle())
            }
            ScrollView {
                if transfers.jobs.isEmpty { empty }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 16) {
                    ForEach(transfers.jobs) { job in card(job) }
                }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }
        }
    }
    private func card(_ job: TransferJob) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: job.uploading ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(Palette.accent)
                    Text(job.name).font(.headline).lineLimit(1)
                    Spacer()
                    if job.state == .running { Button(model.text("取消", "Cancel")) { transfers.cancel(job) } }
                }
                Text(job.remotePath).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2).textSelection(.enabled)
                if job.state == .running { if let fraction = job.fraction { ProgressView(value: fraction) } else { ProgressView() } }
                HStack {
                    Text(status(job)).accessibilityIdentifier("transfer-status-\(job.uploading ? "upload" : "download")-\(job.name)")
                    Spacer()
                    Text(formattedBytes(job.bytes))
                    if let total = job.total { Text("/ \(formattedBytes(total))") }
                    if job.state == .running { Text(job.speed) }
                }.font(.caption).foregroundStyle(job.state == .failed ? Palette.danger : Palette.secondary)
                if let error = job.message { Text(error).font(.footnote).foregroundStyle(Palette.danger).textSelection(.enabled) }
                if job.uploading && job.state == .complete {
                    if job.pendingInsertion != nil {
                        Text(model.text("路径尚未插入。请重试插入或复制远程路径。", "The path was not inserted. Retry Insert or copy the remote path.")).font(.footnote).foregroundStyle(Palette.warning)
                    }
                    HStack {
                        Button(model.text("复制路径", "Copy path")) { UIPasteboard.general.string = job.remotePath }.accessibilityIdentifier("transfer-copy-path-\(job.name)")
                        Spacer()
                        if job.pendingInsertion != nil {
                            Button(model.text("插入终端", "Insert in terminal")) {
                                transfers.insertPath(job.id, model: model)
                            }.disabled(!transfers.canInsertPath(job, model: model)).accessibilityIdentifier("transfer-insert-path-\(job.name)")
                        }
                    }.font(.subheadline)
                }
                if let url = job.localURL {
                    HStack {
                        Button(model.text("分享", "Share")) { share = SharedArtifact(url: url) }.accessibilityIdentifier("transfer-share-\(job.name)")
                        Spacer()
                        Button(model.text("存储到文件", "Save to Files")) { export = SharedArtifact(url: url) }
                    }.font(.subheadline)
                }
            }.padding(16)
        }
    }
    private func status(_ job: TransferJob) -> String {
        switch job.state {
        case .running: return job.uploading ? model.text("上传中", "Uploading") : model.text("下载中", "Downloading")
        case .complete: return model.text("已完成", "Completed")
        case .failed: return model.text("失败", "Failed")
        case .cancelled: return model.text("已取消", "Cancelled")
        }
    }
}
