import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
func render(_ side: Int, _ name: String) throws {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    let scale = CGFloat(side) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let rect = NSRect(x: 48, y: 48, width: 928, height: 928)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 215, yRadius: 215)
    NSGradient(starting: NSColor(red: 0.13, green: 0.45, blue: 0.96, alpha: 1), ending: NSColor(red: 0.08, green: 0.25, blue: 0.69, alpha: 1))!.draw(in: bg, angle: -75)
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: NSRect(x: 130, y: 280, width: 764, height: 490), xRadius: 110, yRadius: 110).fill()
    NSColor.white.setStroke()
    let display = NSBezierPath(roundedRect: NSRect(x: 205, y: 375, width: 614, height: 335), xRadius: 65, yRadius: 65)
    display.lineWidth = 37; display.stroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 512, y: 220)); arrow.line(to: NSPoint(x: 512, y: 590))
    arrow.move(to: NSPoint(x: 400, y: 480)); arrow.line(to: NSPoint(x: 512, y: 595)); arrow.line(to: NSPoint(x: 624, y: 480))
    arrow.lineWidth = 46; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 248, y: 522, width: 31, height: 31)).fill()
    NSBezierPath(ovalIn: NSRect(x: 745, y: 522, width: 31, height: 31)).fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try render(size, "icon_\(size)x\(size).png")
    try render(size * 2, "icon_\(size)x\(size)@2x.png")
}
