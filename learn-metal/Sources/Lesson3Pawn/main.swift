// Урок 3. Настоящее 3D: вращающаяся пешка со светом.
//
// Новое:
// • Матрицы model / view / projection. Вершина проходит три преобразования:
//   из координат фигуры в координаты мира (model), в координаты камеры (view),
//   на экран с перспективой (projection). Всё это — умножение на матрицы 4×4.
// • Буфер глубины. Без него GPU рисует треугольники в порядке команд, и задние
//   части фигуры налезают на передние. С ним каждый пиксель помнит расстояние
//   до камеры, и более далёкие пиксели отбрасываются.
// • Нормали и освещение по Ламберту: чем прямее свет падает на поверхность,
//   тем она ярче. Нормаль — вектор «наружу» из поверхности.
// • Model I/O: готовые сетки (цилиндр, сфера) вместо ручного списка вершин.
//   Так же грузятся модели из файлов (.usdz, .obj).
// • Vertex descriptor: GPU сам раскладывает вершину из буфера по полям
//   [[attribute(n)]], а шейдер получает её через [[stage_in]].
//
// RealityKit в игре делает всё это за нас — плюс тени, материалы и сцену.
//
//   swift run Lesson3Pawn
import LessonKit
import Metal
import MetalKit
import ModelIO
import QuartzCore

let shaders = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct Uniforms {
    float4x4 model;
    float4x4 viewProjection;
    float4 color;
};

struct Varyings {
    float4 position [[position]];
    float3 normal;     // в координатах мира
};

vertex Varyings vertexMain(VertexIn in [[stage_in]],
                           constant Uniforms &u [[buffer(1)]]) {
    Varyings out;
    float4 world = u.model * float4(in.position, 1);
    out.position = u.viewProjection * world;
    // w = 0: нормаль — направление, перенос к ней не применяется.
    out.normal = (u.model * float4(in.normal, 0)).xyz;
    return out;
}

fragment float4 fragmentMain(Varyings in [[stage_in]],
                             constant Uniforms &u [[buffer(1)]]) {
    float3 n = normalize(in.normal);     // после смешивания длина уже не 1
    float3 toLight = normalize(float3(0.6, 1.0, 0.8));
    float diffuse = max(dot(n, toLight), 0.0);
    float ambient = 0.18;
    return float4(u.color.rgb * (ambient + 0.82 * diffuse), 1);
}
"""

struct Uniforms {
    var model: float4x4
    var viewProjection: float4x4
    var color: SIMD4<Float>
}

/// Часть фигуры: сетка и где она стоит относительно основания.
struct Part {
    let mesh: MTKMesh
    let offset: SIMD3<Float>
    let color: SIMD4<Float>
}

@MainActor
final class PawnLesson: NSObject, @MainActor Lesson {
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    let depthState: any MTLDepthStencilState
    let parts: [Part]
    let start = CACurrentMediaTime()
    var aspect: Float = 1

    required init(view: MTKView) {
        let device = view.device!
        queue = device.makeCommandQueue()!
        view.depthStencilPixelFormat = .depth32Float   // MTKView заведёт текстуру глубины

        // Раскладка вершины: позиция (3 float), потом нормаль (3 float).
        let layout = MDLVertexDescriptor()
        layout.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        layout.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        layout.layouts[0] = MDLVertexBufferLayout(stride: 24)

        let allocator = MTKMeshBufferAllocator(device: device)
        func mesh(_ m: MDLMesh) -> MTKMesh {
            m.vertexDescriptor = layout   // перекладывает данные сетки под нашу раскладку
            return try! MTKMesh(mesh: m, device: device)
        }
        func cylinder(_ radius: Float, _ height: Float) -> MDLMesh {
            MDLMesh(cylinderWithExtent: [radius * 2, height, radius * 2], segments: [48, 1],
                    inwardNormals: false, topCap: true, bottomCap: true, geometryType: .triangles, allocator: allocator)
        }
        let ivory: SIMD4<Float> = [0.95, 0.9, 0.8, 1]
        parts = [
            Part(mesh: mesh(MDLMesh(boxWithExtent: [3, 0.2, 3], segments: [1, 1, 1], inwardNormals: false,
                                    geometryType: .triangles, allocator: allocator)),
                 offset: [0, -0.1, 0], color: [0.45, 0.3, 0.2, 1]),
            Part(mesh: mesh(cylinder(0.7, 0.25)), offset: [0, 0.125, 0], color: ivory),
            Part(mesh: mesh(cylinder(0.35, 0.9)), offset: [0, 0.7, 0], color: ivory),
            Part(mesh: mesh(cylinder(0.5, 0.1)), offset: [0, 1.15, 0], color: ivory),
            Part(mesh: mesh(MDLMesh(sphereWithExtent: [0.75, 0.75, 0.75], segments: [48, 48], inwardNormals: false,
                                    geometryType: .triangles, allocator: allocator)),
                 offset: [0, 1.5, 0], color: ivory),
        ]

        let library = makeLibrary(device, source: shaders)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        descriptor.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(layout)
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)

        // Тест глубины: рисовать пиксель, только если он ближе уже нарисованного.
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

        let time = Float(CACurrentMediaTime() - start)
        let projection = float4x4.perspective(fovY: .pi / 4, aspect: aspect, near: 0.1, far: 50)
        let camera = float4x4.lookAt(eye: [0, 3, 5], target: [0, 0.8, 0])
        let spin = float4x4.rotation(angle: time * 0.8, axis: [0, 1, 0])

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)   // задние стороны треугольников не видны, их можно не рисовать
        for part in parts {
            var uniforms = Uniforms(
                model: spin * .translation(part.offset),
                viewProjection: projection * camera,
                color: part.color
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            // Сетка Model I/O: вершины в своих буферах, индексы — в подсетках.
            for (i, buffer) in part.mesh.vertexBuffers.enumerated() {
                encoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: i)
            }
            for sub in part.mesh.submeshes {
                encoder.drawIndexedPrimitives(type: sub.primitiveType, indexCount: sub.indexCount,
                                              indexType: sub.indexType, indexBuffer: sub.indexBuffer.buffer,
                                              indexBufferOffset: sub.indexBuffer.offset)
            }
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
// 1. Закомментируйте encoder.setDepthStencilState — и посмотрите, как основание
//    просвечивает сквозь пешку.
// 2. Добавьте блик (модель Блинна — Фонга): pow(max(dot(n, normalize(toLight + toCamera)), 0), 32).
//    Для этого передайте в Uniforms позицию камеры.
// 3. Поставьте на доску вторую пешку, тёмную, — ещё один набор parts со сдвигом.
// 4. Загрузите модель из файла: MDLAsset(url:vertexDescriptor:bufferAllocator:)
//    и MTKMesh.newMeshes(asset:device:).

MainActor.assumeIsolated {
    runLesson(PawnLesson.self, title: "Урок 3 — пешка в 3D")
}
