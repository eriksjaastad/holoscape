import AppKit

@MainActor
protocol InputResizeHandleViewDelegate: AnyObject {
    func inputResizeHandleView(_ view: InputResizeHandleView, didDragBy deltaY: CGFloat)
}

@MainActor
final class InputResizeHandleView: NSView {
    weak var resizeDelegate: InputResizeHandleViewDelegate?

    private var lastDragY: CGFloat?
    private var skinContext: SkinContext?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("input-resize-handle")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Input panel resize handle")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    func apply(skinContext: SkinContext) {
        self.skinContext = skinContext
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        lastDragY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastDragY else {
            self.lastDragY = event.locationInWindow.y
            return
        }
        let currentY = event.locationInWindow.y
        resizeDelegate?.inputResizeHandleView(self, didDragBy: currentY - lastDragY)
        self.lastDragY = currentY
    }

    override func mouseUp(with event: NSEvent) {
        lastDragY = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let resolved = skinContext?.currentState(for: .inputBoxContainer)
        let accent = resolved?.border?.color ?? NSColor(hex: "#6fa6c5") ?? .systemBlue
        let base = resolvedFillColor(from: resolved) ?? NSColor(hex: "#151a1e") ?? .black

        let topLine = NSBezierPath()
        topLine.move(to: NSPoint(x: bounds.minX + 10, y: bounds.midY + 2))
        topLine.line(to: NSPoint(x: bounds.maxX - 10, y: bounds.midY + 2))
        accent.withAlphaComponent(0.42).setStroke()
        topLine.lineWidth = 1
        topLine.stroke()

        let grooveRect = NSRect(
            x: bounds.midX - 28,
            y: bounds.midY - 1,
            width: 56,
            height: 3
        )
        let groove = NSBezierPath(roundedRect: grooveRect, xRadius: 1.5, yRadius: 1.5)
        base.blended(withFraction: 0.35, of: accent)?.withAlphaComponent(0.9).setFill()
        groove.fill()

        let lowerLine = NSBezierPath()
        lowerLine.move(to: NSPoint(x: bounds.midX - 18, y: bounds.midY - 5))
        lowerLine.line(to: NSPoint(x: bounds.midX + 18, y: bounds.midY - 5))
        NSColor.black.withAlphaComponent(0.38).setStroke()
        lowerLine.lineWidth = 1
        lowerLine.stroke()
    }

    private func resolvedFillColor(from surface: SkinContext.ResolvedSurface?) -> NSColor? {
        guard let surface else { return nil }
        if case .color(let color) = surface.fill {
            return color
        }
        return nil
    }
}
