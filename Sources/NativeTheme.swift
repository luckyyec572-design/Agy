import SwiftUI
import UIKit

/// Explicit surface levels keep chat cards distinct in both appearances.
enum NativeTheme {
    static let canvas = adaptive(light: 0xF2F2F7, dark: 0x11151E)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1D2432)
    static let composer = adaptive(light: 0xFFFFFF, dark: 0x242D3E)
    static let border = adaptive(light: 0xE2E7E4, dark: 0x38445C)
    static let text = adaptive(light: 0x19201F, dark: 0xEDF3EF)
    static let secondaryText = adaptive(light: 0x626D67, dark: 0xADBAB2)
    static let accent = adaptive(light: 0x3264CE, dark: 0xA4C1FF)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x102348)
    static let inactiveControl = adaptive(light: 0xE1E5E3, dark: 0x3A4840)
    static let inactiveSymbol = adaptive(light: 0x6A756F, dark: 0xB0BDB5)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}
