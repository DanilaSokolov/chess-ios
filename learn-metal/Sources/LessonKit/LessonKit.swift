// Общий код уроков: окно с MTKView и математика матриц. Сам Metal — в уроках.
import AppKit
import Metal
import MetalKit
import simd

/// Урок рисует кадр в `draw(in:)`. MTKView вызывает его 60 раз в секунду.
@MainActor
public protocol Lesson: MTKViewDelegate {
    init(view: MTKView)
}

/// Открывает окно с MTKView и отдаёт его уроку. Возвращается, когда окно закрыто.
@MainActor
public func runLesson<L: Lesson>(_ type: L.Type, title: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    // MTLDevice — это видеокарта. На Mac с Apple Silicon она одна и встроена в чип.
    guard let device = MTLCreateSystemDefaultDevice() else {
        fatalError("Metal недоступен на этом компьютере")
    }
    print("GPU: \(device.name)")

    let view = MTKView(frame: NSRect(x: 0, y: 0, width: 720, height: 720), device: device)
    view.clearColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
    let lesson = L(view: view)
    view.delegate = lesson

    let window = NSWindow(
        contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered, defer: false
    )
    window.title = title
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)

    let closer = WindowCloser()
    window.delegate = closer
    app.activate()
    withExtendedLifetime((lesson, closer)) { app.run() }
}

private final class WindowCloser: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }
}

/// Собирает шейдеры из исходного текста во время запуска. В обычном проекте
/// Xcode компилирует файлы .metal при сборке; здесь так проще: весь урок
/// в одном файле, и шейдер можно править рядом с кодом, который его вызывает.
public func makeLibrary(_ device: any MTLDevice, source: String) -> any MTLLibrary {
    do {
        return try device.makeLibrary(source: source, options: nil)
    } catch {
        fatalError("Шейдер не собрался:\n\(error)")
    }
}

// MARK: - Матрицы

// Metal, как и OpenGL, работает с матрицами 4×4 по столбцам. simd хранит их
// так же, поэтому структуры можно копировать в буферы GPU как есть.

public extension float4x4 {
    static let identity = matrix_identity_float4x4

    /// Перспектива: дальние предметы меньше. Глубина в Metal — от 0 до 1.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovY / 2)
        let x = y / aspect
        let z = far / (near - far)
        return float4x4(columns: (
            [x, 0, 0, 0],
            [0, y, 0, 0],
            [0, 0, z, -1],
            [0, 0, z * near, 0]
        ))
    }

    /// Камера в точке `eye` смотрит на `target`.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = [0, 1, 0]) -> float4x4 {
        let z = normalize(eye - target)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return float4x4(columns: (
            [x.x, y.x, z.x, 0],
            [x.y, y.y, z.y, 0],
            [x.z, y.z, z.z, 0],
            [-dot(x, eye), -dot(y, eye), -dot(z, eye), 1]
        ))
    }

    static func rotation(angle: Float, axis: SIMD3<Float>) -> float4x4 {
        float4x4(simd_quatf(angle: angle, axis: normalize(axis)))
    }

    static func translation(_ t: SIMD3<Float>) -> float4x4 {
        var m = identity
        m.columns.3 = [t.x, t.y, t.z, 1]
        return m
    }
}
