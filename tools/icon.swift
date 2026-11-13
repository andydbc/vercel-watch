import AppKit
// Usage: icon <outdir.iconset>  — black rounded square with white triangle.
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int, _ name: String) {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225).fill()
    let w = r.width * 0.46, h = w * 0.866
    let cx = s / 2, cy = s / 2
    let t = NSBezierPath()
    t.move(to: NSPoint(x: cx, y: cy + h * 0.55))
    t.line(to: NSPoint(x: cx + w / 2, y: cy - h * 0.45))
    t.line(to: NSPoint(x: cx - w / 2, y: cy - h * 0.45))
    t.close()
    NSColor.white.setFill(); t.fill()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
for (n, sz) in [(16,16),(32,32),(128,128),(256,256),(512,512)] {
    render(sz, "icon_\(n)x\(n)"); render(sz * 2, "icon_\(n)x\(n)@2x")
}
