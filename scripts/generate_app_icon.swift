import AppKit

let fileManager = FileManager.default
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "SimpleAUHost/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let canvasSize = CGSize(width: 1024, height: 1024)
let iconRect = CGRect(origin: .zero, size: canvasSize)
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Failed to create bitmap graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Failed to create graphics context")
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.interpolationQuality = .high

let cornerRadius: CGFloat = 224
let bodyRect = iconRect.insetBy(dx: 72, dy: 72)
let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)

context.saveGState()
bodyPath.addClip()

let backgroundGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.18, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.42, alpha: 1),
    NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.19, alpha: 1)
])!
backgroundGradient.draw(in: bodyPath, angle: -38)

let orbCenter = CGPoint(x: canvasSize.width * 0.34, y: canvasSize.height * 0.74)
let orbColors = [
    NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.49, alpha: 0.95).cgColor,
    NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.25, alpha: 0.0).cgColor
] as CFArray
let orbLocations: [CGFloat] = [0.0, 1.0]
let orbGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: orbColors, locations: orbLocations)!
context.drawRadialGradient(orbGradient, startCenter: orbCenter, startRadius: 20, endCenter: orbCenter, endRadius: 420, options: .drawsAfterEndLocation)

let gridPath = NSBezierPath()
for offset in stride(from: -300 as CGFloat, through: 1100, by: 72) {
    gridPath.move(to: CGPoint(x: offset, y: 0))
    gridPath.line(to: CGPoint(x: offset + 420, y: 1024))
}
context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
context.setLineWidth(18)
for lineDash in [28.0, 18.0] {
    context.setLineDash(phase: 0, lengths: [lineDash, lineDash])
    context.addPath(gridPath.cgPath)
    context.strokePath()
}

let laneRect = CGRect(x: 180, y: 284, width: 664, height: 456)
let lanePath = NSBezierPath(roundedRect: laneRect, xRadius: 170, yRadius: 170)

context.saveGState()
lanePath.addClip()
let laneGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.13, alpha: 0.92),
    NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.31, alpha: 0.84)
])!
laneGradient.draw(in: lanePath, angle: 90)
context.restoreGState()

context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
context.setLineWidth(10)
context.addPath(lanePath.cgPath)
context.strokePath()

let railPath = NSBezierPath()
railPath.move(to: CGPoint(x: 240, y: 512))
railPath.curve(to: CGPoint(x: 784, y: 512), controlPoint1: CGPoint(x: 366, y: 514), controlPoint2: CGPoint(x: 656, y: 510))
context.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
context.setLineWidth(34)
context.setLineCap(.round)
context.addPath(railPath.cgPath)
context.strokePath()

func drawPort(center: CGPoint, accent: NSColor, direction: CGFloat) {
    let outerRect = CGRect(x: center.x - 98, y: center.y - 98, width: 196, height: 196)
    let innerRect = CGRect(x: center.x - 48, y: center.y - 48, width: 96, height: 96)
    let stemRect = CGRect(x: center.x - 18 + direction * -76, y: center.y - 110, width: 36, height: 220)

    let outer = NSBezierPath(ovalIn: outerRect)
    context.setFillColor(NSColor(calibratedWhite: 0.06, alpha: 0.95).cgColor)
    context.addPath(outer.cgPath)
    context.fillPath()

    context.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
    context.setLineWidth(18)
    context.addPath(outer.cgPath)
    context.strokePath()

    let stem = NSBezierPath(roundedRect: stemRect, xRadius: 18, yRadius: 18)
    context.setFillColor(accent.withAlphaComponent(0.88).cgColor)
    context.addPath(stem.cgPath)
    context.fillPath()

    let inner = NSBezierPath(ovalIn: innerRect)
    context.setFillColor(NSColor(calibratedWhite: 0.11, alpha: 1).cgColor)
    context.addPath(inner.cgPath)
    context.fillPath()
}

drawPort(center: CGPoint(x: 282, y: 512), accent: NSColor(calibratedRed: 0.22, green: 0.87, blue: 0.75, alpha: 1), direction: -1)
drawPort(center: CGPoint(x: 742, y: 512), accent: NSColor(calibratedRed: 1.0, green: 0.60, blue: 0.28, alpha: 1), direction: 1)

let waveform = NSBezierPath()
waveform.move(to: CGPoint(x: 260, y: 512))
waveform.curve(to: CGPoint(x: 360, y: 512), controlPoint1: CGPoint(x: 290, y: 512), controlPoint2: CGPoint(x: 320, y: 512))
waveform.curve(to: CGPoint(x: 430, y: 638), controlPoint1: CGPoint(x: 396, y: 512), controlPoint2: CGPoint(x: 398, y: 638))
waveform.curve(to: CGPoint(x: 512, y: 512), controlPoint1: CGPoint(x: 462, y: 638), controlPoint2: CGPoint(x: 478, y: 512))
waveform.curve(to: CGPoint(x: 600, y: 386), controlPoint1: CGPoint(x: 546, y: 512), controlPoint2: CGPoint(x: 558, y: 386))
waveform.curve(to: CGPoint(x: 664, y: 512), controlPoint1: CGPoint(x: 638, y: 386), controlPoint2: CGPoint(x: 630, y: 512))
waveform.curve(to: CGPoint(x: 764, y: 512), controlPoint1: CGPoint(x: 700, y: 512), controlPoint2: CGPoint(x: 730, y: 512))

context.saveGState()
context.setShadow(offset: .zero, blur: 34, color: NSColor.white.withAlphaComponent(0.55).cgColor)
context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
context.setLineWidth(40)
context.setLineCap(.round)
context.setLineJoin(.round)
context.addPath(waveform.cgPath)
context.strokePath()
context.restoreGState()

context.setStrokeColor(NSColor(calibratedRed: 0.51, green: 0.97, blue: 0.92, alpha: 0.92).cgColor)
context.setLineWidth(14)
context.addPath(waveform.cgPath)
context.strokePath()

let sparkleCenters = [
    CGPoint(x: 442, y: 650),
    CGPoint(x: 592, y: 366),
    CGPoint(x: 512, y: 524)
]
for (index, center) in sparkleCenters.enumerated() {
    let radius = CGFloat(index == 2 ? 18 : 12)
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.setFillColor(NSColor.white.withAlphaComponent(index == 2 ? 0.95 : 0.75).cgColor)
    context.fillEllipse(in: rect)
}

context.restoreGState()

let glossRect = bodyRect.insetBy(dx: 24, dy: 24)
let glossPath = NSBezierPath(roundedRect: glossRect, xRadius: 196, yRadius: 196)
context.saveGState()
glossPath.addClip()
let glossGradient = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.24),
    NSColor.white.withAlphaComponent(0.02),
    NSColor.clear
])!
glossGradient.draw(from: CGPoint(x: 0, y: 930), to: CGPoint(x: 0, y: 430), options: [])
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render PNG output")
}

let outputURL = outputDirectory.appendingPathComponent("icon_512x512@2x.png")
try pngData.write(to: outputURL)
print(outputURL.path)
