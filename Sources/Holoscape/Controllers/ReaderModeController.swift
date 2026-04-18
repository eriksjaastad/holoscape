import AppKit

/// Task 12 — Reader Mode.
///
/// A floating `NSPanel` alongside the main window displaying the active
/// channel's scrollback as plain text (ANSI escape codes stripped) in
/// SF Mono 14pt. Main window dims to alpha 0.4 while the panel is open.
///
/// Lifecycle owned by `MainWindowController`: one `ReaderModeController`
/// instance per app, constructed eagerly at window-controller init
/// (cheap — no NSPanel built until first `activate`). `activate(for:…)`
/// is the single entry point; `dismiss()` reverses each step.
///
/// The panel is **nonactivating** (`NSPanel.StyleMask.nonactivatingPanel`)
/// so it floats above without stealing key-window status from the main
/// window. Keystrokes continue flowing to the main window's first
/// responder (`inputBox`) even while Reader Mode is visible — that's
/// the 12.5 acceptance criterion ("console input focus stays in
/// MainWindowController's first responder chain").
///
/// Font is hardcoded to SF Mono 14pt regardless of the active skin
/// (Task 12.4). The Reader surface is deliberately skin-neutral so
/// errors, logs, and long output render at a predictable size no matter
/// what the rest of the chrome looks like.
@MainActor
final class ReaderModeController: NSObject, NSWindowDelegate {

    // MARK: - State

    private(set) var panel: NSPanel?
    private var textView: NSTextView?

    /// Main window's pre-dim alpha. Captured on `activate`, restored on
    /// `dismiss`. Default 1.0 — safe if activate somehow runs before any
    /// prior alpha change.
    private var savedAlpha: CGFloat = 1.0

    private weak var parentWindow: NSWindow?

    var isActive: Bool { panel?.isVisible == true }

    // MARK: - Lifecycle

    /// Build the panel, capture the active channel's scrollback, dim
    /// the main window, and show. Idempotent against repeat calls:
    /// re-activating re-fetches scrollback and updates the text view,
    /// but does not build a second panel.
    ///
    /// `animationEngine` is optional because the app's object graph
    /// does not currently own a shared `AnimationEngine` instance
    /// (backlog: wire one up alongside DensityModeManager). When nil,
    /// the suppression step is skipped — chrome animations continue
    /// running during Reader Mode. Visible impact: minor; the dim
    /// already communicates "you're not in the active session."
    func activate(
        for channel: any ChannelController,
        parentWindow: NSWindow,
        animationEngine: AnimationEngine?
    ) {
        self.parentWindow = parentWindow

        let panel = buildPanelIfNeeded(anchoring: parentWindow)

        // Snapshot scrollback. 10_000 is a generous upper bound —
        // roughly 500 screenfuls — and cheap to build. Tune after
        // dogfood if real sessions exceed this.
        let lines = channel.lastLines(10_000)
        let raw = lines.joined(separator: "\n")
        let stripped = ANSIStripper.strip(raw)
        // Empty-scrollback UX: a freshly-connected channel or a
        // disconnected-but-present tab can return zero lines. Show a
        // placeholder so the user sees "no output yet" instead of a
        // silent empty panel that looks broken.
        textView?.string = stripped.isEmpty ? "No output captured." : stripped
        // Scroll to the bottom so the user sees the most-recent output
        // first (matching the terminal's "newest at bottom" orientation).
        textView?.scrollToEndOfDocument(nil)

        // Dim main window. NSAnimationContext + animator() matches the
        // codebase's existing constraint-animation pattern — first time
        // we animate a window alphaValue in this project, but the API
        // surface is the same.
        savedAlpha = parentWindow.alphaValue
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            parentWindow.animator().alphaValue = 0.4
        }

        // Pause any in-flight chrome animations. No "resume" call on
        // dismiss is needed — AnimationEngine queues new animations on
        // the next state transition (tab switch, hover, agent state),
        // so chrome naturally resumes once the user returns to the
        // main window.
        animationEngine?.suppressAll()

        // Show as floating panel. orderFront (not makeKeyAndOrderFront)
        // so the main window keeps key status.
        panel.orderFront(nil)
    }

    /// Hide the panel and restore the main window's alpha. Safe to call
    /// when not active (no-op).
    func dismiss() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)

        if let parentWindow {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                parentWindow.animator().alphaValue = savedAlpha
            }
        }
    }

    // MARK: - NSWindowDelegate

    /// Close button → route through `dismiss` so the window-alpha
    /// restoration runs. Without this, clicking the panel's red dot
    /// would hide the panel but leave the main window at 0.4 alpha.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPanel,
              closing === panel else { return }
        dismiss()
    }

    // MARK: - Panel construction

    /// Build the panel on first call; return the existing one thereafter.
    /// Centred relative to `parent` so repeat activations start
    /// visually anchored rather than drifting off-screen.
    private func buildPanelIfNeeded(anchoring parent: NSWindow) -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            // `.nonactivatingPanel` keeps the main window as key window.
            // `.titled` gives us a drag handle + close button + title.
            // `.closable` + `.resizable` match the spec (draggable + resizable).
            // No `.utilityWindow` — utility-style chrome is visually too
            // light for a dedicated reader surface.
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Reader Mode"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false   // stay visible when app loses focus
        panel.isReleasedWhenClosed = false  // reuse across activate/dismiss cycles
        panel.delegate = self

        // Position relative to parent: anchor the reader's top-left to
        // the main window's top-right plus a small gap. Users can drag
        // it anywhere afterward; the panel itself remembers no position
        // between dismiss/activate cycles (by design — Reader Mode is
        // a transient, user-initiated surface, not a workspace).
        let parentFrame = parent.frame
        let origin = NSPoint(
            x: parentFrame.maxX + 10,
            y: parentFrame.maxY - 600
        )
        panel.setFrameOrigin(origin)

        // Content: scrollable, non-editable, selectable NSTextView.
        // Pattern lifted from BugReportDialog.swift:60-66.
        let scrollView = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.textColor
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        panel.contentView = scrollView

        self.panel = panel
        self.textView = textView
        return panel
    }
}
