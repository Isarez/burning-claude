#!/usr/bin/env swift
//
// Draws the Burning Claude app icon and writes an .icns.
//
//   swift Tools/MakeIcon.swift Resources/AppIcon.icns
//
// Vector rather than a checked-in PNG, and re-rendered natively at every size
// rather than downsampled from 1024, so the 16pt Finder icon stays crisp
// instead of turning to mush. Needs nothing but the Command Line Tools:
// CoreGraphics draws it, `iconutil` packs it.
//
// The mark is a flame with a radial burst at its heart — fire for the meter,
// the burst for what is being metered.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let backdropTop = rgb(0x3A241C)
let backdropBottom = rgb(0x150E0C)
let emberGlow = rgb(0xFF8A3D, 0.45)
let emberFade = rgb(0xFF8A3D, 0)
// Weighted so the pale, hottest tones stay in the bottom fifth. The burst sits
// in the belly, and a cream mark on pale yellow has no contrast left.
let flameStops: [(CGFloat, CGColor)] = [
    (0.00, rgb(0xFFC978)),   // hot core at the base
    (0.20, rgb(0xF2A063)),
    (0.55, rgb(0xE08355)),
    (0.82, rgb(0xD97757)),   // Claude orange through the body
    (1.00, rgb(0xC24E2C)),   // cooling at the tip
]
let markColor = rgb(0xFFFFFF)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: space,
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

// MARK: - The flame silhouette

/// A prepared silhouette: the shape itself, plus where its ink actually sits
/// inside the image, in unit coordinates measured top-down.
struct Silhouette {
    var image: CGImage
    var ink: CGRect
    /// Width-to-height ratio of the ink alone, for laying it out undistorted.
    var inkAspect: CGFloat {
        (ink.width * CGFloat(image.width)) / (ink.height * CGFloat(image.height))
    }
}

/// Measures where an image's ink actually sits, optionally closing any holes
/// enclosed by it.
///
/// Both halves earn their keep. Artwork arrives padded — SF Symbols by
/// different amounts on each side — so centring the *image* centres the
/// padding rather than the mark. And `flame.fill` is not solid: it carries a
/// flame-shaped cutout in its belly, which let the dark backdrop through and
/// read as a smudge behind the Claude mark.
///
/// Holes are found by flooding inward from the border: transparent pixels the
/// flood cannot reach are enclosed, so they are interior. That closes the belly
/// while keeping the notch under the flame's tip, which is open to the outside
/// and genuinely part of the outline.
func silhouette(_ symbol: CGImage, width w: Int, fillHoles: Bool = false) -> Silhouette {
    let h = Int((CGFloat(w) * CGFloat(symbol.height) / CGFloat(symbol.width)).rounded())
    var buffer = [UInt8](repeating: 0, count: w * h * 4)

    let result: Silhouette = buffer.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(symbol, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = raw.bindMemory(to: UInt8.self)

        if fillHoles {
            var exterior = [Bool](repeating: false, count: w * h)
            var queue: [Int] = []
            queue.reserveCapacity(w * h / 4)
            func flood(_ i: Int) {
                guard !exterior[i], px[i * 4 + 3] < 8 else { return }
                exterior[i] = true
                queue.append(i)
            }
            for x in 0..<w { flood(x); flood((h - 1) * w + x) }
            for y in 0..<h { flood(y * w); flood(y * w + w - 1) }
            var head = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % w, y = i / w
                if x > 0 { flood(i - 1) }
                if x < w - 1 { flood(i + 1) }
                if y > 0 { flood(i - w) }
                if y < h - 1 { flood(i + w) }
            }
            for i in 0..<(w * h) where !exterior[i] && px[i * 4 + 3] < 255 {
                px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 255
            }
        }

        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // A bitmap context's first row is the top of the image, so these bounds
        // are top-down; `place` below converts.
        let ink = CGRect(
            x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
            width: CGFloat(maxX - minX + 1) / CGFloat(w),
            height: CGFloat(maxY - minY + 1) / CGFloat(h)
        )
        return Silhouette(image: ctx.makeImage()!, ink: ink)
    }
    return result
}

let flame: Silhouette = {
    let config = NSImage.SymbolConfiguration(pointSize: 720, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config),
        let image = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        FileHandle.standardError.write("flame.fill unavailable\n".data(using: .utf8)!)
        exit(1)
    }
    // The same SF Symbol `StatusBarView` draws in the menu bar, so the icon and
    // the status item are recognisably one mark rather than two similar ones.
    return silhouette(image, width: 900, fillHoles: true)
}()

/// The Claude mark, from `Resources/claude.svg`.
///
/// AppKit rasterises SVG itself, so the real artwork goes in rather than an
/// approximation of it drawn in bezier curves. The file paints `currentColor`,
/// which resolves to black — it is used for its alpha alone and tinted below.
let claudeMark: Silhouette = {
    let url = URL(fileURLWithPath: "Resources/claude.svg")
    guard let svg = NSImage(contentsOf: url) else {
        FileHandle.standardError.write("cannot read \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    // An SVG rep reports a 1×1 size; it has to be told how big to rasterise.
    svg.size = NSSize(width: 1024, height: 1024)
    guard let image = svg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("cannot rasterise \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    return silhouette(image, width: 1024)
}()

/// Where the flame's *ink* lands in the 1024 design grid — its natural
/// proportions preserved, centred, and sitting a little high so the burst can
/// occupy the belly without crowding the plate's bottom edge.
let flameInk: CGRect = {
    let height: CGFloat = 664
    let width = height * flame.inkAspect
    return CGRect(x: 512 - width / 2, y: 512 - height / 2 - 4, width: width, height: height)
}()

/// Where the whole padded symbol goes so its ink lands on `flameInk`.
let flameRect: CGRect = {
    let width = flameInk.width / flame.ink.width
    let height = flameInk.height / flame.ink.height
    return CGRect(
        x: flameInk.minX - flame.ink.minX * width,
        y: flameInk.minY - (1 - flame.ink.maxY) * height,
        width: width, height: height
    )
}()

/// Where the Claude mark's ink lands: the middle of the fire.
///
/// Sized against the flame's width and dropped below the flame's bounding-box
/// centre, because a flame's mass is at the bottom and its tip curls off to one
/// side — a geometric centre rides high and reads off-axis.
let markInk: CGRect = {
    // Generous, because the mark's rays are fine: sized to the flame's belly
    // rather than politely inside it, or it reads as spindly at any size and
    // disappears entirely at 16pt.
    let width = flameInk.width * 0.60
    let height = width / claudeMark.inkAspect
    return CGRect(
        x: flameInk.midX - width / 2,
        y: flameInk.minY + flameInk.height * 0.34 - height / 2,
        width: width, height: height
    )
}()

/// Where to draw the whole padded mark so its ink lands on `markInk`.
let markRect: CGRect = {
    let width = markInk.width / claudeMark.ink.width
    let height = markInk.height / claudeMark.ink.height
    return CGRect(
        x: markInk.minX - claudeMark.ink.minX * width,
        y: markInk.minY - (1 - claudeMark.ink.maxY) * height,
        width: width, height: height
    )
}()

// MARK: - Render

func render(size: CGFloat) -> CGImage {
    let px = Int(size)
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    // Everything below is written in a 1024 design grid.
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Rounded-square plate, inset the way macOS icons are.
    let plate = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 185, cornerHeight: 185, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, backdropBottom), (1, backdropTop)]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: []
    )

    // Heat haze behind the flame. Pure decoration, and at 32pt and below it
    // only muddies the silhouette, so it is dropped there.
    if size >= 64 {
        ctx.drawRadialGradient(
            gradient([(0, emberGlow), (1, emberFade)]),
            startCenter: CGPoint(x: 512, y: 545), startRadius: 0,
            endCenter: CGPoint(x: 512, y: 545), endRadius: 430, options: []
        )
    }
    ctx.restoreGState()

    // Flame. The silhouette is laid down for its alpha alone, then `sourceIn`
    // replaces it with the gradient wherever that alpha is.
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.draw(flame.image, in: flameRect)
    ctx.setBlendMode(.sourceIn)
    ctx.drawLinearGradient(
        gradient(flameStops),
        start: CGPoint(x: 512, y: flameInk.minY),
        end: CGPoint(x: 512, y: flameInk.maxY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // The Claude mark, in the middle of the fire. Same trick as the flame: the
    // artwork is laid down for its alpha, then `sourceIn` paints it white.
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.draw(claudeMark.image, in: markRect)
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(markColor)
    ctx.fill(markRect)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // A hairline lip along the plate edge, which keeps the icon from looking
    // pasted onto a dark Dock.
    ctx.addPath(plate)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MakeIcon", code: 1)
    }
    try data.write(to: url)
}

// MARK: - Main

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.icns")

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("BurningClaude.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// Every slot `iconutil` expects, each drawn at its true pixel size.
let slots: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for slot in slots {
    try writePNG(render(size: slot.size), to: iconset.appendingPathComponent("\(slot.name).png"))
}

try? fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

// A 1024 preview alongside the .icns, for looking at without mounting it in a
// bundle first.
try writePNG(render(size: 1024), to: output.deletingPathExtension().appendingPathExtension("png"))
try? fm.removeItem(at: iconset)
print("Wrote \(output.path)")
