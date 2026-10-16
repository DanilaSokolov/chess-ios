import ChessCore
import simd

/// Staunton-style chess pieces generated from profiles.
///
/// Units: one board square is 1. Every piece stands on y = 0, centered on
/// the y axis; the knight faces -z (towards Black when White plays from +z).
/// Profiles are `[radius, height]` points from the bottom up, see
/// `Shapes.lathe`; a repeated point makes a sharp edge.
///
/// `segments` is how finely round parts are cut: 48 looks smooth, 8 faceted.
public enum PieceModels {
    /// Slices around a round part: enough that the eye sees a smooth curve.
    public static let smoothSegments = 48
    /// Few enough slices that the facets show, for learning what "round" is made of.
    public static let facetedSegments = 8

    public static func mesh(for kind: PieceKind, segments: Int = smoothSegments) -> MeshData {
        switch kind {
        case .pawn: pawn(segments)
        case .rook: rook(segments)
        case .knight: knight(segments)
        case .bishop: bishop(segments)
        case .queen: queen(segments)
        case .king: king(segments)
        }
    }

    /// Details drawn in a contrasting material, if the piece has any: the
    /// slit in the bishop's mitre.
    public static func accent(for kind: PieceKind) -> MeshData? {
        guard kind == .bishop else { return nil }
        // A real slit is cut out of the mitre. Cutting one mesh with another
        // (CSG) is a topic of its own; a thin dark slab, tilted and pushed in so
        // only its outer edge shows, reads the same from the board.
        // Narrower than the mitre, so it only shows on the front, not as "ears" on the sides.
        let slab = Shapes.box([0.16, 0.022, 0.2])
        var mesh = MeshData()
        mesh.append(slab, transform: .translation([0, 0.88, -0.08]) * .rotationX(-0.7))
        return mesh
    }

    /// The foot every piece shares: a flat bottom with a sharp edge, a rounded
    /// rim and a bead, ending about 0.15 high and 0.09 inside `radius`.
    static func foot(radius r: Float) -> [SIMD2<Float>] {
        [[0, 0], [r, 0], [r, 0], [r, 0.045]]
            + Shapes.arc(center: [r - 0.03, 0.045], radius: [0.03, 0.03], from: 0, to: 90, steps: 6)
            + [[r - 0.06, 0.085]]
            + Shapes.arc(center: [r - 0.09, 0.11], radius: [0.035, 0.035], from: -90, to: 90, steps: 8)
    }

    /// A thin disc around the stem, as below a pawn's head.
    static func collar(at y: Float, inner: Float, outer: Float, height: Float = 0.03) -> [SIMD2<Float>] {
        [
            [inner, y], [outer, y + 0.015], [outer, y + 0.015], [outer, y + 0.015 + height],
            [outer, y + 0.015 + height],
            [inner, y + 0.03 + height],
        ]
    }

    static func pawn(_ segments: Int) -> MeshData {
        Shapes.lathe(
            foot(radius: 0.34)
                // A slimmer stem and a bigger head than the first version: the stem
                // radii are ~18% smaller, the head grows from 0.13 to 0.15 and its
                // center rises by 0.02 so it does not sink into the collar.
                + [[0.17, 0.17], [0.12, 0.24], [0.095, 0.33], [0.085, 0.42]]
                + collar(at: 0.43, inner: 0.085, outer: 0.19)
                + Shapes.arc(center: [0, 0.64], radius: [0.15, 0.15], from: -58, to: 90, steps: 14),
            segments: segments
        )
    }

    static func rook(_ segments: Int) -> MeshData {
        // A tower with a hollow top; the battlements are separate blocks.
        var mesh = Shapes.lathe(
            foot(radius: 0.36)
                + [
                    [0.22, 0.19], [0.2, 0.3], [0.19, 0.45], [0.2, 0.58], [0.24, 0.66], [0.28, 0.7],
                    [0.28, 0.7], [0.28, 0.86], [0.28, 0.86], [0.2, 0.86], [0.2, 0.86], [0.2, 0.78], [0.2, 0.78],
                    [0, 0.78],
                ],
            segments: segments
        )
        let merlon = Shapes.box([0.08, 0.09, 0.13])
        for k in 0..<6 {
            let angle = Float(k) / 6 * 2 * .pi
            // Turn the block so its x axis points away from the center, then move it onto the rim.
            mesh.append(
                merlon, transform: .translation([0.24 * cos(angle), 0.905, 0.24 * sin(angle)]) * .rotationY(-angle))
        }
        return mesh
    }

    static func knight(_ segments: Int) -> MeshData {
        var mesh = Shapes.lathe(
            foot(radius: 0.36) + [[0.24, 0.17], [0.23, 0.2], [0.23, 0.2], [0, 0.2]], segments: segments)
        // The head in profile, seen from the side, `[z, y]`, muzzle towards -z.
        let head: [SIMD2<Float>] = [
            [0.17, 0.18], [0.21, 0.32], [0.21, 0.46], [0.18, 0.58], [0.13, 0.69],  // back of the neck
            [0.07, 0.78], [0.04, 0.86], [0.02, 0.95],  // mane up to the ear
            [-0.03, 0.88], [-0.06, 0.86], [-0.12, 0.81], [-0.19, 0.73],  // forehead
            [-0.25, 0.65], [-0.29, 0.59], [-0.29, 0.55], [-0.26, 0.52],  // nose and mouth
            [-0.19, 0.5], [-0.12, 0.5], [-0.08, 0.45],  // jaw and throat
            [-0.1, 0.37], [-0.15, 0.27], [-0.17, 0.18],  // chest
        ]
        // A bevel on the edges: without it the head looks like a cut-out plate.
        mesh.append(Shapes.extrude(head, thickness: 0.24, bevel: 0.045))
        return mesh
    }

    static func bishop(_ segments: Int) -> MeshData {
        Shapes.lathe(
            foot(radius: 0.35)
                + [[0.18, 0.18], [0.13, 0.26], [0.11, 0.4], [0.1, 0.55]]
                + collar(at: 0.57, inner: 0.1, outer: 0.19)
                // The mitre: a tall egg.
                + Shapes.arc(center: [0, 0.82], radius: [0.14, 0.2], from: -60, to: 70, steps: 14)
                + [[0.025, 1.02]]
                + Shapes.arc(center: [0, 1.065], radius: [0.045, 0.045], from: -60, to: 90, steps: 8),
            segments: segments
        )
    }

    static func queen(_ segments: Int) -> MeshData {
        var mesh = Shapes.lathe(
            foot(radius: 0.37)
                + [[0.2, 0.19], [0.15, 0.3], [0.12, 0.5], [0.11, 0.7]]
                + collar(at: 0.72, inner: 0.11, outer: 0.21)
                // The crown: a cup flaring out, then a low dome.
                + [
                    [0.13, 0.86], [0.17, 0.95], [0.22, 1.04], [0.24, 1.08], [0.24, 1.08], [0.16, 1.1], [0.1, 1.15],
                    [0.05, 1.17],
                ]
                + Shapes.arc(center: [0, 1.215], radius: [0.055, 0.055], from: -55, to: 90, steps: 8),
            segments: segments
        )
        let point = Shapes.sphere(radius: 0.035, segments: min(12, segments))
        for k in 0..<9 {
            let angle = Float(k) / 9 * 2 * .pi
            mesh.append(point, transform: .translation([0.22 * cos(angle), 1.1, 0.22 * sin(angle)]))
        }
        return mesh
    }

    static func king(_ segments: Int) -> MeshData {
        var mesh = Shapes.lathe(
            foot(radius: 0.38)
                + [[0.21, 0.19], [0.16, 0.3], [0.125, 0.5], [0.115, 0.78]]
                + collar(at: 0.8, inner: 0.115, outer: 0.22)
                + [
                    [0.14, 0.95], [0.19, 1.05], [0.22, 1.12], [0.22, 1.12], [0.22, 1.15], [0.22, 1.15],
                    [0.14, 1.17], [0.08, 1.21], [0, 1.23],
                ],
            segments: segments
        )
        mesh.append(Shapes.box([0.07, 0.22, 0.07]), transform: .translation([0, 1.33, 0]))
        mesh.append(Shapes.box([0.2, 0.065, 0.07]), transform: .translation([0, 1.37, 0]))
        return mesh
    }
}
