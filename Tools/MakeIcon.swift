// Renders the app icon — the mascot standing on its progress rail, matching the
// scrubber inside the app.
//
//   swift Tools/MakeIcon.swift <output.png>          macOS: inset squircle with
//                                                    its own rounded corners
//   swift Tools/MakeIcon.swift <output.png> --ios    iOS: full-bleed and opaque,
//                                                    since iOS masks the corners
//                                                    itself and rejects alpha
import AppKit

let isIOS = CommandLine.arguments.contains("--ios")
let size = 1024.0
// Draw into an explicit CGContext rather than NSImage.lockFocus(): on a retina
// display that renders at 2x, and iOS demands exactly 1024x1024 with no alpha
// channel. NSBitmapImageRep refuses to hand back a graphics context when built
// without alpha, so the bitmap is configured at the CoreGraphics layer.
let hasAlpha = !isIOS
guard let cgContext = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast
                          : CGImageAlphaInfo.noneSkipLast).rawValue
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: false)

// iOS applies its own mask, so the artwork must run edge to edge. Insetting it
// would leave a shrunken icon floating inside the system's rounded square.
let inset = isIOS ? 0 : size * 0.085
let card = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = isIOS ? 0 : size * 0.225
let squircle = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)

NSGraphicsContext.current?.saveGraphicsState()
squircle.addClip()

// Indigo to violet, the library's default cast.
NSGradient(colors: [
    NSColor(srgbRed: 0.15, green: 0.17, blue: 0.42, alpha: 1),
    NSColor(srgbRed: 0.35, green: 0.29, blue: 0.78, alpha: 1),
    NSColor(srgbRed: 0.62, green: 0.44, blue: 0.95, alpha: 1)
], atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: card, angle: 58)

// The gradient runs edge to edge, but the character is inset so iOS's corner
// mask never clips it and it doesn't feel cramped.
let art = isIOS ? card.insetBy(dx: size * 0.11, dy: size * 0.11) : card
let S = art.width
let ink = NSColor(srgbRed: 0.17, green: 0.15, blue: 0.36, alpha: 1)
let cream = NSColor.white

// AppKit's y runs upward, so the rail sits low and the head rides high.
let railY = art.minY + S * 0.235
let railHeight = S * 0.038
let cx = art.midX

// The rail: played stretch bright, the rest knocked back.
let railLeft = art.minX + S * 0.13
let railRight = art.maxX - S * 0.13
let split = cx - S * 0.02

cream.withAlphaComponent(0.35).setFill()
NSBezierPath(roundedRect: CGRect(x: railLeft, y: railY, width: railRight - railLeft, height: railHeight),
             xRadius: railHeight / 2, yRadius: railHeight / 2).fill()
cream.setFill()
NSBezierPath(roundedRect: CGRect(x: railLeft, y: railY, width: split - railLeft, height: railHeight),
             xRadius: railHeight / 2, yRadius: railHeight / 2).fill()

// Legs, standing on the rail.
let legWidth = S * 0.068
let legHeight = S * 0.20
let legTop = railY + legHeight
for side in [-1.0, 1.0] {
    let x = cx + S * 0.125 * side - legWidth / 2
    NSBezierPath(roundedRect: CGRect(x: x, y: railY, width: legWidth, height: legHeight),
                 xRadius: legWidth / 2, yRadius: legWidth / 2).fill()
}

// Arms, swung outward and clear of the head.
let headRadius = S * 0.215
let headCY = legTop + headRadius * 0.72
let armWidth = S * 0.070
let armLength = S * 0.20
for side in [-1.0, 1.0] {
    let path = NSBezierPath(roundedRect:
        CGRect(x: -armWidth / 2, y: -armLength, width: armWidth, height: armLength),
        xRadius: armWidth / 2, yRadius: armWidth / 2)
    let transform = NSAffineTransform()
    transform.translateX(by: cx + headRadius * 0.92 * side, yBy: headCY + headRadius * 0.16)
    transform.rotate(byDegrees: 32 * side)
    path.transform(using: transform as AffineTransform)
    path.fill()
}

// Headphone cups.
let cupWidth = S * 0.085
let cupHeight = S * 0.15
for side in [-1.0, 1.0] {
    let x = cx + headRadius * 1.10 * side - cupWidth / 2
    NSBezierPath(roundedRect: CGRect(x: x, y: headCY - cupHeight / 2, width: cupWidth, height: cupHeight),
                 xRadius: cupWidth / 2, yRadius: cupWidth / 2).fill()
}

// Band over the crown.
let band = NSBezierPath()
band.appendArc(withCenter: CGPoint(x: cx, y: headCY), radius: headRadius * 1.10,
               startAngle: 28, endAngle: 152)
band.lineWidth = S * 0.055
band.lineCapStyle = .round
cream.setStroke()
band.stroke()

// Head.
cream.setFill()
NSBezierPath(ovalIn: CGRect(x: cx - headRadius, y: headCY - headRadius,
                            width: headRadius * 2, height: headRadius * 2)).fill()

// Eyes and an open, singing mouth.
ink.setFill()
let eyeRadius = S * 0.038
for side in [-1.0, 1.0] {
    let x = cx + S * 0.072 * side
    NSBezierPath(ovalIn: CGRect(x: x - eyeRadius, y: headCY + S * 0.018 - eyeRadius,
                                width: eyeRadius * 2, height: eyeRadius * 2)).fill()
}
let mouthWidth = S * 0.058
let mouthHeight = S * 0.052
NSBezierPath(ovalIn: CGRect(x: cx - mouthWidth / 2, y: headCY - S * 0.075,
                            width: mouthWidth, height: mouthHeight)).fill()

NSGraphicsContext.current?.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
guard let cgImage = cgContext.makeImage() else { exit(1) }
let bitmap = NSBitmapImageRep(cgImage: cgImage)
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)  \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)  alpha=\(bitmap.hasAlpha)")
