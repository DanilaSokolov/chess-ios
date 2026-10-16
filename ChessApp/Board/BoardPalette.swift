import RealityKit
import SwiftUI

/// Square colours shared by the 2D and 3D boards, so the two never drift apart.
enum BoardPalette {
    struct RGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    static let lightSquare = RGB(red: 0.93, green: 0.85, blue: 0.71)
    static let darkSquare = RGB(red: 0.71, green: 0.53, blue: 0.39)
}

extension Color {
    init(_ rgb: BoardPalette.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

extension BoardPalette.RGB {
    /// For RealityKit materials. A property here rather than an extension of
    /// `SimpleMaterial.Color`: that alias is declared in an extension of the
    /// `Material` protocol, and Swift refuses to extend a protocol's alias
    /// reached through a conforming type. Extending the real types would need
    /// two, NSColor on macOS and UIColor on iOS, behind `#if os`.
    var materialColor: SimpleMaterial.Color {
        SimpleMaterial.Color(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }
}
