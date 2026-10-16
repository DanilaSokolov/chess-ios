// Writes every piece in both colors as a USDZ file, so the generated models
// can be opened in Finder (Quick Look), Xcode or Reality Composer Pro.
//
//   swift run export-pieces ../Models
import ChessCore
import ChessModels
import CoreGraphics
import Foundation
import ImageIO
import ModelIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Models", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let format = MDLAsset.canExportFileExtension("usdz") ? "usdz" : "usdc"

let names: [PieceKind: String] = [
    .pawn: "pawn", .rook: "rook", .knight: "knight", .bishop: "bishop", .queen: "queen", .king: "king",
]
let colors: [(name: String, rgb: SIMD3<Float>)] = [("white", [0.92, 0.86, 0.74]), ("black", [0.09, 0.07, 0.06])]

/// Model I/O wants the same data as RealityKit, just in its own wrappers:
/// one interleaved vertex buffer described by an `MDLVertexDescriptor`,
/// and an index buffer per submesh with its material.
func makeMesh(_ data: MeshData, material: MDLMaterial, allocator: MDLMeshBufferDataAllocator) -> MDLMesh {
    var interleaved: [Float] = []
    interleaved.reserveCapacity(data.positions.count * 8)
    for i in data.positions.indices {
        let (p, n, t) = (data.positions[i], data.normals[i], data.uvs[i])
        interleaved += [p.x, p.y, p.z, n.x, n.y, n.z, t.x, t.y]
    }
    let vertices = allocator.newBuffer(with: interleaved.withUnsafeBytes { Data($0) }, type: .vertex)
    let indices = allocator.newBuffer(with: data.indices.withUnsafeBytes { Data($0) }, type: .index)

    let layout = MDLVertexDescriptor()
    layout.attributes[0] = MDLVertexAttribute(
        name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
    layout.attributes[1] = MDLVertexAttribute(
        name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
    layout.attributes[2] = MDLVertexAttribute(
        name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
    layout.layouts[0] = MDLVertexBufferLayout(stride: 32)

    let submesh = MDLSubmesh(
        indexBuffer: indices, indexCount: data.indices.count, indexType: .uInt32,
        geometryType: .triangles, material: material)
    return MDLMesh(vertexBuffer: vertices, vertexCount: data.positions.count, descriptor: layout, submeshes: [submesh])
}

let allocator = MDLMeshBufferDataAllocator()
for kind in PieceKind.allCases {
    let data = PieceModels.mesh(for: kind)
    for color in colors {
        // Physically based: base color plus how rough and how lacquered the surface is.
        let material = MDLMaterial(
            name: "\(color.name)-\(names[kind]!)", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: color.rgb))
        material.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, float: 0.32))
        material.setProperty(MDLMaterialProperty(name: "clearcoat", semantic: .clearcoat, float: 0.7))

        let mesh = makeMesh(data, material: material, allocator: allocator)
        mesh.name = "\(color.name)_\(names[kind]!)"
        let asset = MDLAsset()
        asset.upAxis = [0, 1, 0]
        asset.add(mesh)

        let url = folder.appendingPathComponent("\(color.name)-\(names[kind]!).\(format)")
        try asset.export(to: url)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("\(url.lastPathComponent): \(data.triangleCount) треугольников, \(size / 1024) КБ")
    }
}

// The wood grain the app puts on the pieces, as a picture.
let size = 512
var pixels = WoodTexture.pixels(size: size)
let image = pixels.withUnsafeMutableBytes { raw in
    CGContext(
        data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
}
let woodURL = folder.appendingPathComponent("wood.png")
let destination = CGImageDestinationCreateWithURL(woodURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wood.png: текстура дерева \(size)×\(size)")
