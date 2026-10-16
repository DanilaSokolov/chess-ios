// Урок 4. Вычисления на GPU (compute) без окна.
//
// GPU — это тысячи простых ядер. Им выгодно давать одинаковую работу над
// большим количеством данных: каждый пиксель, каждый элемент массива.
// Compute-шейдер (kernel) не рисует треугольники: он запускается на сетке
// потоков, и каждый поток знает свою позицию в ней.
//
// Здесь GPU строит фрактал Мандельброта 2048×2048 — 4 млн независимых
// пикселей — и сохраняет его в mandelbrot.png. Для сравнения то же самое
// считает CPU в один поток.
//
//   swift run -c release Lesson4Compute
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

let size = 2048
let maxIterations: Int32 = 500

let source = """
#include <metal_stdlib>
using namespace metal;

// gid — координата потока в сетке; одна координата = один пиксель.
kernel void mandelbrot(texture2d<float, access::write> out [[texture(0)]],
                       constant int &maxIterations [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;

    float2 c = (float2(gid) / float2(out.get_width(), out.get_height())) * 3.0 - float2(2.2, 1.5);
    float2 z = 0;
    int i = 0;
    for (; i < maxIterations && dot(z, z) < 4.0; i++) {
        z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
    }
    float t = float(i) / float(maxIterations);
    // Палитра «дерево доски»: от тёмного к светлому.
    float3 color = i == maxIterations ? float3(0.08) : mix(float3(0.36, 0.22, 0.13), float3(0.95, 0.88, 0.74), sqrt(t));
    out.write(float4(color, 1), gid);
}
"""

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("Metal недоступен")
}
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "mandelbrot")!)

// Текстура — картинка в памяти GPU. shaderWrite: в неё будет писать kernel.
let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false
)
textureDescriptor.usage = [.shaderWrite]
textureDescriptor.storageMode = .shared   // общая память: CPU сможет прочитать результат
let texture = device.makeTexture(descriptor: textureDescriptor)!

// Потоки объединяются в группы (threadgroups), которые выполняются вместе.
// Размер группы подбирается под железо: ширина SIMD-блока × сколько влезет.
let width = pipeline.threadExecutionWidth
let height = pipeline.maxTotalThreadsPerThreadgroup / width
let threadsPerGroup = MTLSize(width: width, height: height, depth: 1)
print("GPU: \(device.name), группа потоков \(width)×\(height)")

let gpuStart = Date()
let commands = queue.makeCommandBuffer()!
let encoder = commands.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setTexture(texture, index: 0)
var iterations = maxIterations
encoder.setBytes(&iterations, length: MemoryLayout<Int32>.size, index: 0)
// Сетка ровно по размеру картинки; лишние потоки на краях GPU не запустит.
encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1), threadsPerThreadgroup: threadsPerGroup)
encoder.endEncoding()
commands.commit()
commands.waitUntilCompleted()   // здесь CPU ждёт GPU — в окне так не делают
let gpuTime = Date().timeIntervalSince(gpuStart)

// То же на CPU, в одном потоке, для сравнения.
let cpuStart = Date()
var inside = 0
for y in 0..<size {
    for x in 0..<size {
        let cx = Float(x) / Float(size) * 3 - 2.2, cy = Float(y) / Float(size) * 3 - 1.5
        var zx: Float = 0, zy: Float = 0, i: Int32 = 0
        while i < maxIterations, zx * zx + zy * zy < 4 {
            (zx, zy) = (zx * zx - zy * zy + cx, 2 * zx * zy + cy)
            i += 1
        }
        if i == maxIterations { inside += 1 }
    }
}
let cpuTime = Date().timeIntervalSince(cpuStart)
print(String(format: "GPU: %.3f с, CPU (1 поток): %.3f с — быстрее в %.0f раз", gpuTime, cpuTime, cpuTime / gpuTime))

// Читаем пиксели из текстуры и сохраняем PNG.
var pixels = [UInt8](repeating: 0, count: size * size * 4)
texture.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
let image = pixels.withUnsafeMutableBytes { raw in
    CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}
let url = URL(fileURLWithPath: "mandelbrot.png")
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("Сохранено: \(url.path)")

// Упражнения:
// 1. Поменяйте maxIterations на 2000 и сравните, как растёт время GPU и CPU.
// 2. Приблизьте участок фрактала: поменяйте формулу c в kernel.
// 3. Посчитайте на GPU сумму большого массива. Подсказка: atomic_fetch_add_explicit
//    или редукция внутри группы через threadgroup-память.
