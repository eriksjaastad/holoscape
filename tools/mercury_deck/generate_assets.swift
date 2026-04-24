#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

let logicalWidth: CGFloat = 1000
let logicalHeight: CGFloat = 700
let scale: CGFloat = 2

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let skinDir = repoRoot
    .appendingPathComponent("Sources/Holoscape/Resources/Skins/MercuryDeck")
let assetsDir = skinDir.appendingPathComponent("assets")

func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    let scanner = Scanner(string: hex)
    _ = scanner.scanString("#")
    var value: UInt64 = 0
    scanner.scanHexInt64(&value)
    let r = CGFloat((value >> 16) & 0xff) / 255
    let g = CGFloat((value >> 8) & 0xff) / 255
    let b = CGFloat(value & 0xff) / 255
    return CGColor(red: r, green: g, blue: b, alpha: alpha)
}

func path(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
}

func fillRounded(
    _ ctx: CGContext,
    _ rect: CGRect,
    radius: CGFloat,
    fill: CGColor,
    stroke: CGColor? = nil,
    lineWidth: CGFloat = 1
) {
    let rounded = path(rect, radius: radius)
    ctx.addPath(rounded)
    ctx.setFillColor(fill)
    ctx.fillPath()

    if let stroke {
        ctx.addPath(rounded)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
    }
}

func strokeLine(
    _ ctx: CGContext,
    from start: CGPoint,
    to end: CGPoint,
    color: CGColor,
    width: CGFloat = 1
) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.move(to: start)
    ctx.addLine(to: end)
    ctx.strokePath()
}

func fillGradient(
    _ ctx: CGContext,
    rect: CGRect,
    radius: CGFloat,
    top: CGColor,
    bottom: CGColor
) {
    let colors = [top, bottom] as CFArray
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.addPath(path(rect, radius: radius))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.maxY),
        options: []
    )
    ctx.restoreGState()
}

func drawBrushedLines(
    _ ctx: CGContext,
    rect: CGRect,
    step: CGFloat,
    light: Bool
) {
    let lineColor = light
        ? color("#ffffff", alpha: 0.035)
        : color("#000000", alpha: 0.11)
    var y = rect.minY + 4
    while y < rect.maxY - 3 {
        strokeLine(
            ctx,
            from: CGPoint(x: rect.minX + 10, y: y),
            to: CGPoint(x: rect.maxX - 10, y: y),
            color: lineColor,
            width: 0.6
        )
        y += step
    }
}

func drawLedRow(_ ctx: CGContext, start: CGPoint, count: Int) {
    for index in 0..<count {
        let x = start.x + CGFloat(index) * 10
        let state = index > 9 ? "#ffb347" : "#6fa6c5"
        fillRounded(
            ctx,
            CGRect(x: x, y: start.y, width: 6, height: 6),
            radius: 3,
            fill: color(state, alpha: 0.84),
            stroke: color("#071014", alpha: 0.85),
            lineWidth: 0.8
        )
    }
}

func renderChrome(opaque: Bool) throws -> NSBitmapImageRep {
    let pixelWidth = Int(logicalWidth * scale)
    let pixelHeight = Int(logicalHeight * scale)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let nsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MercuryDeckGenerator", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    let ctx = nsContext.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: logicalHeight)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let shadowAlpha: CGFloat = opaque ? 0.5 : 0.36
    let metalAlpha: CGFloat = opaque ? 1 : 0.96
    let glassAlpha: CGFloat = opaque ? 1 : 0.92

    let leftBody = CGRect(x: 4, y: 58, width: 242, height: 618)
    let mainBody = CGRect(x: 282, y: 8, width: 712, height: 684)
    let terminalCavity = CGRect(x: 302, y: 82, width: 672, height: 500)
    let inputDeck = CGRect(x: 302, y: 596, width: 672, height: 76)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: 12),
        blur: 22,
        color: color("#000000", alpha: shadowAlpha)
    )
    fillRounded(ctx, leftBody, radius: 24, fill: color("#1d252a", alpha: metalAlpha))
    fillRounded(ctx, mainBody, radius: 24, fill: color("#2e363b", alpha: metalAlpha))
    ctx.restoreGState()

    fillGradient(
        ctx,
        rect: leftBody,
        radius: 24,
        top: color("#515b62", alpha: metalAlpha),
        bottom: color("#252d32", alpha: metalAlpha)
    )
    fillGradient(
        ctx,
        rect: mainBody,
        radius: 24,
        top: color("#8d989d", alpha: metalAlpha),
        bottom: color("#30383d", alpha: metalAlpha)
    )

    fillRounded(
        ctx,
        leftBody.insetBy(dx: 1.5, dy: 1.5),
        radius: 22,
        fill: color("#000000", alpha: 0),
        stroke: color("#aab3b8", alpha: 0.48),
        lineWidth: 1
    )
    fillRounded(
        ctx,
        mainBody.insetBy(dx: 1.5, dy: 1.5),
        radius: 22,
        fill: color("#000000", alpha: 0),
        stroke: color("#c0c8cc", alpha: 0.5),
        lineWidth: 1
    )

    drawBrushedLines(ctx, rect: leftBody.insetBy(dx: 8, dy: 8), step: 3, light: false)
    drawBrushedLines(ctx, rect: mainBody.insetBy(dx: 10, dy: 10), step: 3, light: false)

    let leftTop = CGRect(x: 18, y: 72, width: 214, height: 40)
    fillRounded(
        ctx,
        leftTop,
        radius: 12,
        fill: color("#313b41", alpha: glassAlpha),
        stroke: color("#7e8a91", alpha: 0.58),
        lineWidth: 1
    )
    strokeLine(
        ctx,
        from: CGPoint(x: leftTop.minX + 12, y: leftTop.maxY - 8),
        to: CGPoint(x: leftTop.maxX - 36, y: leftTop.maxY - 8),
        color: color("#ffb347", alpha: 0.7),
        width: 1.2
    )

    let navCavity = CGRect(x: 16, y: 124, width: 220, height: 496)
    fillRounded(
        ctx,
        navCavity,
        radius: 18,
        fill: color("#10161a", alpha: glassAlpha),
        stroke: color("#64717a", alpha: 0.7),
        lineWidth: 1
    )
    fillRounded(
        ctx,
        CGRect(x: 18, y: 126, width: 216, height: 24),
        radius: 12,
        fill: color("#6fa6c5", alpha: 0.08)
    )
    fillRounded(
        ctx,
        CGRect(x: 24, y: 640, width: 198, height: 12),
        radius: 6,
        fill: color("#99a6ad", alpha: 0.24)
    )

    let bridge = CGRect(x: 246, y: 318, width: 36, height: 58)
    fillRounded(
        ctx,
        bridge,
        radius: 8,
        fill: color("#141b20", alpha: 0.84),
        stroke: color("#8f9aa1", alpha: 0.38),
        lineWidth: 1
    )
    strokeLine(
        ctx,
        from: CGPoint(x: bridge.midX, y: bridge.minY + 8),
        to: CGPoint(x: bridge.midX, y: bridge.maxY - 8),
        color: color("#6fa6c5", alpha: 0.32),
        width: 2
    )

    let trafficDock = CGRect(x: 296, y: 16, width: 98, height: 30)
    fillRounded(
        ctx,
        trafficDock,
        radius: 12,
        fill: color("#20292f", alpha: 0.86),
        stroke: color("#728089", alpha: 0.55),
        lineWidth: 1
    )

    let displayPocket = CGRect(x: 684, y: 14, width: 126, height: 26)
    fillRounded(
        ctx,
        displayPocket,
        radius: 9,
        fill: color("#101a20", alpha: glassAlpha),
        stroke: color("#8eb4c5", alpha: 0.45),
        lineWidth: 1
    )
    drawLedRow(ctx, start: CGPoint(x: 828, y: 24), count: 12)

    fillRounded(
        ctx,
        terminalCavity,
        radius: 18,
        fill: color("#11171b", alpha: glassAlpha),
        stroke: color("#52616a", alpha: 0.7),
        lineWidth: 1.2
    )
    fillRounded(
        ctx,
        CGRect(x: terminalCavity.minX + 2, y: terminalCavity.minY + 2, width: terminalCavity.width - 4, height: 30),
        radius: 15,
        fill: color("#6fa6c5", alpha: 0.055)
    )

    fillRounded(
        ctx,
        inputDeck,
        radius: 16,
        fill: color("#182025", alpha: glassAlpha),
        stroke: color("#6e7b83", alpha: 0.72),
        lineWidth: 1
    )
    fillRounded(
        ctx,
        CGRect(x: inputDeck.minX + 20, y: inputDeck.minY + 10, width: inputDeck.width - 40, height: 8),
        radius: 4,
        fill: color("#6fa6c5", alpha: 0.16)
    )
    fillRounded(
        ctx,
        CGRect(x: inputDeck.midX - 42, y: inputDeck.minY + 25, width: 84, height: 6),
        radius: 3,
        fill: color("#ffb347", alpha: 0.62)
    )
    strokeLine(
        ctx,
        from: CGPoint(x: inputDeck.midX - 32, y: inputDeck.minY + 37),
        to: CGPoint(x: inputDeck.midX + 32, y: inputDeck.minY + 37),
        color: color("#05090b", alpha: 0.62),
        width: 1.2
    )

    strokeLine(
        ctx,
        from: CGPoint(x: mainBody.minX + 22, y: 58),
        to: CGPoint(x: mainBody.maxX - 22, y: 58),
        color: color("#6fa6c5", alpha: 0.32),
        width: 1
    )
    strokeLine(
        ctx,
        from: CGPoint(x: mainBody.minX + 22, y: 674),
        to: CGPoint(x: mainBody.maxX - 22, y: 674),
        color: color("#98a7af", alpha: 0.28),
        width: 2
    )

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MercuryDeckGenerator", code: 2)
    }
    try data.write(to: url)
    print("wrote \(url.path)")
}

try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
try write(
    try renderChrome(opaque: false),
    to: assetsDir.appendingPathComponent("chrome@2x.png")
)
try write(
    try renderChrome(opaque: true),
    to: assetsDir.appendingPathComponent("chrome-opaque@2x.png")
)
