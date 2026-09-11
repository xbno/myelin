import AppKit
import SwiftUI
import PaceCore

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// "#RRGGBB" for storing a picked color.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}

/// The colors a bar draws with. `ink` is the text/track/tick color and follows the surface:
/// white or black in the menu bar, the label color in the popover.
struct Palette {
    var used: Color
    var unspent: Color
    var over: Color
    var ink: Color

    init(settings: AppSettings, ink: Color) {
        used = Color(hex: settings.usedColor)
        unspent = Color(hex: settings.unspentColor)
        over = Color(hex: settings.overColor)
        self.ink = ink
    }

    func color(for fill: FillColor, solid: Color?) -> Color {
        switch fill {
        case .used: return used
        case .unspent: return unspent
        case .over: return over
        case .solid: return solid ?? used
        }
    }

    /// Verdict text color. Yellow text is unreadable on a light surface, so use amber there.
    func verdictColor(_ state: PaceState, onLightSurface: Bool) -> Color {
        switch state {
        case .onPace: return used
        case .over: return over
        case .under: return onLightSurface ? Color(hex: "#9A6B00") : unspent
        }
    }

    func swatchColor(_ state: PaceState) -> Color {
        switch state {
        case .onPace: return used
        case .over: return over
        case .under: return unspent
        }
    }
}
