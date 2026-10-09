import AppKit

/// A compact clipboard-and-P template glyph for standard and Retina menu bars.
enum MenuBarIcon {
    @MainActor static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()

            let clipboard = NSBezierPath(
                roundedRect: NSRect(x: 3.2, y: 2.1, width: 13.6, height: 14.7),
                xRadius: 2.3,
                yRadius: 2.3
            )
            clipboard.lineWidth = 1.55
            clipboard.lineJoinStyle = .round
            clipboard.stroke()

            NSColor.black.setFill()
            let clasp = NSBezierPath(
                roundedRect: NSRect(x: 6.8, y: 14.7, width: 6.4, height: 3.2),
                xRadius: 1.25,
                yRadius: 1.25
            )
            clasp.fill()

            let letter = NSBezierPath()
            letter.lineWidth = 1.75
            letter.lineCapStyle = .round
            letter.lineJoinStyle = .round
            letter.move(to: NSPoint(x: 7.4, y: 5.1))
            letter.line(to: NSPoint(x: 7.4, y: 13.1))
            letter.line(to: NSPoint(x: 10.7, y: 13.1))
            letter.curve(
                to: NSPoint(x: 10.7, y: 9.2),
                controlPoint1: NSPoint(x: 14.2, y: 13.1),
                controlPoint2: NSPoint(x: 14.2, y: 9.2)
            )
            letter.line(to: NSPoint(x: 7.4, y: 9.2))
            letter.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pastrix clipboard"
        return image
    }
}
