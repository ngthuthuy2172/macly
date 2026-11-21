import AppKit

// Icon mẫu 5: vòng dung lượng + cây chổi, nền xanh lá kính
let px = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Thiết kế trên lưới 90×90, đặt vào ô 824px (lề 100px như icon macOS)
let s: CGFloat = 824.0 / 90.0
func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 100 + x * s, y: 100 + (90 - y) * s) }
func L(_ v: CGFloat) -> CGFloat { v * s }

// Nền bo góc
let bgRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.33, green: 0.23, blue: 0.72, alpha: 1),
                    NSColor(red: 0.52, green: 0.40, blue: 0.92, alpha: 1),
                    NSColor(red: 0.86, green: 0.62, blue: 0.92, alpha: 1)])!.draw(in: bgPath, angle: -45)

// Ánh bóng kính phía trên
NSGraphicsContext.saveGraphicsState()
bgPath.addClip()
let gloss = NSBezierPath(ovalIn: NSRect(x: 60, y: 560, width: 904, height: 520))
NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0.0)])!.draw(in: gloss, angle: -90)
NSGraphicsContext.restoreGraphicsState()
NSColor(white: 1, alpha: 0.25).setStroke()
bgPath.lineWidth = 4
bgPath.stroke()

let center = P(45, 46)
let r = L(27)

// Đĩa kính bên trong
let disc = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
NSColor(white: 1, alpha: 0.16).setFill()
disc.fill()

// Vòng mờ đầy đủ
let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
ring.lineWidth = L(8)
NSColor(white: 1, alpha: 0.28).setStroke()
ring.stroke()

// Cung 3/4 sáng
let arc = NSBezierPath()
arc.appendArc(withCenter: center, radius: r, startAngle: 90, endAngle: 180, clockwise: true)
arc.lineWidth = L(8)
arc.lineCapStyle = .round
NSColor.white.setStroke()
arc.stroke()

// Cây chổi
let handle = NSBezierPath()
handle.move(to: P(53, 31))
handle.line(to: P(45, 48))
handle.lineWidth = L(3.6)
handle.lineCapStyle = .round
NSColor.white.setStroke()
handle.stroke()

let brush = NSBezierPath()
brush.move(to: P(39, 46))
brush.line(to: P(51, 50))
brush.line(to: P(49, 61))
brush.curve(to: P(35, 56), controlPoint1: P(44, 62.5), controlPoint2: P(38.5, 60))
brush.close()
NSColor.white.setFill()
brush.fill()

let bristles = NSBezierPath()
bristles.move(to: P(42, 52)); bristles.line(to: P(40, 58))
bristles.move(to: P(46, 53.5)); bristles.line(to: P(45, 60))
bristles.lineWidth = L(1.4)
bristles.lineCapStyle = .round
NSColor(red: 0.55, green: 0.42, blue: 0.90, alpha: 1).setStroke()
bristles.stroke()

// Tia lấp lánh nhỏ
func sparkle(_ c: NSPoint, _ rr: CGFloat) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x, y: c.y + rr))
    p.curve(to: NSPoint(x: c.x + rr, y: c.y), controlPoint1: NSPoint(x: c.x, y: c.y), controlPoint2: NSPoint(x: c.x, y: c.y))
    p.curve(to: NSPoint(x: c.x, y: c.y - rr), controlPoint1: NSPoint(x: c.x, y: c.y), controlPoint2: NSPoint(x: c.x, y: c.y))
    p.curve(to: NSPoint(x: c.x - rr, y: c.y), controlPoint1: NSPoint(x: c.x, y: c.y), controlPoint2: NSPoint(x: c.x, y: c.y))
    p.curve(to: NSPoint(x: c.x, y: c.y + rr), controlPoint1: NSPoint(x: c.x, y: c.y), controlPoint2: NSPoint(x: c.x, y: c.y))
    NSColor.white.setFill()
    p.fill()
}
sparkle(P(61, 35), L(4))

NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
