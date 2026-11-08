import SwiftUI
import UIKit
import RoamttyDesktopCore

/// Android DesktopPage's status card: one size and hierarchy across all connection states.
struct DesktopStatusOverlay: View {
    let host: String
    let phase: DesktopPhase
    let hasPicture: Bool
    let windowsHost: Bool
    let log: String
    let failure: DesktopText?
    let english: Bool
    let onRetry: () -> Void
    let onClose: () -> Void
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 244
    @State private var recoveryShownFor: Int64?

    private let panel = Color(uiColor: UIColor(hex: 0x1C1C1E))
    private let ink = Color(uiColor: UIColor(hex: 0xF2F2F7))
    private let dim = Color(uiColor: UIColor(hex: 0x9A9AA1))
    private let accent = Color(uiColor: UIColor(hex: 0xFF9F0A))
    private var recoverySince: Int64? {
        if case .recovering(let since) = phase { return since }
        return nil
    }
    private func text(_ value: DesktopText) -> String { value.text(english: english) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                switch phase {
                case .failed(let message):
                    card(.couldNotOpen, size: geometry.size) {
                        Text(failure.map(text) ?? message).font(font(14)).foregroundStyle(ink)
                            .accessibilityIdentifier("desktop-error")
                    } footer: {
                        HStack(spacing: 8) {
                            Button(english ? "Retry" : "重试", action: onRetry)
                                .buttonStyle(FilledButtonStyle()).frame(minHeight: 44)
                                .accessibilityIdentifier("desktop-retry")
                            Button(action: onClose) {
                                Text(english ? "Close" : "关闭").font(font(14, weight: .medium))
                                    .foregroundStyle(dim).padding(.horizontal, 12).frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("desktop-close")
                        }
                    }
                case .needsAction(let needs):
                    card(.needsTitle, size: geometry.size) {
                        Text(text(.needs(needs))).font(font(14)).foregroundStyle(ink)
                            .accessibilityIdentifier("desktop-needs")
                        if DesktopText.showsWindowsServiceHint(windowsHost: windowsHost, needs: needs) {
                            Text(text(.windowsServiceHint)).font(font(13)).foregroundStyle(dim)
                            Text(WindowsDesktop.SERVICE_INSTALL).font(font(12, monospaced: true)).foregroundStyle(ink)
                                .textSelection(.enabled).accessibilityIdentifier("desktop-service-command")
                            Button(text(.copyCommand)) { UIPasteboard.general.string = WindowsDesktop.SERVICE_INSTALL }
                                .buttonStyle(TextActionStyle()).frame(minHeight: 44)
                                .accessibilityIdentifier("desktop-service-copy")
                        }
                    } footer: { footerLine(.connectsWhenDone) }
                case .recovering(let since) where hasPicture:
                    if recoveryShownFor == since {
                        card(.connectionLost, size: geometry.size, id: "desktop-recovering") {
                            Text(text(.recovering)).font(font(14)).foregroundStyle(ink)
                        } footer: { footerLine(.pictureComesBack) }
                    }
                default:
                    if !hasPicture {
                        card(.openingDesktop, size: geometry.size) {
                            let step: DesktopPhase.Step? = {
                                if case .connecting(let step, _) = phase { return step }
                                return nil
                            }()
                            stepLine(.loggingIn, index: 0, current: step == .login, done: step != nil && step != .login)
                            stepLine(step == .install ? .installingPlugin : .startingPlugin, index: 1,
                                     current: step == .install || step == .start, done: step == .firstFrame)
                            stepLine(.waitingForPicture, index: 2, current: step == .firstFrame, done: false)
                        } footer: {
                            Text(log).font(font(11, monospaced: true)).foregroundStyle(dim)
                                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("desktop-log")
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: recoverySince) {
            recoveryShownFor = nil
            guard let since = recoverySince else { return }
            let elapsed = Int64(Date().timeIntervalSince1970 * 1000) - since
            let remaining = max(0, 2_000 - elapsed)
            do { try await Task.sleep(for: .milliseconds(remaining)) } catch { return }
            guard !Task.isCancelled else { return }
            recoveryShownFor = since
        }
    }

    private func card<Body: View, Footer: View>(_ title: DesktopText, size: CGSize, id: String = "desktop-status",
                                                @ViewBuilder body: () -> Body, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(host).font(font(12)).foregroundStyle(dim).lineLimit(1).truncationMode(.tail)
            Text(text(title)).font(font(17, weight: .semibold)).foregroundStyle(ink)
                .lineLimit(1).truncationMode(.tail).padding(.top, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12, content: body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.top, 14).frame(maxHeight: .infinity)
                .accessibilityIdentifier("desktop-status-body")
            footer().frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8).frame(minHeight: 24, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
        .frame(width: min(296, max(0, size.width - 32)), height: min(cardHeight, max(0, size.height - 32)))
        .background(panel, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }

    private func stepLine(_ label: DesktopText, index: Int, current: Bool, done: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if done {
                    AppIcon("ic_check", size: 18).foregroundStyle(Palette.success)
                } else if current {
                    DesktopStatusSpinner(color: accent, lineWidth: 2).frame(width: 16, height: 16)
                } else {
                    Circle().fill(dim).frame(width: 8, height: 8)
                }
            }.frame(width: 20, height: 20).accessibilityHidden(true)
            Text(text(label)).font(font(14)).foregroundStyle(current || done ? ink : dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text(label))
        .accessibilityValue(done ? (english ? "Completed" : "已完成") : current ? (english ? "In progress" : "进行中") : (english ? "Waiting" : "等待中"))
        .accessibilityIdentifier("desktop-step-\(index)")
    }

    private func footerLine(_ label: DesktopText) -> some View {
        HStack(spacing: 8) {
            DesktopStatusSpinner(color: accent, lineWidth: 1.5).frame(width: 12, height: 12).accessibilityHidden(true)
            Text(text(label)).font(font(12)).foregroundStyle(dim).lineLimit(1).truncationMode(.tail)
        }
    }

    private func font(_ size: CGFloat, weight: Font.Weight = .regular, monospaced: Bool = false) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .body).scaledValue(for: size), weight: weight,
                design: monospaced ? .monospaced : .default)
    }
}

private struct DesktopStatusSpinner: View {
    let color: Color
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    var body: some View {
        Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            .overlay {
                Circle().trim(from: 0, to: 0.72).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            }
            .onAppear { spinning = true }
    }
}
