import ChessCore
import Testing
import simd

@testable import ChessModels

/// Every mesh the app can draw: each piece smooth, faceted, and at the cuts
/// a hot device falls back to (RenderQuality), plus the bishop's slit.
let allMeshes: [(String, MeshData)] = PieceKind.allCases.flatMap { kind in
    [("\(kind)", PieceModels.mesh(for: kind))]
        + [8, 12, 24].map { ("\(kind) \($0) sides", PieceModels.mesh(for: kind, segments: $0)) }
        + (PieceModels.accent(for: kind).map { [("\(kind) accent", $0)] } ?? [])
}

@Test(arguments: allMeshes.map(\.0))
func meshIsWellFormed(_ name: String) {
    let mesh = allMeshes.first { $0.0 == name }!.1
    #expect(mesh.positions.count == mesh.normals.count)
    #expect(mesh.positions.count == mesh.uvs.count, "every vertex has texture coordinates")
    #expect(mesh.indices.count % 3 == 0)
    #expect(mesh.triangleCount >= 12)
    #expect(mesh.indices.allSatisfy { Int($0) < mesh.positions.count })
    #expect(mesh.normals.allSatisfy { abs(length($0) - 1) < 1e-3 })
}

/// Every triangle's front side faces where its vertex normals point; a
/// flipped triangle would vanish or render dark.
@Test(arguments: allMeshes.map(\.0))
func trianglesFaceOutward(_ name: String) {
    let mesh = allMeshes.first { $0.0 == name }!.1
    for t in 0..<mesh.triangleCount {
        let (a, b, c) = (Int(mesh.indices[3 * t]), Int(mesh.indices[3 * t + 1]), Int(mesh.indices[3 * t + 2]))
        let facing = cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a])
        let wanted = mesh.normals[a] + mesh.normals[b] + mesh.normals[c]
        #expect(dot(facing, wanted) > 0, "\(name) triangle \(t)")
    }
}

@Test(arguments: PieceKind.allCases)
func standsOnItsSquare(_ kind: PieceKind) {
    let (lo, hi) = PieceModels.mesh(for: kind).bounds
    #expect(abs(lo.y) < 1e-4, "stands on the board")
    #expect(max(-lo.x, hi.x, -lo.z, hi.z) < 0.45, "fits inside its square")
}

@Test func heightsFollowRank() {
    func height(_ kind: PieceKind) -> Float { PieceModels.mesh(for: kind).bounds.max.y }
    #expect(height(.pawn) < height(.rook))
    #expect(height(.rook) < height(.bishop))
    #expect(height(.bishop) < height(.queen))
    #expect(height(.queen) < height(.king))
}

@Test func knightFacesForward() {
    // Only the head: the round foot is wider than it and the same on all sides.
    let head = PieceModels.mesh(for: .knight).positions.filter { $0.y > 0.3 }.map(\.z)
    #expect(-head.min()! > head.max()!, "the muzzle reaches further towards -z than the back of the neck towards +z")
}

@Test func triangulationCoversTheArea() {
    // An L shape: area 3, with a dent that a naive fan would cut wrongly.
    let points: [SIMD2<Float>] = [[0, 0], [2, 0], [2, 1], [1, 1], [1, 2], [0, 2]]
    let triangles = Shapes.triangulate(points)
    #expect(triangles.count == points.count - 2)
    let area = triangles.reduce(Float(0)) { sum, t in
        sum + abs(Shapes.signedArea([points[t.0], points[t.1], points[t.2]])) / 2
    }
    #expect(abs(area - 3) < 1e-5)
}

@Test func facetedPiecesAreCoarser() {
    for kind in PieceKind.allCases {
        #expect(PieceModels.mesh(for: kind, segments: 8).triangleCount < PieceModels.mesh(for: kind).triangleCount / 3)
    }
}

@Test func bevelShrinksTheCaps() {
    // A 1×1 square, bevelled by 0.1: the caps are 0.8×0.8, the sides stay 1×1.
    let square: [SIMD2<Float>] = [[0, 0], [1, 0], [1, 1], [0, 1]]
    let inset = Shapes.inset(square, by: 0.1)
    #expect(inset.allSatisfy { p in (0.09...0.91).contains(p.x) && (0.09...0.91).contains(p.y) })
    #expect(abs(Shapes.signedArea(inset) / 2 - 0.64) < 1e-4)

    let solid = Shapes.extrude(square, thickness: 0.5, bevel: 0.1)
    let (lo, hi) = solid.bounds
    #expect(abs(hi.x - 0.25) < 1e-5 && abs(lo.x + 0.25) < 1e-5, "full thickness kept")
    #expect(abs(hi.z - 1) < 1e-5 && abs(lo.y) < 1e-5, "full outline kept")
}

@Test func knightHeadOutlineStaysSimpleWhenBevelled() {
    // If the inset outline crossed itself, ear clipping would give up early.
    let knight = PieceModels.mesh(for: .knight)
    let plain = Shapes.lathe(PieceModels.foot(radius: 0.36) + [[0.24, 0.17], [0.23, 0.2], [0.23, 0.2], [0, 0.2]])
    let headTriangles = knight.triangleCount - plain.triangleCount
    let outline = 22
    // Two caps of outline - 2 triangles, plus a wall and two bevel bands of 2 triangles per edge.
    #expect(headTriangles == 2 * (outline - 2) + 3 * 2 * outline)
}

@Test func slitSitsOnTheMitre() {
    let (lo, hi) = PieceModels.accent(for: .bishop)!.bounds
    #expect(lo.y > 0.75 && hi.y < 1.0, "within the mitre's height")
    // Wherever the slab pokes out of the mitre (an ellipse turned around the
    // axis: center 0.82, radii 0.14 × 0.2), it must be on the front, z < 0.
    for p in PieceModels.accent(for: .bishop)!.positions {
        let h = (p.y - 0.82) / 0.2
        let mitreRadius = 0.14 * (max(0, 1 - h * h)).squareRoot()
        if (p.x * p.x + p.z * p.z).squareRoot() > mitreRadius {
            #expect(p.z < 0, "slit pokes out at \(p)")
        }
    }
    #expect(PieceModels.accent(for: .pawn) == nil)
}

@Test func woodTextureTiles() {
    // The left column must continue the right one, and the top row the bottom one.
    for t: Float in stride(from: 0, to: 1, by: 0.1) {
        #expect(abs(WoodTexture.shade(0, t) - WoodTexture.shade(1, t)) < 1e-3)
        #expect(abs(WoodTexture.shade(t, 0) - WoodTexture.shade(t, 1)) < 1e-3)
    }
    let pixels = WoodTexture.pixels(size: 64)
    #expect(pixels.count == 64 * 64 * 4)
    let grey = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
    #expect(grey.max()! - grey.min()! > 40, "visible grain, not a flat colour")
}
