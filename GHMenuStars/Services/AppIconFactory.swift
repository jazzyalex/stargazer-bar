import AppKit

enum AppIconFactory {
    static func iconImage(size: NSSize = NSSize(width: 512, height: 512)) -> NSImage {
        bundledIcon() ?? makeIcon(size: size)
    }

    static func applyRuntimeIcon() {
        NSApplication.shared.applicationIconImage = iconImage()
    }

    private static func bundledIcon() -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: iconURL)
    }

    private static func makeIcon(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let bounds = NSRect(origin: .zero, size: size)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 36, dy: 36), xRadius: 104, yRadius: 104)
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.13, alpha: 1).setFill()
        background.fill()

        let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 58, dy: 58), xRadius: 82, yRadius: 82)
        NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.21, alpha: 1).setFill()
        inner.fill()

        starPath(in: bounds.insetBy(dx: 126, dy: 118)).fill(with: NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.22, alpha: 1))

        let shadow = NSBezierPath(roundedRect: NSRect(x: 166, y: 86, width: 180, height: 54), xRadius: 27, yRadius: 27)
        NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.05, alpha: 0.34).setFill()
        shadow.fill()

        let dot = NSBezierPath(ovalIn: NSRect(x: 230, y: 104, width: 52, height: 52))
        NSColor(calibratedRed: 0.42, green: 0.88, blue: 0.58, alpha: 1).setFill()
        dot.fill()
        return image
    }

    private static func starPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.43

        for index in 0..<10 {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = CGFloat(index) * .pi / 5 - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        return path
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
