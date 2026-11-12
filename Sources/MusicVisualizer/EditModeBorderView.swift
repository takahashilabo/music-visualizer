import AppKit

/// Visible only while Edit Mode is on. Draws a dashed outline so the user can
/// see the window bounds, and handles dragging the whole panel (click
/// anywhere) or resizing it (click the bottom-right grip).
final class EditModeBorderView: NSView {
    private let gripSize: CGFloat = 18

    private var isResizing = false
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartFrame: NSRect = .zero

    private var gripRect: NSRect {
        NSRect(x: bounds.maxX - gripSize, y: bounds.minY, width: gripSize, height: gripSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1.0, alpha: 0.35).setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 1.5
        let dashPattern: [CGFloat] = [4, 3]
        outline.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        outline.stroke()

        NSColor(white: 1.0, alpha: 0.55).setFill()
        let r = gripRect
        let grip = NSBezierPath()
        grip.move(to: NSPoint(x: r.maxX - 3, y: r.minY + 3))
        grip.line(to: NSPoint(x: r.maxX - 3, y: r.maxY - 3))
        grip.line(to: NSPoint(x: r.minX + 3, y: r.minY + 3))
        grip.close()
        grip.fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        let location = convert(event.locationInWindow, from: nil)
        isResizing = gripRect.contains(location)
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartFrame = window.frame

        if !isResizing {
            window.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing, let window = window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartMouseLocation.x
        let dy = current.y - dragStartMouseLocation.y

        var newFrame = dragStartFrame
        newFrame.size.width = max(window.minSize.width, dragStartFrame.width + dx)
        newFrame.size.height = max(window.minSize.height, dragStartFrame.height - dy)
        newFrame.origin.y = dragStartFrame.origin.y + (dragStartFrame.height - newFrame.size.height)

        window.setFrame(newFrame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        isResizing = false
        (window as? VisualizerPanel)?.saveFrame()
    }
}
