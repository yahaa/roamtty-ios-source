import SwiftUI
import UIKit

struct HostSystemMark: View {
    @Environment(\.colorScheme) private var scheme
    let system: String
    var info: (asset: String, brand: UInt32, scale: CGFloat)? {
        switch system.uppercased() {
        case "UBUNTU": return ("ubuntu", 0xE95420, 0.6)
        case "DEBIAN": return ("debian", 0xD70A53, 0.64)
        case "CENTOS": return ("centos", 0x9C4C99, 0.6)
        case "FEDORA": return ("fedora", 0x51A2DA, 0.6)
        case "ARCH": return ("archlinux", 0x1793D1, 0.6)
        case "REDHAT": return ("redhat", 0xEE0000, 0.6)
        case "OPENSUSE": return ("opensuse", 0x73BA25, 0.68)
        case "ROCKY": return ("rockylinux", 0x10B981, 0.6)
        case "ALMALINUX": return ("almalinux", 0x0F8BD6, 0.6)
        case "GENTOO": return ("gentoo", 0x8E7FC4, 0.6)
        case "NIXOS": return ("nixos", 0x7EBAE4, 0.6)
        case "LINUXMINT": return ("linuxmint", 0x87CF3E, 0.6)
        case "LINUX": return ("linux", 0xF2B705, 0.64)
        case "WINDOWS": return ("windows", 0x0078D4, 0.5)
        case "MACOS": return ("macos", 0x9A9A9F, 0.64)
        default: return nil
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if let info {
                    let darkInk = ["DEBIAN", "LINUX", "REDHAT"].contains(system.uppercased())
                    if scheme == .dark && darkInk { Color(uiColor: UIColor(hex: 0xE6E1D8)) }
                    Color(uiColor: UIColor(hex: info.brand)).opacity(scheme == .dark ? darkInk ? 0.14 : 0.22 : 0.12)
                    Image("ic_os_" + info.asset).resizable().scaledToFit().frame(width: side * info.scale, height: side * info.scale)
                } else {
                    Palette.accentPanel
                    AppIcon("ic_os_server", size: side * 0.5).foregroundStyle(Palette.adaptive(0x682F20, 0xF9D9C9))
                }
            }.clipShape(RoundedRectangle(cornerRadius: side * 0.28)).accessibilityLabel(system)
        }
    }
}

/// Untiled logo used by the desktop screen card, matching Android's strip and backdrop.
struct HostSystemLogo: View {
    let system: String
    var monochrome = false
    var body: some View {
        if let info = HostSystemMark(system: system).info {
            Image("ic_os_" + info.asset).resizable().renderingMode(monochrome ? .template : .original).scaledToFit()
        } else {
            Image("ic_os_server").resizable().renderingMode(.template).scaledToFit()
        }
    }
}
