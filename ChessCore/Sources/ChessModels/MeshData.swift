import simd

/// A triangle mesh as plain arrays: what every 3D API ends up drawing.
///
/// - `positions[i]` and `normals[i]` describe vertex `i`. The normal is the
///   direction the surface faces at that vertex; lighting depends on it.
/// - `uvs[i]` is where vertex `i` lands on a texture ("texture
///   coordinates"): u across, v along the image, in image sizes, so 2 means
///   the texture repeats twice.
/// - Every three `indices` form a triangle. Its front side is the one from
///   which the vertices appear counter-clockwise; renderers usually skip
///   back sides, so the order matters.
///
/// RealityKit takes this through `MeshDescriptor`, Model I/O through
/// `MDLMesh`, Metal through two buffers and `drawIndexedPrimitives`.
public struct MeshData: Sendable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    public var indices: [UInt32] = []

    public init() {}

    public var triangleCount: Int { indices.count / 3 }

    /// Smallest and largest coordinates of all vertices.
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        positions.reduce((SIMD3(repeating: .infinity), SIMD3(repeating: -.infinity))) {
            (simd_min($0.0, $1), simd_max($0.1, $1))
        }
    }

    @discardableResult
    mutating func addVertex(_ position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>) -> UInt32 {
        positions.append(position)
        normals.append(normal)
        uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    /// Adds a triangle facing the way its vertex normals point. Writing every
    /// generator with the "right" vertex order is error-prone; deriving it
    /// from the normals keeps all triangles consistent. Triangles without
    /// area (where a lathe meets its axis) are dropped.
    mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let pa = positions[Int(a)]
        let pb = positions[Int(b)]
        let pc = positions[Int(c)]
        let facing = cross(pb - pa, pc - pa)  // Points out of the side where a, b, c run counter-clockwise.
        guard length(facing) > 1e-9 else { return }
        let wanted = normals[Int(a)] + normals[Int(b)] + normals[Int(c)]
        indices += dot(facing, wanted) >= 0 ? [a, b, c] : [a, c, b]
    }

    /// Adds `other`, moved and turned by `transform` (rotation and translation only).
    public mutating func append(_ other: MeshData, transform: simd_float4x4 = matrix_identity_float4x4) {
        let offset = UInt32(positions.count)
        let rotation = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        for (p, n) in zip(other.positions, other.normals) {
            let moved = transform * SIMD4(p, 1)
            positions.append(SIMD3(moved.x, moved.y, moved.z))
            normals.append(normalize(rotation * n))
        }
        uvs += other.uvs
        indices += other.indices.map { $0 + offset }
    }
}

// MARK: - Transforms

extension simd_float4x4 {
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    static func rotationX(_ angle: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: angle, axis: [1, 0, 0]))
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: angle, axis: [0, 1, 0]))
    }
}
