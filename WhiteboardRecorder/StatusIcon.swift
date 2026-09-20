import AppKit

enum StatusIcon {
    static func image(for state: IconState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let diameter: CGFloat = 14
        let origin = (size.width - diameter) / 2
        let rect = NSRect(x: origin, y: origin, width: diameter, height: diameter)
        let path = NSBezierPath(ovalIn: rect)

        switch state {
        case .idle:
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        case .recording:
            NSColor.black.setFill()
            path.fill()
        case .uploading:
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let dot = rect.insetBy(dx: 4.5, dy: 4.5)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        image.unlockFocus()
        // Template images follow the menu bar appearance, light or dark.
        image.isTemplate = true
        return image
    }
}
