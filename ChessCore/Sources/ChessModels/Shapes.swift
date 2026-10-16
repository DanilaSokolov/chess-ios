import Foundation
import simd

/// Building blocks for meshes.
///
/// Texture coordinates are in "texture sizes" with `uvScale` texture lengths
/// per board square, so the wood grain has the same scale on every piece.
public enum Shapes {
    /// How many times the texture repeats along one unit (one board square).
    public static let uvScale: Float = 2

    /// A surface of revolution: `profile` spun around the y axis, the way a
    /// lathe turns wood. Each point is `[radius, height]`, listed from the
    /// bottom up. Start and end on the axis (radius 0) for a closed solid.
    ///
    /// Normals are smoothed between neighbouring segments, so curves look
    /// round. Repeat a point to get a sharp edge there instead.
    ///
    /// `segments` is how many slices go around: 48 looks round, 8 shows that
    /// "round" in 3D is just many flat faces.
    public static func lathe(_ profile: [SIMD2<Float>], segments: Int = 48) -> MeshData {
        var mesh = MeshData()
        // A segment's 2D normal: the segment turned 90° clockwise, which points
        // away from the axis for a profile going up, down for one going out
        // along the bottom, and up for one going in across the top.
        func normal(_ from: SIMD2<Float>, _ to: SIMD2<Float>) -> SIMD2<Float>? {
            let d = to - from
            return length(d) < 1e-6 ? nil : normalize(SIMD2(d.y, -d.x))
        }

        var rings: [UInt32] = []  // First vertex of each ring.
        var along: Float = 0  // Distance travelled along the profile, for v.
        for (i, point) in profile.enumerated() {
            if i > 0 { along += length(point - profile[i - 1]) }
            let before = i > 0 ? normal(profile[i - 1], point) : nil
            let after = i + 1 < profile.count ? normal(point, profile[i + 1]) : nil
            // A repeated point has a zero-length segment on one side: the
            // normal then comes from the other side only, which makes a crease.
            let n2 =
                switch (before, after) {
                case (let b?, let a?): normalize(b + a)
                case (let b?, nil): b
                case (nil, let a?): a
                case (nil, nil): SIMD2<Float>(0, 1)
                }
            rings.append(UInt32(mesh.positions.count))
            for j in 0...segments {  // The seam vertex is repeated: it needs u = 0 on one side and u = 1 on the other.
                let turn = Float(j) / Float(segments)
                let angle = turn * 2 * .pi
                let (c, s) = (cos(angle), sin(angle))
                // u goes around once per turn, v runs up the profile: the grain follows the lathe axis.
                mesh.addVertex(
                    [point.x * c, point.y, point.x * s], normal: [n2.x * c, n2.y, n2.x * s],
                    uv: [turn, along * uvScale])
            }
        }
        // Two triangles per quad between neighbouring rings.
        for i in 0..<profile.count - 1 where length(profile[i + 1] - profile[i]) > 1e-6 {
            for j in 0..<UInt32(segments) {
                let a = rings[i] + j
                let b = a + 1
                let c = rings[i + 1] + j
                let d = c + 1
                mesh.addTriangle(a, c, b)
                mesh.addTriangle(b, c, d)
            }
        }
        return mesh
    }

    /// Points along an ellipse arc, for round parts of a lathe profile.
    /// Angles in degrees, 0 pointing away from the axis, 90 straight up.
    public static func arc(center: SIMD2<Float>, radius: SIMD2<Float>, from: Float, to: Float, steps: Int) -> [SIMD2<
        Float
    >] {
        (0...steps).map { i in
            let angle = (from + (to - from) * Float(i) / Float(steps)) * .pi / 180
            return center + radius * SIMD2(cos(angle), sin(angle))
        }
    }

    /// A ball: the lathe of a half circle.
    public static func sphere(radius: Float, segments: Int = 20) -> MeshData {
        lathe(
            arc(center: .zero, radius: [radius, radius], from: -90, to: 90, steps: max(2, segments / 2)),
            segments: segments)
    }

    /// An axis-aligned box centered on the origin. Each face gets its own
    /// vertices: corners shared between faces would have to average their
    /// normals and the box would look rounded.
    public static func box(_ size: SIMD3<Float>) -> MeshData {
        var mesh = MeshData()
        let h = size / 2
        for axis in 0..<3 {
            for sign: Float in [-1, 1] {
                var n = SIMD3<Float>.zero
                n[axis] = sign
                // Two directions spanning the face.
                let u = SIMD3<Float>(axis == 0 ? [0, 1, 0] : [1, 0, 0])
                let v = cross(n, u)
                let center = n * h
                let (uSize, vSize) = (length(u * size), length(v * size))
                let corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { (a: Float, b: Float) in
                    mesh.addVertex(
                        center + a * u * h + b * v * h, normal: n,
                        uv: [(a + 1) / 2 * uSize, (b + 1) / 2 * vSize] * uvScale)
                }
                mesh.addTriangle(corners[0], corners[1], corners[2])
                mesh.addTriangle(corners[0], corners[2], corners[3])
            }
        }
        return mesh
    }

    /// A flat outline pushed out to `thickness`, like a cookie cutter. The
    /// outline is in the z–y plane (`[z, y]` points, any winding, no
    /// self-intersections); the solid spans x from -thickness/2 to +thickness/2.
    ///
    /// `bevel` cuts the sharp edges between the caps and the sides at 45°:
    /// each cap shrinks by `bevel` and a slanted band joins it to the sides.
    /// Light catches the band, so the solid stops looking like a cut-out plate.
    public static func extrude(_ outline: [SIMD2<Float>], thickness: Float, bevel: Float = 0) -> MeshData {
        var mesh = MeshData()
        // Work with a counter-clockwise outline, so "outside" is on the right of each edge.
        let points = signedArea(outline) >= 0 ? outline : outline.reversed()
        let half = thickness / 2
        let bevel = min(bevel, half * 0.9)
        let cap = bevel > 0 ? inset(points, by: bevel) : points
        let wall = half - bevel  // The straight sides end here; the bevel takes over.

        // Two flat caps, each triangulated the same way.
        let triangles = triangulate(cap)
        for side: Float in [-1, 1] {
            let n = SIMD3<Float>(side, 0, 0)
            let first = UInt32(mesh.positions.count)
            for p in cap {
                mesh.addVertex([side * half, p.y, p.x], normal: n, uv: p * uvScale)
            }
            for (a, b, c) in triangles {
                mesh.addTriangle(first + UInt32(a), first + UInt32(b), first + UInt32(c))
            }
        }

        // Around the outline: the side wall, and the bevel bands on both sides. Flat-shaded quads.
        var along: Float = 0
        for i in points.indices {
            let j = (i + 1) % points.count
            let (p, q) = (points[i], points[j])
            let edge = q - p
            let out = normalize(SIMD2(edge.y, -edge.x))  // Right of the edge = outside.
            let sideNormal = SIMD3<Float>(0, out.y, out.x)
            let (u0, u1) = (along * uvScale, (along + length(edge)) * uvScale)
            along += length(edge)

            func quad(_ corners: [(SIMD3<Float>, SIMD2<Float>)], _ normal: SIMD3<Float>) {
                let ids = corners.map { mesh.addVertex($0.0, normal: normal, uv: $0.1) }
                mesh.addTriangle(ids[0], ids[1], ids[2])
                mesh.addTriangle(ids[0], ids[2], ids[3])
            }
            quad(
                [
                    ([-wall, p.y, p.x], [u0, -wall * uvScale]), ([wall, p.y, p.x], [u0, wall * uvScale]),
                    ([wall, q.y, q.x], [u1, wall * uvScale]), ([-wall, q.y, q.x], [u1, -wall * uvScale]),
                ], sideNormal)
            guard bevel > 0 else { continue }
            for side: Float in [-1, 1] {
                // Halfway between facing sideways and facing out of the cap.
                let n = normalize(sideNormal + SIMD3(side, 0, 0))
                let (ci, cj) = (cap[i], cap[j])
                quad(
                    [
                        ([side * wall, p.y, p.x], [u0, side * wall * uvScale]),
                        ([side * half, ci.y, ci.x], [u0, side * half * uvScale]),
                        ([side * half, cj.y, cj.x], [u1, side * half * uvScale]),
                        ([side * wall, q.y, q.x], [u1, side * wall * uvScale]),
                    ], n)
            }
        }
        return mesh
    }

    /// Moves every point of a counter-clockwise outline `distance` inwards.
    /// Each point slides along the bisector of its corner, far enough that
    /// both neighbouring edges end up `distance` away; very sharp corners are
    /// limited so they do not shoot across the shape.
    static func inset(_ points: [SIMD2<Float>], by distance: Float) -> [SIMD2<Float>] {
        points.indices.map { i in
            let p = points[i]
            let prev = points[(i + points.count - 1) % points.count]
            let next = points[(i + 1) % points.count]
            func inward(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
                let e = normalize(b - a)
                return SIMD2(-e.y, e.x)  // Left of the edge = inside, for a counter-clockwise outline.
            }
            let (n1, n2) = (inward(prev, p), inward(p, next))
            let bisector = normalize(n1 + n2)
            return p + bisector * distance / max(dot(bisector, n1), 0.4)
        }
    }

    /// Twice the area of a polygon, positive when its points run counter-clockwise.
    static func signedArea(_ points: [SIMD2<Float>]) -> Float {
        points.indices.reduce(0) { sum, i in
            let p = points[i]
            let q = points[(i + 1) % points.count]
            return sum + (p.x * q.y - q.x * p.y)
        }
    }

    /// Splits a counter-clockwise simple polygon into triangles by "ear
    /// clipping": repeatedly cut off a corner whose triangle contains no
    /// other point of the polygon. Returns indices into `points`.
    static func triangulate(_ points: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        func cross2(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func inside(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            cross2(a, b, p) >= 0 && cross2(b, c, p) >= 0 && cross2(c, a, p) >= 0
        }

        var remaining = Array(points.indices)
        var result: [(Int, Int, Int)] = []
        while remaining.count > 3 {
            var clipped = false
            for k in remaining.indices {
                let ia = remaining[(k + remaining.count - 1) % remaining.count]
                let ib = remaining[k]
                let ic = remaining[(k + 1) % remaining.count]
                let (a, b, c) = (points[ia], points[ib], points[ic])
                guard cross2(a, b, c) > 0 else { continue }  // A dent, not an ear.
                let blocked = remaining.contains { i in
                    i != ia && i != ib && i != ic && inside(points[i], a, b, c)
                }
                if !blocked {
                    result.append((ia, ib, ic))
                    remaining.remove(at: k)
                    clipped = true
                    break
                }
            }
            if !clipped { break }  // Not a simple polygon; give up rather than loop forever.
        }
        if remaining.count == 3 {
            result.append((remaining[0], remaining[1], remaining[2]))
        }
        return result
    }
}
