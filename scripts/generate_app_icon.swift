import AppKit

struct IconSpec {
    let filename: String
    let pixelSize: Int
}

let fileManager = FileManager.default
let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "SimpleAUHost/Assets.xcassets/AppIcon.appiconset",
    isDirectory: true
)

let specs = [
    IconSpec(filename: "icon_16x16.png", pixelSize: 16),
    IconSpec(filename: "icon_16x16@2x.png", pixelSize: 32),
    IconSpec(filename: "icon_32x32.png", pixelSize: 32),
    IconSpec(filename: "icon_32x32@2x.png", pixelSize: 64),
    IconSpec(filename: "icon_128x128.png", pixelSize: 128),
    IconSpec(filename: "icon_128x128@2x.png", pixelSize: 256),
    IconSpec(filename: "icon_256x256.png", pixelSize: 256),
    IconSpec(filename: "icon_256x256@2x.png", pixelSize: 512),
    IconSpec(filename: "icon_512x512.png", pixelSize: 512),
    IconSpec(filename: "icon_512x512@2x.png", pixelSize: 1024)
]

enum DetailLevel {
    case compact
    case standard
    case full
}

let teal = NSColor(calibratedRed: 0.13, green: 0.92, blue: 0.82, alpha: 1)
let orange = NSColor(calibratedRed: 1.00, green: 0.56, blue: 0.23, alpha: 1)
let navy = NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.18, alpha: 1)
let cobalt = NSColor(calibratedRed: 0.14, green: 0.29, blue: 0.62, alpha: 1)
let slate = NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.23, alpha: 1)

try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for spec in specs {
    try renderIcon(spec)
}

func renderIcon(_ spec: IconSpec) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: spec.pixelSize,
        pixelsHigh: spec.pixelSize,
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

    let detailLevel: DetailLevel
    if spec.pixelSize <= 32 {
        detailLevel = .compact
    } else if spec.pixelSize <= 128 {
        detailLevel = .standard
    } else {
        detailLevel = .full
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Failed to create graphics context")
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(spec.pixelSize) / 1024.0, y: CGFloat(spec.pixelSize) / 1024.0)

    drawIcon(in: context, detailLevel: detailLevel)

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Failed to render PNG output")
    }

    let outputURL = outputDirectory.appendingPathComponent(spec.filename)
    try pngData.write(to: outputURL)
    print(outputURL.path)
}

func drawIcon(in context: CGContext, detailLevel: DetailLevel) {
    let iconRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let bodyRect = iconRect.insetBy(dx: 70, dy: 70)
    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 228, yRadius: 228)

    context.saveGState()
    bodyPath.addClip()

    let baseGradient = NSGradient(colors: [navy, cobalt, orange])!
    baseGradient.draw(in: bodyPath, angle: -32)

    let topGlow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawRadialGradient(
        topGlow,
        startCenter: CGPoint(x: 332, y: 804),
        startRadius: 10,
        endCenter: CGPoint(x: 332, y: 804),
        endRadius: 470,
        options: .drawsAfterEndLocation
    )

    let cornerGlow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            orange.withAlphaComponent(0.42).cgColor,
            orange.withAlphaComponent(0.0).cgColor
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawRadialGradient(
        cornerGlow,
        startCenter: CGPoint(x: 816, y: 164),
        startRadius: 12,
        endCenter: CGPoint(x: 816, y: 164),
        endRadius: 360,
        options: .drawsAfterEndLocation
    )

    if detailLevel == .full {
        drawBackgroundBands(in: context)
    }

    context.restoreGState()

    drawShellStroke(in: context, rect: bodyRect)
    drawSignalStage(in: context, detailLevel: detailLevel)
}

func drawBackgroundBands(in context: CGContext) {
    context.saveGState()
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
    context.setLineWidth(20)

    for index in 0..<4 {
        let offset = CGFloat(index) * 102
        let band = NSBezierPath()
        band.move(to: CGPoint(x: -90 + offset, y: 120))
        band.curve(
            to: CGPoint(x: 320 + offset, y: 980),
            controlPoint1: CGPoint(x: 70 + offset, y: 430),
            controlPoint2: CGPoint(x: 180 + offset, y: 760)
        )
        context.addPath(band.cgPath)
        context.strokePath()
    }

    context.restoreGState()
}

func drawShellStroke(in context: CGContext, rect: CGRect) {
    let strokePath = NSBezierPath(roundedRect: rect, xRadius: 228, yRadius: 228)
    context.saveGState()
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    context.setLineWidth(12)
    context.addPath(strokePath.cgPath)
    context.strokePath()

    let innerHighlight = NSBezierPath(roundedRect: rect.insetBy(dx: 22, dy: 22), xRadius: 202, yRadius: 202)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    context.setLineWidth(6)
    context.addPath(innerHighlight.cgPath)
    context.strokePath()
    context.restoreGState()
}

func drawSignalStage(in context: CGContext, detailLevel: DetailLevel) {
    let stageRect = CGRect(x: 168, y: 286, width: 688, height: 452)
    let stagePath = NSBezierPath(roundedRect: stageRect, xRadius: 166, yRadius: 166)

    if detailLevel != .compact {
        context.saveGState()
        stagePath.addClip()
        let stageGradient = NSGradient(colors: [
            slate.withAlphaComponent(0.94),
            NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.20, alpha: 0.90)
        ])!
        stageGradient.draw(in: stagePath, angle: 90)

        if detailLevel == .full {
            drawTrackMeters(in: context)
        }

        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.17).cgColor)
        context.setLineWidth(10)
        context.addPath(stagePath.cgPath)
        context.strokePath()
        context.restoreGState()
    }

    drawPorts(in: context, detailLevel: detailLevel)
    drawWaveform(in: context, detailLevel: detailLevel)
}

func drawTrackMeters(in context: CGContext) {
    let laneYs: [CGFloat] = [395, 512, 629]
    let laneColors = [
        teal.withAlphaComponent(0.16),
        NSColor.white.withAlphaComponent(0.10),
        orange.withAlphaComponent(0.14)
    ]

    for (laneIndex, y) in laneYs.enumerated() {
        for barIndex in 0..<7 {
            let x = 340 + CGFloat(barIndex) * 46
            let height = CGFloat(36 + ((laneIndex + barIndex) % 4) * 18)
            let rect = CGRect(x: x, y: y - height / 2, width: 22, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
            context.setFillColor(laneColors[laneIndex].cgColor)
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }
}

func drawPorts(in context: CGContext, detailLevel: DetailLevel) {
    drawPort(
        in: context,
        center: CGPoint(x: 278, y: 512),
        accent: teal,
        detailLevel: detailLevel
    )
    drawPort(
        in: context,
        center: CGPoint(x: 746, y: 512),
        accent: orange,
        detailLevel: detailLevel
    )
}

func drawPort(in context: CGContext, center: CGPoint, accent: NSColor, detailLevel: DetailLevel) {
    let outerDiameter: CGFloat = detailLevel == .compact ? 178 : 190
    let outerRect = CGRect(
        x: center.x - outerDiameter / 2,
        y: center.y - outerDiameter / 2,
        width: outerDiameter,
        height: outerDiameter
    )
    let outerPath = NSBezierPath(ovalIn: outerRect)

    context.saveGState()
    context.setFillColor(NSColor(calibratedWhite: 0.06, alpha: 0.96).cgColor)
    context.addPath(outerPath.cgPath)
    context.fillPath()

    context.setStrokeColor(accent.cgColor)
    context.setLineWidth(detailLevel == .compact ? 18 : 20)
    context.addPath(outerPath.cgPath)
    context.strokePath()

    let innerDiameter: CGFloat = detailLevel == .compact ? 62 : 74
    let innerRect = CGRect(
        x: center.x - innerDiameter / 2,
        y: center.y - innerDiameter / 2,
        width: innerDiameter,
        height: innerDiameter
    )
    context.setFillColor(accent.withAlphaComponent(0.96).cgColor)
    context.fillEllipse(in: innerRect)

    if detailLevel != .compact {
        let highlightRect = outerRect.insetBy(dx: 18, dy: 18)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        context.setLineWidth(6)
        context.addEllipse(in: highlightRect)
        context.strokePath()
    }

    context.restoreGState()
}

func drawWaveform(in context: CGContext, detailLevel: DetailLevel) {
    let points = [
        CGPoint(x: 334, y: 512),
        CGPoint(x: 422, y: 512),
        CGPoint(x: 486, y: 640),
        CGPoint(x: 548, y: 412),
        CGPoint(x: 618, y: 602),
        CGPoint(x: 694, y: 512)
    ]

    let waveform = NSBezierPath()
    waveform.move(to: points[0])
    for point in points.dropFirst() {
        waveform.line(to: point)
    }

    context.saveGState()
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(detailLevel == .compact ? 82 : 72)
    context.addPath(waveform.cgPath)
    context.strokePath()

    if detailLevel != .compact {
        context.setStrokeColor(cobalt.withAlphaComponent(0.42).cgColor)
        context.setLineWidth(20)
        context.addPath(waveform.cgPath)
        context.strokePath()
    }

    if detailLevel == .full {
        for point in [points[2], points[3], points[4]] {
            let dotRect = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
            context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
            context.fillEllipse(in: dotRect)
        }
    }

    context.restoreGState()
}
