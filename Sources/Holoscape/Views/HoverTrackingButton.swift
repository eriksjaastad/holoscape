import AppKit

/// NSButton base class that keeps hover state truthful across layout,
/// skin-driven view replacement, and app activation changes.
@MainActor
class HoverTrackingButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isPointerInside = false

    var hoverTrackingAreasForTesting: [NSTrackingArea] {
        hoverTrackingArea.map { [$0] } ?? []
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observeActivationChanges()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeActivationChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func observeActivationChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        reconcileHoverStateFromPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileHoverStateFromPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        reconcileHoverState(pointerInside: true, applicationIsActive: NSApp.isActive)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        reconcileHoverState(pointerInside: false, applicationIsActive: NSApp.isActive)
        super.mouseExited(with: event)
    }

    func reconcileHoverState(pointerInside: Bool, applicationIsActive: Bool) {
        let resolvedState = pointerInside && applicationIsActive
        guard resolvedState != isPointerInside else { return }
        isPointerInside = resolvedState
        hoverStateDidChange(isInside: resolvedState)
    }

    func hoverStateDidChange(isInside: Bool) {}

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        reconcileHoverStateFromPointer()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        reconcileHoverState(pointerInside: false, applicationIsActive: false)
    }

    private func reconcileHoverStateFromPointer() {
        guard let window, !isHidden, alphaValue > 0 else {
            reconcileHoverState(pointerInside: false, applicationIsActive: NSApp.isActive)
            return
        }
        let localPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        reconcileHoverState(
            pointerInside: bounds.contains(localPoint),
            applicationIsActive: NSApp.isActive
        )
    }
}
