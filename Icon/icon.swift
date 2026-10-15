// The app's icon: the flying kea (Icon/kea.png, 1024 × 1024, its sunset and
// all) on Apple's plate — 824 of 1024, corners at 22.37% — with the soft
// shadow every icon in the Dock has, drawn at each size an iconset wants.
//
//   swift Icon/icon.swift Icon/kea.png build/AppIcon.iconset
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, let art = NSImage(contentsOfFile: args[0]) else {
    FileHandle.standardError.write(Data("usage: swift Icon/icon.swift ART.png OUT.iconset\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(pixels) / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: plate, xRadius: 824 * 0.2237 * s, yRadius: 824 * 0.2237 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    art.draw(in: plate, from: .zero, operation: .sourceOver, fraction: 1)
    return rep.representation(using: .png, properties: [:])
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(points * scale)?.write(to: out.appendingPathComponent(name))
    }
}
print("drew: \(out.path)")
