import AppKit

/// A small template glyph inspired by the clipboard + folded page reference.
/// Vector drawing keeps edges crisp on both standard and Retina menu bars.
enum MenuBarIcon {
    @MainActor static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            func stroke(_ points: [NSPoint], width: CGFloat = 1.45) {
                let p = NSBezierPath(); p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round
                p.move(to: points[0]); for point in points.dropFirst() { p.line(to: point) }; p.stroke()
            }
            let board = NSBezierPath()
            board.lineWidth = 1.45; board.lineCapStyle = .round; board.lineJoinStyle = .round
            board.move(to: NSPoint(x: 7.2, y: 3.2))
            board.line(to: NSPoint(x: 4.5, y: 3.2))
            board.curve(to: NSPoint(x: 2.3, y: 5.4), controlPoint1: NSPoint(x: 3, y: 3.2), controlPoint2: NSPoint(x: 2.3, y: 3.9))
            board.line(to: NSPoint(x: 2.3, y: 14.5))
            board.curve(to: NSPoint(x: 4.5, y: 16.7), controlPoint1: NSPoint(x: 2.3, y: 16), controlPoint2: NSPoint(x: 3, y: 16.7))
            board.line(to: NSPoint(x: 5.3, y: 16.7)); board.stroke()
            stroke([NSPoint(x: 10.7, y: 16.7), NSPoint(x: 11.5, y: 16.7), NSPoint(x: 12.4, y: 16.3), NSPoint(x: 12.7, y: 15)])
            let clasp = NSBezierPath(roundedRect: NSRect(x: 5.3, y: 15.3, width: 5.4, height: 3.1), xRadius: 1.25, yRadius: 1.25)
            clasp.lineWidth = 1.35; clasp.stroke()
            let page = NSBezierPath(); page.lineWidth = 1.45; page.lineCapStyle = .round; page.lineJoinStyle = .round
            page.move(to: NSPoint(x: 14.2, y: 13.7)); page.line(to: NSPoint(x: 9.7, y: 13.7))
            page.curve(to: NSPoint(x: 7.7, y: 11.7), controlPoint1: NSPoint(x: 8.3, y: 13.7), controlPoint2: NSPoint(x: 7.7, y: 13.1))
            page.line(to: NSPoint(x: 7.7, y: 3.5))
            page.curve(to: NSPoint(x: 9.7, y: 1.5), controlPoint1: NSPoint(x: 7.7, y: 2.1), controlPoint2: NSPoint(x: 8.3, y: 1.5))
            page.line(to: NSPoint(x: 16.2, y: 1.5))
            page.curve(to: NSPoint(x: 18.2, y: 3.5), controlPoint1: NSPoint(x: 17.6, y: 1.5), controlPoint2: NSPoint(x: 18.2, y: 2.1))
            page.line(to: NSPoint(x: 18.2, y: 9.7)); page.close(); page.stroke()
            stroke([NSPoint(x: 14.2, y: 13.7), NSPoint(x: 14.2, y: 10.7), NSPoint(x: 14.5, y: 10), NSPoint(x: 15.2, y: 9.7), NSPoint(x: 18.2, y: 9.7)], width: 1.2)
            // A tiny friendly face remains legible without the reference's fine detail.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 10, y: 7.3, width: 0.95, height: 0.95)).fill()
            NSBezierPath(ovalIn: NSRect(x: 15, y: 7.3, width: 0.95, height: 0.95)).fill()
            let smile = NSBezierPath(); smile.lineWidth = 1; smile.lineCapStyle = .round
            smile.move(to: NSPoint(x: 11.9, y: 7.3)); smile.curve(to: NSPoint(x: 14, y: 7.3), controlPoint1: NSPoint(x: 12.2, y: 5.9), controlPoint2: NSPoint(x: 13.7, y: 5.9)); smile.stroke()
            stroke([NSPoint(x: 10.3, y: 4.3), NSPoint(x: 15.6, y: 4.3)], width: 1.1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Paster clipboard"
        return image
    }
}
