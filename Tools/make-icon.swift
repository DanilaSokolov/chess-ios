#!/usr/bin/env swift
// Draws the app icon: the knight from the splash screen (♞) on a walnut
// board, and writes every PNG the AppIcon set needs.
//
//   swift Tools/make-icon.swift            (from apple/)
//
// Nothing here is a bitmap made by hand: the knight is the outline of a font
// glyph (CoreText gives it as a vector path), the rest is gradients and
// rectangles, so every size is drawn sharp, not scaled down from 1024.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: "ChessApp/Assets.xcassets/AppIcon.appiconset")

// MARK: - Colours

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// One look of the icon. iOS 18 asks for three: the usual one, a dark one
/// (shown with the dark Home Screen) and a grey one it tints itself.
struct Palette {
    var background: (top: CGColor, bottom: CGColor)?  // nil: transparent (dark mode draws its own)
    var squares: CGColor  // the faint board pattern
    var knight: (top: CGColor, bottom: CGColor)
    var shadow: CGColor
}

let light = Palette(
    background: (rgb(0x8A5A34), rgb(0x3B2213)),  // walnut, as the 3D board's frame
    squares: rgb(0xFFFFFF, 0.07),
    knight: (rgb(0xFBF3E2), rgb(0xE2CBA0)),  // the cream of the light squares
    shadow: rgb(0x000000, 0.45))

let dark = Palette(
    background: nil,
    squares: rgb(0xFFFFFF, 0.05),
    knight: (rgb(0xF2C88A), rgb(0xC98E4E)),  // warm gold reads well on the black backdrop
    shadow: rgb(0x000000, 0.6))

let tinted = Palette(
    background: (rgb(0x000000), rgb(0x000000)),  // iOS wants grey on black and colours it
    squares: rgb(0xFFFFFF, 0.06),
    knight: (rgb(0xFFFFFF), rgb(0xB0B0B0)),
    shadow: rgb(0x000000, 0))

// MARK: - The knight

/// The ♞ glyph as a path, scaled to fit `box` and centred in it. "Apple
/// Symbols" has well-drawn chess pieces; the black knight is a filled
/// silhouette whose eye and mane are holes, which is what an icon wants.
func knightPath(in box: CGRect) -> CGPath {
    let font = CTFontCreateWithName("Apple Symbols" as CFString, 1000, nil)
    var character: [UniChar] = Array("\u{265E}".utf16)
    var glyph = CGGlyph(0)
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
        let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil)
    else { fatalError("no ♞ in Apple Symbols") }

    let bounds = glyphPath.boundingBoxOfPath
    let scale = min(box.width / bounds.width, box.height / bounds.height)
    var transform = CGAffineTransform.identity
        .translatedBy(x: box.midX, y: box.midY)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -bounds.midX, y: -bounds.midY)
    return glyphPath.copy(using: &transform)!
}

// MARK: - Drawing

/// Draws the icon into a square of `side` points. `body` is where the art
/// goes: the whole square on iOS (the system rounds the corners itself), a
/// smaller rounded square on macOS (Mac icons bring their own shape).
func draw(_ c: CGContext, side: CGFloat, palette: Palette, mac: Bool) {
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    // Apple's Mac icon grid: an 824/1024 body with 185/1024 corners.
    let body = mac ? canvas.insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024) : canvas
    let shape = CGPath(
        roundedRect: body, cornerWidth: mac ? side * 185 / 1024 : 0,
        cornerHeight: mac ? side * 185 / 1024 : 0, transform: nil)

    if mac {  // The Mac icon's own drop shadow under the body.
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -side * 10 / 1024), blur: side * 28 / 1024,
                    color: rgb(0x000000, 0.35))
        c.addPath(shape)
        c.setFillColor(rgb(0x3B2213))
        c.fillPath()
        c.restoreGState()
    }

    c.saveGState()
    c.addPath(shape)
    c.clip()

    // Background: a vertical gradient, light from above.
    if let background = palette.background {
        let gradient = CGGradient(
            colorsSpace: nil, colors: [background.top, background.bottom] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(
            gradient, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY),
            options: [])
    }

    // A faint 4×4 board behind the knight: says "chess" without competing with it.
    let square = body.width / 4
    c.setFillColor(palette.squares)
    for row in 0..<4 {
        for column in 0..<4 where (row + column) % 2 == 0 {
            c.fill(CGRect(x: body.minX + CGFloat(column) * square, y: body.minY + CGFloat(row) * square,
                          width: square, height: square))
        }
    }

    // The knight, a little above centre (the eye expects weight to sit low,
    // so a centred figure looks like it is sinking).
    let knightBox = CGRect(
        x: body.minX + body.width * 0.19, y: body.minY + body.height * 0.15,
        width: body.width * 0.62, height: body.height * 0.68)
    let knight = knightPath(in: knightBox)

    c.saveGState()  // Shadow first, as its own fill: a gradient fill casts none.
    c.setShadow(offset: CGSize(width: 0, height: -body.width * 0.02), blur: body.width * 0.05,
                color: palette.shadow)
    c.addPath(knight)
    c.setFillColor(palette.knight.bottom)
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(knight)
    c.clip()
    let shine = CGGradient(
        colorsSpace: nil, colors: [palette.knight.top, palette.knight.bottom] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(
        shine, start: CGPoint(x: knightBox.midX, y: knightBox.maxY),
        end: CGPoint(x: knightBox.midX, y: knightBox.minY), options: [])
    c.restoreGState()

    c.restoreGState()
}

func render(pixels: Int, palette: Palette, mac: Bool, opaque: Bool, to name: String) throws {
    let c = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        // The App Store rejects an iOS icon with an alpha channel: drop it when the art is opaque.
        bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    draw(c, side: CGFloat(pixels), palette: palette, mac: mac)

    let url = output.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

// MARK: - The icon set

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var images: [[String: Any]] = []

// iOS and iPadOS: one 1024 image per appearance; Xcode makes the other sizes.
try render(pixels: 1024, palette: light, mac: false, opaque: true, to: "ios.png")
try render(pixels: 1024, palette: dark, mac: false, opaque: false, to: "ios-dark.png")
try render(pixels: 1024, palette: tinted, mac: false, opaque: true, to: "ios-tinted.png")
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios.png"])
images.append([
    "idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-dark.png",
    "appearances": [["appearance": "luminosity", "value": "dark"]],
])
images.append([
    "idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-tinted.png",
    "appearances": [["appearance": "luminosity", "value": "tinted"]],
])

// macOS: every size drawn on its own, at 1x and 2x.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(points)@\(scale)x.png"
        try render(pixels: points * scale, palette: light, mac: true, opaque: false, to: name)
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))

let catalog = output.deletingLastPathComponent().appendingPathComponent("Contents.json")
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.data(using: .utf8)!.write(to: catalog)

print("wrote \(images.count) images to \(output.path)")
