// Урок 2. Шахматная доска одним вызовом draw.
//
// Новое:
// • Инстансинг. Один квадрат рисуется 64 раза одной командой: GPU сам
//   передаёт номер копии (instance_id), и шейдер по нему считает клетку.
//   Так рисуют траву, толпы, частицы — тысячи одинаковых объектов.
// • Вершины без буфера: углы квадрата шейдер вычисляет из vertex_id.
// • Uniforms — небольшие данные «на весь кадр» (время, номер клетки),
//   которые CPU передаёт шейдерам через setVertexBytes/setFragmentBytes.
// • Логика в шейдере: цвет клетки, подсветка и анимация считаются на GPU.
//
//   swift run Lesson2Board
import LessonKit
import Metal
import MetalKit
import QuartzCore

let shaders = """
#include <metal_stdlib>
using namespace metal;

// Совпадает со структурой Uniforms в Swift. Порядок и типы полей важны:
// GPU читает те же байты.
struct Uniforms {
    float time;
    int highlighted;   // номер подсвеченной клетки 0…63
    float aspect;      // ширина / высота окна, чтобы клетки были квадратными
};

struct Varyings {
    float4 position [[position]];
    float2 uv;          // координата внутри клетки, 0…1
    uint square [[flat]];   // [[flat]] — не смешивать между вершинами
};

vertex Varyings vertexMain(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           constant Uniforms &u [[buffer(0)]]) {
    // Два треугольника на квадрат: 6 вершин, углы берём из таблицы.
    const float2 corners[6] = { {0,0}, {1,0}, {0,1}, {0,1}, {1,0}, {1,1} };
    float2 corner = corners[vid];

    uint file = iid % 8;
    uint rank = iid / 8;
    // Доска занимает квадрат от -0.9 до 0.9; клетка — 1/8 его стороны.
    float2 p = (float2(file, rank) + corner) / 8.0 * 1.8 - 0.9;
    p.x /= max(u.aspect, 1.0);
    p.y *= min(u.aspect, 1.0);

    Varyings out;
    out.position = float4(p, 0, 1);
    out.uv = corner;
    out.square = iid;
    return out;
}

fragment float4 fragmentMain(Varyings in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]]) {
    uint file = in.square % 8;
    uint rank = in.square / 8;
    bool light = (file + rank) % 2 == 1;
    float3 color = light ? float3(0.93, 0.85, 0.71) : float3(0.71, 0.53, 0.39);

    if (int(in.square) == u.highlighted) {
        // Пульсирующая подсветка: sin от времени, от 0 до 1.
        float pulse = 0.5 + 0.5 * sin(u.time * 6.0);
        color = mix(color, float3(0.45, 0.8, 0.4), 0.4 + 0.4 * pulse);
    }

    // Мягкая тень к краю клетки — посчитана для каждого пикселя.
    float2 d = abs(in.uv - 0.5) * 2.0;
    color *= 1.0 - 0.15 * smoothstep(0.7, 1.0, max(d.x, d.y));
    return float4(color, 1);
}
"""

struct Uniforms {
    var time: Float
    var highlighted: Int32
    var aspect: Float
}

/// Обход доски конём: каждая клетка ровно один раз. Подсветка идёт по нему.
let knightTour: [Int32] = {
    var visited = Set<Int>(), path: [Int32] = [], square = 0
    let jumps = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    func next(_ s: Int) -> [Int] {
        jumps.compactMap { df, dr in
            let f = s % 8 + df, r = s / 8 + dr
            return (0..<8).contains(f) && (0..<8).contains(r) && !visited.contains(r * 8 + f) ? r * 8 + f : nil
        }
    }
    // Правило Варнсдорфа: идти туда, откуда меньше всего продолжений.
    for _ in 0..<64 {
        visited.insert(square)
        path.append(Int32(square))
        guard let best = next(square).min(by: { next($0).count < next($1).count }) else { break }
        square = best
    }
    return path
}()

@MainActor
final class BoardLesson: NSObject, @MainActor Lesson {
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    let start = CACurrentMediaTime()

    required init(view: MTKView) {
        let device = view.device!
        queue = device.makeCommandQueue()!
        let library = makeLibrary(device, source: shaders)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let time = Float(CACurrentMediaTime() - start)
        let size = view.drawableSize
        var uniforms = Uniforms(
            time: time,
            highlighted: knightTour[Int(time * 2) % knightTour.count],
            aspect: Float(size.width / size.height)
        )

        encoder.setRenderPipelineState(pipeline)
        // setVertexBytes копирует до 4 КБ прямо в команду — для uniforms
        // удобнее, чем заводить буфер.
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        // 6 вершин × 64 копии = вся доска одной командой.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 64)
        encoder.endEncoding()

        commands.present(drawable)
        commands.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// Упражнения:
// 1. Сделайте доску 10×10 (международные шашки): поменяйте 8 и 64.
// 2. Подсвечивайте клетку под курсором: в Swift переведите координату мыши
//    в номер клетки и передайте в Uniforms.highlighted.
// 3. Нарисуйте на клетках кружки: в fragmentMain по length(in.uv - 0.5)
//    решите, внутри круга пиксель или нет.
// 4. Попробуйте discard_fragment() для клеток с нечётным номером.

MainActor.assumeIsolated {
    runLesson(BoardLesson.self, title: "Урок 2 — доска одним вызовом")
}
