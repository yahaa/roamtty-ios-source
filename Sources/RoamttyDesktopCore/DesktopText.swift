/// The desktop's user-facing text in both app languages, word for word Android's `tr()` strings and
/// their English (AppLocale.kt, roamtty #218). Messages the connection produces carry a `DesktopText`
/// so the page shows them in whatever language is current.
public enum DesktopText: Equatable, Sendable {
    // Connection failures and notices.
    case openedElsewhere, cannotConnect, lostOver30s, cannotProbe, noDesktop, unsupportedSystem
    case pluginStartFailed, pluginStartFailedCode(Int), pluginError(String), cannotReachServer, cannotReadCredentials
    case downloadFailed, checksumFailed, encoderFailed, hostWriteFailed
    case unlockOnComputer
    // Install and start log.
    case installing(version: String, target: String)
    case step(DesktopPluginInstaller.Step)
    case restartingAgent
    // Needs (NeedsAction) and the Windows service hint.
    case needs([String])
    case needsTitle, connectsWhenDone, windowsServiceHint, copyCommand
    // Connecting card.
    case openingDesktop, loggingIn, installingPlugin, startingPlugin, waitingForPicture, couldNotOpen
    case connectionLost, recovering, pictureComesBack
    /// Text from elsewhere (an SSH error), shown as is.
    case raw(String)

    public func text(english: Bool) -> String {
        let (zh, en) = pair
        return english ? en : zh
    }

    private var pair: (String, String) {
        switch self {
        case .openedElsewhere: return ("已在另一台设备上打开", "Opened on another device")
        case .cannotConnect: return ("无法连接桌面", "Couldn't connect to the desktop")
        case .lostOver30s: return ("连接中断超过 30 秒，桌面已断开", "The connection was lost for over 30 seconds; the desktop disconnected")
        case .cannotProbe: return ("无法检测这台主机的桌面", "Couldn't check this host's desktop")
        case .noDesktop: return ("这台主机没有图形桌面", "This host has no graphical desktop")
        case .unsupportedSystem: return ("暂不支持这台主机的系统", "This host's system isn't supported yet")
        case .pluginStartFailed: return ("桌面插件启动失败", "The desktop plugin didn't start")
        case .pluginStartFailedCode(let c): return ("桌面插件启动失败（退出码 \(c)）", "The desktop plugin didn't start (exit code \(c))")
        case .pluginError(let s): return ("桌面插件出错：\(s)", "Desktop plugin error: \(s)")
        case .cannotReachServer: return ("无法连接服务器", "Could not connect to the server")
        case .cannotReadCredentials: return ("无法读取凭据，请重新导入密钥或保存密码。", "Could not read credentials. Import the key again or save the password.")
        case .downloadFailed: return ("下载桌面插件失败", "Couldn't download the desktop plugin")
        case .checksumFailed: return ("桌面插件校验失败", "The desktop plugin failed its checksum")
        case .encoderFailed: return ("下载 OpenH264 编码器失败", "Couldn't download the OpenH264 encoder")
        case .hostWriteFailed: return ("无法在主机上写入插件", "Couldn't write the plugin on the host")
        case .unlockOnComputer: return ("请在本机解锁", "Unlock it on the computer")
        case .installing(let v, let t): return ("安装桌面插件 \(v)（\(t)）", "Installing desktop plugin \(v) (\(t))")
        case .step(let s):
            switch s {
            case .hostDownload: return ("主机直接下载…", "Downloading on the host…")
            case .phoneDownload: return ("主机下载失败，改为手机下载后上传…", "The host couldn't download it; downloading on the phone and uploading…")
            case .upload: return ("上传到主机…", "Uploading to the host…")
            case .verify: return ("校验 SHA-256…", "Checking SHA-256…")
            case .encoderHost: return ("获取 Cisco OpenH264 编码器…", "Getting Cisco's OpenH264 encoder…")
            case .encoderPhone: return ("主机获取编码器失败，改为手机下载后上传…", "The host couldn't get the encoder; downloading on the phone and uploading…")
            case .register: return ("注册插件…", "Registering the plugin…")
            case .done: return ("安装完成", "Installed")
            }
        case .restartingAgent: return ("重新启动桌面代理…", "Restarting the desktop agent…")
        case .needs(let needs):
            switch needs.first {
            case "not-logged-in": return ("请先在这台电脑上登录桌面", "Log in to the desktop on this computer first")
            case "screen-recording": return ("请在 Mac 上允许“屏幕录制”：系统设置 › 隐私与安全性 › 屏幕与系统音频录制，打开 Roamtty Desktop",
                                             "Allow Screen Recording on the Mac: System Settings › Privacy & Security › Screen & System Audio Recording, turn on Roamtty Desktop")
            case "accessibility": return ("请在 Mac 上允许“辅助功能”：系统设置 › 隐私与安全性 › 辅助功能，打开 Roamtty Desktop",
                                          "Allow Accessibility on the Mac: System Settings › Privacy & Security › Accessibility, turn on Roamtty Desktop")
            case "locked": return ("请在本机解锁", "Unlock it on the computer")
            case "portal-approval": return ("请在电脑上点“允许”共享屏幕", "Click Allow on the computer to share the screen")
            default: return ("需要在电脑上操作", "Something needs doing on the computer")
            }
        case .needsTitle: return ("需要在电脑上操作", "Something needs doing on the computer")
        case .connectsWhenDone: return ("满足后会自动连接", "It connects by itself once done")
        case .windowsServiceHint: return ("在这台电脑上用管理员 PowerShell 运行一次下面的命令，之后电脑重启或锁屏时也能直接连接：",
                                          "Run this once in an administrator PowerShell on the PC to connect after restarts and on the lock screen too:")
        case .copyCommand: return ("复制命令", "Copy command")
        case .openingDesktop: return ("正在打开桌面", "Opening the desktop")
        case .loggingIn: return ("登录主机", "Logging in")
        case .installingPlugin: return ("安装桌面插件", "Installing the desktop plugin")
        case .startingPlugin: return ("启动桌面插件", "Starting the desktop plugin")
        case .waitingForPicture: return ("等待画面", "Waiting for the picture")
        case .couldNotOpen: return ("无法打开桌面", "Could not open the desktop")
        case .connectionLost: return ("连接中断", "Connection lost")
        case .recovering: return ("正在恢复…", "Recovering…")
        case .pictureComesBack: return ("网络恢复后画面会自动回来", "The picture comes back with the network")
        case .raw(let s): return (s, s)
        }
    }

    /// The installer's failure as Android words it.
    public static func installFailure(_ reason: DesktopPluginInstaller.Reason) -> DesktopText {
        switch reason {
        case .download: return .downloadFailed
        case .checksum: return .checksumFailed
        case .encoder: return .encoderFailed
        case .host: return .hostWriteFailed
        }
    }

    /// Whether the NeedsAction card shows the Windows service hint and its copy command (`WindowsDesktop.SERVICE_INSTALL`).
    public static func showsWindowsServiceHint(windowsHost: Bool, needs: [String]) -> Bool {
        windowsHost && needs.first == "not-logged-in"
    }
}
