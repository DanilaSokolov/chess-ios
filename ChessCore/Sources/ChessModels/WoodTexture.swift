import Foundation

/// A wood grain texture computed from formulas instead of loaded from a file
/// ("procedural texture"). Grey, so one image serves both colors: the
/// material tints it ivory or ebony.
///
/// The grain runs along v, the way a turned piece's grain runs up the lathe
/// axis, and the image tiles seamlessly: the right edge continues into the
/// left, the top into the bottom.
public enum WoodTexture {
    /// RGBA bytes, `size × size` pixels, row by row from the top.
    public static func pixels(size: Int = 512) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let u = Float(x) / Float(size)
                let v = Float(y) / Float(size)
                let value = shade(u, v)
                let byte = UInt8((value * 255).rounded())
                let i = (y * size + x) * 4
                bytes[i] = byte
                bytes[i + 1] = byte
                bytes[i + 2] = byte
            }
        }
        return bytes
    }

    /// Brightness 0…1 at texture coordinates u, v in 0…1.
    static func shade(_ u: Float, _ v: Float) -> Float {
        let tau = 2 * Float.pi
        // Stripes across u, gently waving along v and wobbled by noise, so
        // they look like grain instead of a barcode. Whole numbers of waves
        // per image keep it seamless.
        let wobble = 0.35 * sin(tau * (2 * v + u)) + 1.2 * noise(u * 6, v * 3, period: (6, 3))
        let stripes = 0.5 + 0.5 * sin(tau * (6 * u + 0.3 * wobble))
        let line = pow(stripes, 4)  // Narrow dark lines, wide light wood.
        let fine = noise(u * 64, v * 8, period: (64, 8))  // Fine fibres.
        return min(1, max(0, 0.86 - 0.14 * line + 0.06 * (fine - 0.5)))
    }

    /// Smooth random values in 0…1 on a grid, blended between grid points
    /// ("value noise"). The grid wraps after `period` cells, so the noise tiles.
    static func noise(_ x: Float, _ y: Float, period: (Int, Int)) -> Float {
        func random(_ i: Int, _ j: Int) -> Float {
            let (i, j) = (((i % period.0) + period.0) % period.0, ((j % period.1) + period.1) % period.1)
            var h = UInt32(truncatingIfNeeded: i &* 374_761_393 &+ j &* 668_265_263)
            h = (h ^ (h >> 13)) &* 1_274_126_177
            return Float(h & 0xFFFF) / 65535
        }
        let (i, j) = (Int(x.rounded(.down)), Int(y.rounded(.down)))
        let (fx, fy) = (x - Float(i), y - Float(j))
        let (sx, sy) = (fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy))  // Smoothstep: no visible grid.
        let top = random(i, j) + (random(i + 1, j) - random(i, j)) * sx
        let bottom = random(i, j + 1) + (random(i + 1, j + 1) - random(i, j + 1)) * sx
        return top + (bottom - top) * sy
    }
}
