import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let outer = NSBezierPath(roundedRect: NSRect(x: 36, y: 36, width: 952, height: 952), xRadius: 212, yRadius: 212)
NSGradient(colors: [NSColor(red: 0.96, green: 0.38, blue: 0.39, alpha: 1), NSColor(red: 0.6, green: 0.36, blue: 0.89, alpha: 1)])!.draw(in: outer, angle: -45)
NSGraphicsContext.saveGraphicsState()
let transform = NSAffineTransform(); transform.translateX(by: 512, yBy: 512); transform.concat()
let rotation = NSAffineTransform(); rotation.rotate(byDegrees: -12); rotation.concat()
NSColor.white.withAlphaComponent(0.42).setFill()
NSBezierPath(roundedRect: NSRect(x: -237, y: -235, width: 440, height: 490), xRadius: 48, yRadius: 48).fill()
NSGraphicsContext.restoreGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.17); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -15)
NSGraphicsContext.saveGraphicsState(); shadow.set()
NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 332, y: 226, width: 438, height: 530), xRadius: 48, yRadius: 48).fill()
NSGraphicsContext.restoreGraphicsState()
NSColor(red: 0.96, green: 0.69, blue: 0.33, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 374, y: 568, width: 354, height: 145), xRadius: 23, yRadius: 23).fill()
for (y, width) in [(493.0, 268.0), (424.0, 304.0), (355.0, 213.0)] {
    NSColor(red: 0.82, green: 0.80, blue: 0.9, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 380, y: y, width: width, height: 25), xRadius: 12, yRadius: 12).fill()
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
