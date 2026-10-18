// Membuat Resources/AppIcon.icns + PNG untuk website dari palet & bentuk Lapangke
// (gradien biru Original, flower & spark ekspresif). Jalankan dari root proyek: swift scripts/make-icon.swift "$PWD"
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Parser SVG kecil untuk path ekspresif (M, C, Q, Z absolut). Q diubah ke kubik.
func svgPath(_ d: String) -> NSBezierPath {
    let path = NSBezierPath()
    let scanner = Scanner(string: d)
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,")
    var current = CGPoint.zero
    func number() -> CGFloat { CGFloat(scanner.scanDouble() ?? 0) }
    func point() -> CGPoint { CGPoint(x: number(), y: number()) }
    var command: Character = "M"
    while !scanner.isAtEnd {
        if let c = scanner.scanCharacter(), "MCQZ".contains(c) { command = c } else { scanner.currentIndex = scanner.string.index(before: scanner.currentIndex) }
        switch command {
        case "M": current = point(); path.move(to: current)
        case "C":
            let c1 = point(), c2 = point(), end = point()
            path.curve(to: end, controlPoint1: c1, controlPoint2: c2); current = end
        case "Q":
            let q = point(), end = point()
            let c1 = CGPoint(x: current.x + 2 / 3 * (q.x - current.x), y: current.y + 2 / 3 * (q.y - current.y))
            let c2 = CGPoint(x: end.x + 2 / 3 * (q.x - end.x), y: end.y + 2 / 3 * (q.y - end.y))
            path.curve(to: end, controlPoint1: c1, controlPoint2: c2); current = end
        case "Z": path.close()
        default: break
        }
    }
    return path
}

let flower = svgPath("M60 8C74 -8 87 2 86 20C108 9 121 26 107 42C130 46 131 67 110 73C123 92 108 109 89 100C90 123 68 131 60 110C47 132 26 120 31 101C10 111 -3 94 11 76C-11 68 -6 47 14 43C-1 24 16 9 35 21C32 1 51 -8 60 8Z")
let spark = svgPath("M40 0Q44 36 80 40Q44 44 40 80Q36 44 0 40Q36 36 40 0Z")

/// Letakkan path (koordinat SVG, y ke bawah) di kotak tujuan dengan rotasi.
func placed(_ source: NSBezierPath, size: CGFloat, viewBox: CGFloat, center: CGPoint, rotation: CGFloat = 0) -> NSBezierPath {
    let path = source.copy() as! NSBezierPath
    var t = AffineTransform()
    t.translate(x: center.x, y: center.y)
    t.rotate(byDegrees: rotation)
    t.scale(x: size / viewBox, y: -size / viewBox)
    t.translate(x: -viewBox / 2, y: -viewBox / 2)
    path.transform(using: t)
    return path
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Badan ikon sesuai template macOS: 824×824 di kanvas 1024, sudut ±185.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x082E52, 0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x0064AF).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x4FD7F8), color(0x23ABEC), color(0x1F8CF0), color(0x0064AF)],
               atLocations: [0, 0.32, 0.62, 1], colorSpace: .sRGB)!.draw(in: body, angle: -70)

    // Dekorasi pastel seperti hero website.
    let orbit = NSBezierPath(ovalIn: NSRect(x: 30, y: 10, width: 470, height: 470))
    orbit.lineWidth = 64
    color(0xCFE3FF, 0.35).setStroke()
    orbit.stroke()
    var capsuleTransform = AffineTransform()
    capsuleTransform.translate(x: 800, y: 175)
    capsuleTransform.rotate(byDegrees: 38)
    let capsule = NSBezierPath(roundedRect: NSRect(x: -60, y: -150, width: 120, height: 300), xRadius: 60, yRadius: 60)
    capsule.transform(using: capsuleTransform)
    color(0xE1EEB2).setFill()
    capsule.fill()
    color(0xD8CFF8).setFill()
    placed(spark, size: 120, viewBox: 80, center: CGPoint(x: 245, y: 780)).fill()

    // Flower putih dengan bayangan lembut + spark biru di tengah.
    NSGraphicsContext.saveGraphicsState()
    let flowerShadow = NSShadow()
    flowerShadow.shadowColor = color(0x082E52, 0.28)
    flowerShadow.shadowBlurRadius = 30
    flowerShadow.shadowOffset = NSSize(width: 0, height: -14)
    flowerShadow.set()
    NSColor.white.setFill()
    placed(flower, size: 540, viewBox: 120, center: CGPoint(x: 522, y: 500), rotation: 12).fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0x0064AF).setFill()
    placed(spark, size: 250, viewBox: 80, center: CGPoint(x: 522, y: 500)).fill()
    color(0x4FD7F8).setFill()
    placed(spark, size: 74, viewBox: 80, center: CGPoint(x: 640, y: 620)).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Sorot tipis di tepi atas.
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    rim.lineWidth = 3
    NSColor(white: 1, alpha: 0.22).setStroke()
    rim.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Lapangke.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()

// Aset website memakai gambar yang sama.
let web = root.appendingPathComponent("web/public")
try render(512).write(to: web.appendingPathComponent("icon.png"))
try render(180).write(to: web.appendingPathComponent("apple-touch-icon.png"))
try render(64).write(to: web.appendingPathComponent("favicon.png"))
print(process.terminationStatus == 0 ? "OK → \(output.path) + web/public/{icon,apple-touch-icon,favicon}.png" : "iconutil gagal")
