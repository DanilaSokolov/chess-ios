import Foundation

/// How much the 3D board may cost the device.
///
/// A phone that runs hot lowers its own clock speeds (thermal throttling):
/// frames take longer and the battery drains faster. Games answer by drawing
/// less. The system reports how hot it is through `ProcessInfo.thermalState`;
/// Low Power Mode is the player asking for the same thing.
///
/// What each step drops, from the most expensive to the least visible:
/// - shadows: a second render pass of every piece, from the light's side;
/// - round detail: the pieces are lathed from profiles, and fewer segments
///   around means fewer triangles;
/// - the lacquer (clear coat): a second highlight in the material.
public enum RenderQuality: Int, Comparable, Sendable, CaseIterable {
    case full
    /// Hot (`.serious`) or Low Power Mode.
    case reduced
    /// About to be throttled hard (`.critical`).
    case minimal

    public init(thermalState: ProcessInfo.ThermalState, isLowPowerMode: Bool) {
        self =
            switch thermalState {
            case .critical: .minimal
            case .serious: .reduced
            // .nominal, .fair, and any state added later.
            default: isLowPowerMode ? .reduced : .full
            }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The player's choice of segments, capped. Faceted pieces (8) are
    /// already below every cap and stay as chosen.
    public func pieceSegments(preferred: Int) -> Int {
        switch self {
        case .full: preferred
        case .reduced: min(preferred, 24)
        case .minimal: min(preferred, 12)
        }
    }

    public var hasShadows: Bool { self == .full }
    public var hasClearCoat: Bool { self != .minimal }
}
