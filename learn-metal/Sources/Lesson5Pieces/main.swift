// Урок 5. Шахматные фигуры из игры — на чистом Metal.
//
// Те же массивы, что 3D-доска в приложении отдаёт RealityKit
// (`PieceModels.mesh(for:)`), здесь идут прямо в GPU. Это упражнение 5
// из MODELS.md, и заодно новое:
//
// • Свои буферы вершин вместо Model I/O: отдельный буфер на каждое свойство
//   (позиции, нормали, UV) и буфер индексов. Vertex descriptor говорит GPU,
//   где что лежит.
// • Подвох с выравниванием: SIMD3<Float> в Swift занимает 16 байт, а не 12
//   (четвёртое число — пустое, для выравнивания). Шаг (stride) буфера должен
//   это учитывать, иначе каждая вершина «съедет» на 4 байта.
// • Текстура и сэмплер: картинка дерева из `WoodTexture` загружается в
//   MTLTexture, шейдер берёт из неё цвет по UV вершины. Сэмплер решает, что
//   делать между пикселями (сглаживать) и за краем картинки (повторять).
// • Блик (Блинн — Фонг) поверх освещения из урока 3 — так выглядит лак.
//
//   swift run Lesson5Pieces
import ChessCore
import ChessModels
import LessonKit
import Metal
import MetalKit
import QuartzCore

let shaders = """
#include <metal_stdlib>
using namespace metal;

// Каждое поле — из своего буфера: см. vertexDescriptor в Swift.
struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct Uniforms {
    float4x4 model;
    float4x4 viewProjection;
    float4 tint;        // цвет дерева: слоновая кость или эбен
    float4 camera;      // позиция камеры (w не используется), для блика
    float textured;     // 1 — дерево, 0 — однотонно (подставка)
};

struct Varyings {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
};

vertex Varyings vertexMain(VertexIn in [[stage_in]], constant Uniforms &u [[buffer(4)]]) {
    Varyings out;
    float4 world = u.model * float4(in.position, 1);
    out.position = u.viewProjection * world;
    out.world = world.xyz;
    out.normal = (u.model * float4(in.normal, 0)).xyz;
    out.uv = in.uv;
    return out;
}

fragment float4 fragmentMain(Varyings in [[stage_in]],
                             constant Uniforms &u [[buffer(4)]],
                             texture2d<float> wood [[texture(0)]]) {
    // repeat: UV больше 1 повторяет картинку; linear: смешивает соседние пиксели.
    constexpr sampler grain(address::repeat, filter::linear, mip_filter::linear);
    float3 base = u.tint.rgb * (u.textured > 0.5 ? wood.sample(grain, in.uv).rgb : float3(1));

    float3 n = normalize(in.normal);
    float3 toLight = normalize(float3(0.5, 1.0, 0.7));
    float3 toCamera = normalize(u.camera.xyz - in.world);
    float diffuse = max(dot(n, toLight), 0.0);
    // Блик: насколько нормаль совпадает с серединой между «к свету» и «к камере».
    float specular = pow(max(dot(n, normalize(toLight + toCamera)), 0.0), 48.0) * 0.6 * u.textured;
    return float4(base * (0.2 + 0.8 * diffuse) + specular, 1);
}
"""

struct Uniforms {
    var model: float4x4
    var viewProjection: float4x4
    var tint: SIMD4<Float>
    var camera: SIMD4<Float>
    var textured: Float
}

/// Сетка в памяти GPU: по буферу на свойство и буфер индексов.
struct GPUMesh {
    let positions, normals, uvs, indices: any MTLBuffer
    let indexCount: Int

    init(_ data: MeshData, device: any MTLDevice) {
        // `BitwiseCopyable`: only plain values (numbers, SIMD vectors) may be
        // copied to the GPU byte for byte; a class reference there would be garbage.
        func buffer<T: BitwiseCopyable>(_ array: [T]) -> any MTLBuffer {
            array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        }
        positions = buffer(data.positions)
        normals = buffer(data.normals)
        uvs = buffer(data.uvs)
        indices = buffer(data.indices)
        indexCount = data.indices.count
    }
}

@MainActor
final class PiecesLesson: NSObject, @MainActor Lesson {
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    let depthState: any MTLDepthStencilState
    let wood: any MTLTexture
    let pieces: [(mesh: GPUMesh, x: Float)]
    let plate: GPUMesh
    let start = CACurrentMediaTime()
    var aspect: Float = 1

    required init(view: MTKView) {
        let device = view.device!
        queue = device.makeCommandQueue()!
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.16, green: 0.15, blue: 0.14, alpha: 1)

        // Шесть фигур в ряд, от пешки до короля, и подставка под ними.
        let kinds: [PieceKind] = [.pawn, .rook, .knight, .bishop, .queen, .king]
        pieces = kinds.enumerated().map { i, kind in
            (GPUMesh(PieceModels.mesh(for: kind), device: device), Float(i) - 2.5)
        }
        plate = GPUMesh(Shapes.box([6.6, 0.1, 1.4]), device: device)

        // Текстура: те же байты, что приложение отдаёт RealityKit.
        let size = 512
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: true)
        wood = device.makeTexture(descriptor: descriptor)!
        let pixels = WoodTexture.pixels(size: size)
        wood.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        // Уменьшенные копии (mipmaps) — чтобы вдали текстура не рябила.
        let mips = queue.makeCommandBuffer()!
        let blit = mips.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: wood)
        blit.endEncoding()
        mips.commit()

        // Где искать каждое поле вершины: атрибут → буфер, шаг буфера.
        let layout = MTLVertexDescriptor()
        for (index, format, stride) in [
            (0, MTLVertexFormat.float3, MemoryLayout<SIMD3<Float>>.stride), // 16, не 12!
            (1, .float3, MemoryLayout<SIMD3<Float>>.stride),
            (2, .float2, MemoryLayout<SIMD2<Float>>.stride),
        ] {
            layout.attributes[index].format = format
            layout.attributes[index].bufferIndex = index
            layout.attributes[index].offset = 0
            layout.layouts[index].stride = stride
        }

        let library = makeLibrary(device, source: shaders)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipelineDescriptor.vertexDescriptor = layout
        pipeline = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)!
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        // Камера медленно ходит по кругу вокруг ряда фигур.
        let time = Float(CACurrentMediaTime() - start)
        let eye = SIMD3<Float>(7 * sin(time * 0.3), 3.2, 7 * cos(time * 0.3))
        let viewProjection = float4x4.perspective(fovY: .pi / 5, aspect: aspect, near: 0.1, far: 50)
            * float4x4.lookAt(eye: eye, target: [0, 0.6, 0])

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise) // Как в MeshData: лицевая сторона — против часовой.
        encoder.setFragmentTexture(wood, index: 0)

        func draw(_ mesh: GPUMesh, model: float4x4, tint: SIMD4<Float>, textured: Bool) {
            var uniforms = Uniforms(model: model, viewProjection: viewProjection, tint: tint,
                                    camera: SIMD4(eye, 1), textured: textured ? 1 : 0)
            encoder.setVertexBuffer(mesh.positions, offset: 0, index: 0)
            encoder.setVertexBuffer(mesh.normals, offset: 0, index: 1)
            encoder.setVertexBuffer(mesh.uvs, offset: 0, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 4)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 4)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32,
                                          indexBuffer: mesh.indices, indexBufferOffset: 0)
        }

        draw(plate, model: .translation([0, -0.05, 0]), tint: [0.36, 0.22, 0.13, 1], textured: false)
        for (i, piece) in pieces.enumerated() {
            // Чередуем светлое и тёмное дерево.
            let tint: SIMD4<Float> = i % 2 == 0 ? [0.95, 0.88, 0.74, 1] : [0.3, 0.2, 0.14, 1]
            draw(piece.mesh, model: .translation([piece.x, 0, 0]), tint: tint, textured: true)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = Float(size.width / max(size.height, 1))
    }
}

// Упражнения:
// 1. Поставьте stride 12 вместо MemoryLayout<SIMD3<Float>>.stride и посмотрите,
//    во что превратятся фигуры. Так выглядит ошибка выравнивания.
// 2. Замените PieceModels.mesh(for: kind) на mesh(for: kind, segments: 8).
// 3. Уберите mip_filter у сэмплера и отодвиньте камеру: текстура начнёт рябить.
// 4. Сделайте setFrontFacing(.clockwise) — останутся видны только внутренние стенки.

MainActor.assumeIsolated {
    runLesson(PiecesLesson.self, title: "Урок 5 — фигуры на Metal")
}
