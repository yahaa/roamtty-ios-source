import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let save = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var work: URL?
    private var cancellation: ShareInboxCancellation?
    private func text(_ chinese: String, _ english: String) -> String { Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english }
    private func color(_ dark: UInt32, _ light: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        let accent = color(0xEFA783, 0x9E462C)
        view.backgroundColor = color(0x252728, 0xF3F0EB)
        status.textColor = color(0xF3F0EA, 0x2B2A27)
        status.text = text("将文件保存到 Roamtty，然后在应用内选择上传主机。", "Save files to Roamtty, then choose an upload host in the app.")
        status.accessibilityIdentifier = "share-status"
        status.numberOfLines = 0; status.textAlignment = .center; status.font = .preferredFont(forTextStyle: .body)
        var saveStyle = UIButton.Configuration.filled()
        saveStyle.title = text("保存到 Roamtty", "Save to Roamtty")
        saveStyle.baseBackgroundColor = accent; saveStyle.baseForegroundColor = color(0x252728, 0xFFFDF9)
        saveStyle.cornerStyle = .large; saveStyle.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        save.configuration = saveStyle; save.accessibilityIdentifier = "share-save"
        save.titleLabel?.font = .preferredFont(forTextStyle: .headline); save.addTarget(self, action: #selector(saveFiles), for: .touchUpInside)
        let cancel = UIButton(type: .system)
        cancel.setTitle(text("取消", "Cancel"), for: .normal)
        cancel.tintColor = accent
        cancel.accessibilityIdentifier = "share-cancel"
        cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
        spinner.color = accent
        let icon = UIImageView(image: UIImage(systemName: "terminal")); icon.tintColor = accent; icon.contentMode = .scaleAspectFit
        let stack = UIStackView(arrangedSubviews: [icon, status, spinner, save, cancel]); stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([icon.heightAnchor.constraint(equalToConstant: 56),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
    @objc private func cancelShare() {
        if let cancellation, !cancellation.cancel() {
            // Publication completed before Cancel acquired the lock; preserve the saved transaction.
            extensionContext?.completeRequest(returningItems: nil); return
        }
        if let work { try? FileManager.default.removeItem(at: work) }
        work = nil
        extensionContext?.cancelRequest(withError: NSError(domain: "RoamttyShare", code: NSUserCancelledError))
    }
    @objc private func saveFiles() {
        let group = ShareInboxStore.groupContainer
        let root = group ?? FileManager.default.temporaryDirectory
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { status.text = text("没有可共享的文件。", "No supported files were shared."); return }
        guard providers.count <= 20 else { status.text = text("每次最多共享 20 个文件。", "Share up to 20 files at a time."); return }
        let transaction = root.appendingPathComponent("Inbox", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true) } catch { status.text = failureText(error); return }
        work = transaction; save.isEnabled = false; spinner.startAnimating()
        let token = ShareInboxCancellation(); cancellation = token
        saveProvider(providers: providers, index: 0, directory: transaction, useGroup: group != nil, cancellation: token)
    }
    private func saveProvider(providers: [NSItemProvider], index: Int, directory: URL, useGroup: Bool, cancellation: ShareInboxCancellation) {
        guard !cancellation.isCancelled else { return }
        guard index < providers.count else {
            do {
                if useGroup {
                    try cancellation.publish { try Data().write(to: directory.appendingPathComponent(".ready"), options: .atomic) }
                } else {
                    try ShareInboxStore.save(directory: directory, cancellation: cancellation)
                    try? FileManager.default.removeItem(at: directory)
                }
            } catch { failed(error, directory: directory, cancellation: cancellation); return }
            DispatchQueue.main.async {
                guard self.cancellation === cancellation, !cancellation.isCancelled else { return }
                self.spinner.stopAnimating(); self.work = nil; self.extensionContext?.completeRequest(returningItems: nil)
            }
            return
        }
        let provider = providers[index]
        func next(_ error: Error?) {
            guard !cancellation.isCancelled else { return }
            if let error {
                failed(error, directory: directory, cancellation: cancellation)
            } else {
                saveProvider(providers: providers, index: index + 1, directory: directory, useGroup: useGroup, cancellation: cancellation)
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error { next(error); return }
                guard let url = item as? URL else { next(NSError(domain: "RoamttyShare", code: 1, userInfo: [NSLocalizedDescriptionKey: self.text("共享文件无效", "Invalid shared file")])); return }
                do {
                    try cancellation.check()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent("\(index)-" + url.lastPathComponent))
                    try cancellation.check()
                    next(nil)
                } catch { next(error) }
            }
        } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true && UTType($0)?.conforms(to: .text) != true }) {
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let error { next(error); return }
                guard let url else { next(NSError(domain: "RoamttyShare", code: 2, userInfo: [NSLocalizedDescriptionKey: self.text("无法读取共享文件", "Unable to read shared file")])); return }
                let baseName = provider.suggestedName ?? url.lastPathComponent
                let name = baseName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
                let ext = (name as NSString).pathExtension.isEmpty ? "." + (UTType(type)?.preferredFilenameExtension ?? "bin") : ""
                do {
                    try cancellation.check()
                    try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent("\(index)-" + name + ext))
                    try cancellation.check()
                    next(nil)
                } catch { next(error) }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error { next(error); return }
                let data = (item as? Data) ?? (item as? String).map { Data($0.utf8) }
                guard let data else { next(NSError(domain: "RoamttyShare", code: 3, userInfo: [NSLocalizedDescriptionKey: self.text("无法读取共享文本", "Unable to read shared text")])); return }
                do {
                    try cancellation.check()
                    try data.write(to: directory.appendingPathComponent("Shared text \(index + 1).txt"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    try cancellation.check()
                    next(nil)
                } catch { next(error) }
            }
        } else { next(NSError(domain: "RoamttyShare", code: 4, userInfo: [NSLocalizedDescriptionKey: text("不支持此共享内容", "Unsupported shared content")])) }
    }
    private func failed(_ error: Error, directory: URL, cancellation: ShareInboxCancellation) {
        DispatchQueue.main.async {
            guard self.cancellation === cancellation, !cancellation.isCancelled else { return }
            guard cancellation.cancel() else { self.extensionContext?.completeRequest(returningItems: nil); return }
            self.spinner.stopAnimating(); self.save.isEnabled = true; self.status.text = self.failureText(error)
            try? FileManager.default.removeItem(at: directory); self.work = nil
        }
    }
    private func failureText(_ error: Error) -> String {
        let message = error.localizedDescription
        let translations = [
            "Shared inbox is unavailable": "共享收件箱不可用",
            "Unable to save shared content": "无法保存共享内容",
            "Shared content is incomplete": "共享内容不完整",
            "Share between 1 and 20 files": "每次请选择 1–20 个文件",
            "Shared files must total 64 MiB or less": "共享文件的总大小不能超过 64 MiB，且必须为普通文件",
            "Shared file changed while copying": "复制期间共享文件发生变化，请重试"
        ]
        if let chinese = translations[message] { return text(chinese, message) }
        return text("无法共享：", "Unable to share: ") + message
    }
}
