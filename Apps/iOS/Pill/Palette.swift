import SwiftUI

/// The approved mockups' colours. The product is a black screen; these are its only other inks.
enum Palette {
    static let on = Color(hex: 0x30d158)
    static let off = Color(hex: 0xff453a)
    static let panel = Color(hex: 0x15151a)
    static let raise = Color(hex: 0x1c1c22)
    static let well = Color(hex: 0x2d2d35)
    static let line = Color(hex: 0x2a2a31)
    static let ink = Color(hex: 0xe9e8e3)
    static let mute = Color(hex: 0x85858d)
    static let accent = Color(hex: 0x0a84ff)
    /// The connecting sweep and the onboarding spinner, deep to light.
    static let sweep = [Color(hex: 0x1a55c4), Color(hex: 0x8fc6ff)]

    static var sweepStops: [Gradient.Stop] {
        [.init(color: .clear, location: 0), .init(color: .clear, location: 0.58),
         .init(color: sweep[0], location: 0.78), .init(color: sweep[1], location: 0.9),
         .init(color: .clear, location: 1)]
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}
