import XCTest
@testable import RoamttyDesktopCore

/// The copy is Android's word for word (DesktopPage.needsText, DesktopConnection, AppLocale).
final class DesktopTextTests: XCTestCase {
    func testNeedsTextInBothLanguages() {
        let cases: [(String, String, String)] = [
            ("not-logged-in", "请先在这台电脑上登录桌面", "Log in to the desktop on this computer first"),
            ("screen-recording", "请在 Mac 上允许“屏幕录制”：系统设置 › 隐私与安全性 › 屏幕与系统音频录制，打开 Roamtty Desktop",
             "Allow Screen Recording on the Mac: System Settings › Privacy & Security › Screen & System Audio Recording, turn on Roamtty Desktop"),
            ("accessibility", "请在 Mac 上允许“辅助功能”：系统设置 › 隐私与安全性 › 辅助功能，打开 Roamtty Desktop",
             "Allow Accessibility on the Mac: System Settings › Privacy & Security › Accessibility, turn on Roamtty Desktop"),
            ("locked", "请在本机解锁", "Unlock it on the computer"),
            ("portal-approval", "请在电脑上点“允许”共享屏幕", "Click Allow on the computer to share the screen"),
            ("something-new", "需要在电脑上操作", "Something needs doing on the computer")
        ]
        for (need, zh, en) in cases {
            XCTAssertEqual(DesktopText.needs([need]).text(english: false), zh)
            XCTAssertEqual(DesktopText.needs([need]).text(english: true), en)
        }
        XCTAssertEqual(DesktopText.needs([]).text(english: false), "需要在电脑上操作")
    }

    func testWindowsServiceHint() {
        XCTAssertTrue(DesktopText.showsWindowsServiceHint(windowsHost: true, needs: ["not-logged-in"]))
        XCTAssertFalse(DesktopText.showsWindowsServiceHint(windowsHost: false, needs: ["not-logged-in"]))
        XCTAssertFalse(DesktopText.showsWindowsServiceHint(windowsHost: true, needs: ["locked"]))
        XCTAssertEqual(DesktopText.windowsServiceHint.text(english: false), "在这台电脑上用管理员 PowerShell 运行一次下面的命令，之后电脑重启或锁屏时也能直接连接：")
        XCTAssertEqual(DesktopText.copyCommand.text(english: false), "复制命令")
        XCTAssertEqual(DesktopText.copyCommand.text(english: true), "Copy command")
    }

    func testInstallAndFailureCopy() {
        XCTAssertEqual(DesktopText.installing(version: "0.8.2", target: "linux-x86_64").text(english: false), "安装桌面插件 0.8.2（linux-x86_64）")
        XCTAssertEqual(DesktopText.installing(version: "0.8.2", target: "linux-x86_64").text(english: true), "Installing desktop plugin 0.8.2 (linux-x86_64)")
        XCTAssertEqual(DesktopText.pluginStartFailedCode(127).text(english: false), "桌面插件启动失败（退出码 127）")
        XCTAssertEqual(DesktopText.lostOver30s.text(english: false), "连接中断超过 30 秒，桌面已断开")
        XCTAssertEqual(DesktopText.openedElsewhere.text(english: false), "已在另一台设备上打开")
        let steps = DesktopPluginInstaller.Step.allCases.map { DesktopText.step($0).text(english: false) }
        XCTAssertEqual(steps, ["主机直接下载…", "主机下载失败，改为手机下载后上传…", "上传到主机…", "校验 SHA-256…",
                               "获取 Cisco OpenH264 编码器…", "主机获取编码器失败，改为手机下载后上传…", "注册插件…", "安装完成"])
        XCTAssertEqual([.download, .checksum, .encoder, .host].map { DesktopText.installFailure($0).text(english: false) },
                       ["下载桌面插件失败", "桌面插件校验失败", "下载 OpenH264 编码器失败", "无法在主机上写入插件"])
    }
}
