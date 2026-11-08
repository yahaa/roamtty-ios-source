import SwiftUI
import RoamttyCore

/// The login question on top of everything: a password, a passphrase, keyboard-interactive answers or a host key to trust.
struct AuthenticationOverlay: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let request = model.authentication {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                // Centered while it fits; in landscape, where a fingerprint and its fields can be taller than the
                // screen, it scrolls. One card either way, so typing never moves the answers to a new one.
                GeometryReader { geo in
                    ScrollView {
                        AuthenticationCard(request: request).id(request.id).frame(maxWidth: 430).padding(20)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                }
            }.zIndex(100).accessibilityAddTraits(.isModal)
        }
    }
}
private struct AuthenticationCard: View {
    @EnvironmentObject var model: AppModel
    let request: AuthenticationRequest
    @State private var values: [String] = []
    /// Secret fields shown as plain text, by index.
    @State private var revealed: Set<Int> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(request.title, systemImage: request.fingerprint == nil ? "lock" : "checkmark.shield").font(.title3.weight(.semibold)).accessibilityIdentifier("auth-title")
            if !request.message.isEmpty { Text(request.message).font(.subheadline).textSelection(.enabled).accessibilityIdentifier("auth-message") }
            if let fingerprint = request.fingerprint {
                Text(fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("auth-fingerprint")
                Text(model.text("请与服务器管理员确认指纹。信任后会保存在此设备。", "Verify this fingerprint with your server administrator. Trust is saved on this device."))
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            ForEach(Array(request.labels.enumerated()), id: \.offset) { index, label in
                if index < values.count {
                    let echoed = request.echo.indices.contains(index) && request.echo[index]
                    HStack(spacing: 8) {
                        Group {
                            if echoed || revealed.contains(index) {
                                TextField(label, text: $values[index]).textInputAutocapitalization(.never).autocorrectionDisabled()
                            } else {
                                SecureField(label, text: $values[index])
                            }
                        }.accessibilityLabel(label).accessibilityIdentifier("auth-field-\(index)")
                        // A secret is hidden until asked for, and only for this prompt.
                        if !echoed {
                            let shown = revealed.contains(index)
                            Button { if shown { revealed.remove(index) } else { revealed.insert(index) } } label: {
                                Image(systemName: shown ? "eye.slash" : "eye").foregroundStyle(Palette.secondary).frame(width: 32, height: 32).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel(shown ? model.text("隐藏密码", "Hide password") : model.text("显示密码", "Show password"))
                                .accessibilityIdentifier("auth-field-\(index)-visibility")
                        }
                    }.padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6).frame(minHeight: 44)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            HStack {
                Button(model.text("取消", "Cancel")) { model.answerPrompt(nil) }.buttonStyle(RoamButtonStyle()).accessibilityIdentifier("auth-cancel")
                Button(request.fingerprint == nil ? model.text("继续", "Continue") : model.text("信任并连接", "Trust and connect")) {
                    model.answerPrompt(request.fingerprint == nil ? values : ["trust"])
                }.buttonStyle(RoamButtonStyle(primary: true)).accessibilityIdentifier("auth-confirm")
            }
        }.padding(24).background(Palette.raised, in: RoundedRectangle(cornerRadius: 28)).foregroundStyle(Palette.foreground)
            .onAppear { values = Array(repeating: "", count: request.labels.count) }
    }
}
struct FingerprintReview: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let host: Host
    /// Android removes the old record and reconnects at once, so the new fingerprint is shown for approval.
    var onRemoved: (() -> Void)?
    var body: some View {
        NavigationStack {
            Group {
                if verticalSizeClass == .compact {
                    // Landscape: the flat bar, the warning beside the button that acts on it.
                    VStack(spacing: 0) {
                        LandscapeBar(title: host.name) { cancelButton.buttonStyle(TextActionStyle()) } trailing: { EmptyView() }
                        ScrollView {
                            HStack(alignment: .center, spacing: 24) {
                                message
                                removeButton.frame(width: 260)
                            }.padding(.horizontal, 16).padding(.bottom, 16)
                        }
                    }
                } else {
                    VStack(spacing: 24) { message; removeButton; Spacer() }.padding(16)
                }
            }.pageBackground().navigationTitle(host.name).navigationBarTitleDisplayMode(.inline)
                .toolbar(verticalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .cancellationAction) { cancelButton } }
        }
    }
    private var cancelButton: some View { Button(model.text("取消", "Cancel")) { dismiss() } }
    private var message: some View {
        EmptyMessage(icon: "exclamationmark.shield", title: model.text("服务器指纹已变化", "Host key changed"),
            message: model.text("这可能是服务器重装或连接被拦截。请通过可信渠道核对新的指纹，再移除之前的记录。",
                                // swiftlint:disable:next line_length - one English sentence
                                "This can mean the server was reinstalled or the connection was intercepted. Verify the new fingerprint through a trusted channel before removing the previous record."))
    }
    private var removeButton: some View {
        Button(onRemoved == nil ? model.text("移除旧指纹", "Remove previous fingerprint") : model.text("移除旧记录并重连", "Remove and reconnect"), role: .destructive) {
            model.forgetPin(host); dismiss(); onRemoved?()
        }.buttonStyle(RoamButtonStyle()).accessibilityIdentifier("fingerprint-remove")
    }
}
