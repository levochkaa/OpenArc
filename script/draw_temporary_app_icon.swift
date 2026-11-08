// Draws the temporary app icon into a folder: swiftc -o /tmp/draw script/draw_temporary_app_icon.swift && /tmp/draw <folder>
import AppKit
// Draws OpenArc's temporary app icon: an open white arc on a violet-to-coral squircle.
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS grid: 824/1024 body, 100 px margin, corner ~185.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(srgbRed: 0.33, green: 0.24, blue: 0.86, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.93, green: 0.42, blue: 0.47, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // A faint top sheen.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    // The open arc: three quarters of a ring, open at the lower right, with round ends.
    let center = CGPoint(x: body.midX, y: body.midY)
    let ring = body.width * 0.27
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(body.width * 0.115)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: ring, startAngle: -.pi / 4 + 0.2, endAngle: -.pi / 4 - 0.2 + 2 * .pi * 0.75 + .pi / 2 - .pi / 2, clockwise: false)
    ctx.strokePath()
    // A dot that the arc points at.
    let dotAngle = -CGFloat.pi / 4 - 0.55
    let dot = CGPoint(x: center.x + cos(dotAngle) * ring, y: center.y + sin(dotAngle) * ring)
    let r = body.width * 0.062
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
for px in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(px).png"))
}
