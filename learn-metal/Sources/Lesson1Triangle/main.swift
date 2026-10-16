// Урок 1. Треугольник.
//
// Минимальная программа на Metal. Всё, что рисует GPU, проходит один и тот же путь:
//
//   вершины (буфер) → вершинный шейдер → растеризация → фрагментный шейдер → пиксели
//
// Вершинный шейдер решает, ГДЕ на экране вершина. Растеризатор (железо GPU, его
// не программируют) находит все пиксели внутри треугольника. Фрагментный шейдер
// решает, какого ЦВЕТА каждый пиксель. Цвета вершин GPU сам плавно смешивает
// между ними, поэтому треугольник получается радужным.
//
//   swift run Lesson1Triangle
import LessonKit
import Metal
import MetalKit

// Шейдеры пишутся на Metal Shading Language — это C++ с расширениями.
let shaders = """
#include <metal_stdlib>
using namespace metal;

// Как вершина лежит в буфере. Должно совпадать со структурой Vertex в Swift ниже.
struct Vertex {
    float2 position;   // x, y от -1 до 1: так GPU измеряет экран («clip space»)
    float4 color;
};

// Что вершинный шейдер передаёт дальше. [[position]] — обязательное поле:
// координата вершины на экране.
struct Varyings {
    float4 position [[position]];
    float4 color;
};

// Вызывается по разу на каждую вершину, параллельно.
// vertex_id — номер вершины, buffer(0) — буфер, который мы привяжем в Swift.
vertex Varyings vertexMain(uint vid [[vertex_id]],
                           constant Vertex *vertices [[buffer(0)]]) {
    Varyings out;
    out.position = float4(vertices[vid].position, 0, 1);
    out.color = vertices[vid].color;
    return out;
}

// Вызывается по разу на каждый пиксель треугольника. Получает Varyings,
// уже смешанные между тремя вершинами.
fragment float4 fragmentMain(Varyings in [[stage_in]]) {
    return in.color;
}
"""

struct Vertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

@MainActor
final class TriangleLesson: NSObject, @MainActor Lesson {
    // Очередь команд создаётся один раз. Через неё CPU отправляет работу GPU.
    let queue: any MTLCommandQueue
    // Состояние конвейера: какие шейдеры и в каком формате пиксели. Собирать
    // его дорого, поэтому тоже один раз, а не каждый кадр.
    let pipeline: any MTLRenderPipelineState
    let vertices: any MTLBuffer

    required init(view: MTKView) {
        let device = view.device!
        queue = device.makeCommandQueue()!

        let library = makeLibrary(device, source: shaders)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)

        // Буфер — участок памяти, который видит GPU. На Apple Silicon память
        // общая у CPU и GPU, поэтому копирования нет: GPU читает те же байты.
        let triangle: [Vertex] = [
            Vertex(position: [0, 0.7], color: [1, 0.3, 0.3, 1]),
            Vertex(position: [-0.7, -0.6], color: [0.3, 1, 0.4, 1]),
            Vertex(position: [0.7, -0.6], color: [0.3, 0.5, 1, 1]),
        ]
        vertices = device.makeBuffer(bytes: triangle, length: MemoryLayout<Vertex>.stride * triangle.count)!
    }

    func draw(in view: MTKView) {
        // Кадр: буфер команд → кодировщик → команды → отправка.
        guard let pass = view.currentRenderPassDescriptor,   // куда рисовать (текстура окна)
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)   // index 0 = [[buffer(0)]] в шейдере
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commands.present(drawable)   // показать результат, когда GPU закончит
        commands.commit()            // отправить работу на GPU; CPU не ждёт
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// Упражнения:
// 1. Поменяйте цвета вершин. Что будет, если у всех трёх один цвет?
// 2. Добавьте ещё три вершины и нарисуйте второй треугольник (vertexCount: 6).
// 3. Во фрагментном шейдере верните float4(1) - in.color — получится негатив.
// 4. Нарисуйте .line вместо .triangle и посмотрите, как меняется смысл тех же вершин.

MainActor.assumeIsolated {
    runLesson(TriangleLesson.self, title: "Урок 1 — треугольник")
}
