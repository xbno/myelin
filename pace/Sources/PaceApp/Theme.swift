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

    /// Verdict text color. A bar color bright enough to read on the menu bar can be invisible
    /// as text on a light popover, so on that surface it is darkened by how bright it actually
    /// is — yellow needs a lot, pink barely any. The swatch beside the text keeps the bar's
    /// own color, so the two still read as the same thing.
    func verdictColor(_ state: PaceState, onLightSurface: Bool) -> Color {
        switch state {
        case .onPace: return used
        case .over: return over
        case .under: return onLightSurface ? Palette.readableOnLight(unspent) : unspent
        }
    }

    /// Target luminance for text on a light background; above it, brightness comes down in
    /// proportion and saturation up a little to keep the hue recognisable.
    static func readableOnLight(_ color: Color, target: Double = 0.45) -> Color {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return color }
        let luminance = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        guard luminance > target else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(nsColor: NSColor(hue: h, saturation: min(1, s * 1.15),
                                      brightness: b * CGFloat(target) / luminance, alpha: a))
    }

    func swatchColor(_ state: PaceState) -> Color {
        switch state {
        case .onPace: return used
        case .over: return over
        case .under: return unspent
        }
    }
}
