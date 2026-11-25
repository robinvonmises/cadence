// Zeichnet das Cadence-App-Icon (Sprechblase mit Klangwelle auf Marken-Verlauf).
//
//   swift scripts/make-icon.swift <ausgabe.png>
//
// scripts/make-icon.sh erzeugt daraus Resources/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let indigo = color(0.31, 0.27, 0.90)
let violet = color(0.55, 0.36, 0.96)
let coral = color(0.98, 0.42, 0.45)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Koordinaten wie in SwiftUI: Ursprung oben links.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

/// Kontinuierlich abgerundetes Rechteck (macOS-„Squircle“).
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

func linearGradient(_ colors: [CGColor], from: CGPoint, to: CGPoint, in path: CGPath) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// 1. Grundfläche nach Apples Icon-Raster: 824 pt, mittig, mit weichem Schatten.
let inset = (size - 824) / 2
let tile = CGRect(x: inset, y: inset, width: 824, height: 824)
let tilePath = squircle(tile, radius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0, 0, 0, 0.18))
ctx.addPath(tilePath)
ctx.setFillColor(indigo)
ctx.fillPath()
ctx.restoreGState()
linearGradient([indigo, violet, coral], from: CGPoint(x: tile.minX, y: tile.minY), to: CGPoint(x: tile.maxX, y: tile.maxY), in: tilePath)
// Glanz oben.
linearGradient([color(1, 1, 1, 0.28), color(1, 1, 1, 0)], from: CGPoint(x: 0, y: tile.minY), to: CGPoint(x: 0, y: tile.midY), in: tilePath)

// 2. Sprechblase.
let mark = tile.insetBy(dx: 824 * 0.2, dy: 824 * 0.2)
let bubbleBody = CGRect(x: mark.minX, y: mark.minY, width: mark.width, height: mark.height * 0.84)
let tail = CGMutablePath()
tail.move(to: CGPoint(x: mark.minX + mark.width * 0.20, y: bubbleBody.maxY - mark.height * 0.10))
tail.addLine(to: CGPoint(x: mark.minX + mark.width * 0.10, y: mark.maxY))
tail.addQuadCurve(to: CGPoint(x: mark.minX + mark.width * 0.46, y: bubbleBody.maxY - mark.height * 0.04),
                  control: CGPoint(x: mark.minX + mark.width * 0.30, y: mark.maxY - mark.height * 0.02))
tail.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: color(0.12, 0.05, 0.30, 0.25))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(1, 1, 1))
ctx.addPath(squircle(bubbleBody, radius: mark.width * 0.26))
ctx.fillPath()
ctx.addPath(tail)
ctx.fillPath()
ctx.endTransparencyLayer()
ctx.restoreGState()

// 3. Klangwelle aus fünf Balken im Marken-Verlauf.
let heights: [CGFloat] = [0.32, 0.62, 0.92, 0.55, 0.38]
let barWidth = mark.width * 0.085
let gap = mark.width * 0.06
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
let centerY = mark.minY + mark.height / 2 - mark.height * 0.06
let bars = CGMutablePath()
for (index, h) in heights.enumerated() {
    let height = mark.height * 0.62 * h
    let x = mark.midX - total / 2 + CGFloat(index) * (barWidth + gap)
    let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
    bars.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
linearGradient([indigo, violet, coral], from: CGPoint(x: mark.minX, y: mark.minY), to: CGPoint(x: mark.maxX, y: mark.maxY), in: bars)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("✓ \(output)")
