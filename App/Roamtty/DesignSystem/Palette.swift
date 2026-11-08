import SwiftUI
import UIKit

enum Palette {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color { Color(uiColor: adaptiveUI(light, dark)) }
    static func adaptiveUI(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { trait in UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light) }
    }
    static let background = adaptive(0xF3F0EB, 0x252728)
    static let panel = adaptive(0xFFFDF9, 0x353632)
    static let raised = adaptive(0xEBE7E0, 0x3D3E39)
    static let foreground = adaptive(0x2B2A27, 0xF3F0EA)
    static let secondary = adaptive(0x5F5B54, 0xC7C4BD)
    static let accent = adaptive(0x9E462C, 0xEFA783)
    static let accentPanel = adaptive(0xF4DED3, 0x5B3C30)
    static let outline = adaptive(0xD8D1C8, 0x50514B)
    static let success = adaptive(0x2E7D4F, 0x7FD19B)
    static let warning = adaptive(0x9A6200, 0xF2C46D)
    static let danger = adaptive(0xB32631, 0xFFB4A8)
    // Material roles used by Android's terminal chrome (ItermuxTheme.kt).
    static let surface = adaptive(0xFFFDF9, 0x303230)
    static let surfaceVariant = adaptive(0xF1EEE8, 0x353632)
    static let sheet = adaptive(0xF6F3EE, 0x303230)
    static let containerHighest = adaptive(0xE5E0D8, 0x484944)
    static let onAccent = adaptive(0xFFFFFF, 0x442315)
    static let inverseSurface = adaptive(0x31302D, 0xE6E2DC)
    static let inverseForeground = adaptive(0xF4F0EA, 0x31302D)

    /// Each host's own colour, picked by its id (hashed as Android's String.hashCode, since Swift's hash changes every
    /// launch) so it stays put; none is a status colour (amber, green, red).
    static func host(_ id: String) -> Color {
        let hash = id.utf16.reduce(Int32(0)) { $0 &* 31 &+ Int32($1) }
        let index = Int((Int64(hash) % Int64(hostColors.count) + Int64(hostColors.count)) % Int64(hostColors.count))
        return hostColors[index]
    }
    private static let hostColors = [
        adaptive(0x1F8A7E, 0x4FB6A8), // teal
        adaptive(0x7B5BC9, 0xB394F0), // violet
        adaptive(0x2F6FC4, 0x6AA7F5), // blue
        adaptive(0xB8457F, 0xE88BB8), // pink
        adaptive(0x1F86A6, 0x5CC3E0), // cyan
        adaptive(0x4F5BC4, 0x8F98F0) // indigo
    ]
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
