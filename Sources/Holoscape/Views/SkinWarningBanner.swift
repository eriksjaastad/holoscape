import AppKit

/// Amplify Task 21.2 — transient warning banner shown when a skin
/// fails to validate (Requirement 13.2). The engine still loads the
/// skin with a graceful-degradation fallback (drops the malformed
/// field, keeps everything else); the banner tells the skin author
/// which field was rejected and why so they can fix the manifest
/// without hunting the Console.
///
/// Behavior:
/// - Pinned to the top of its containing view, full-width.
/// - 40pt tall with the reason string centered.
/// - Fades in, holds for 5 seconds, fades out, removes itself.
/// - Reduce Motion (Req 15.4) skips the fade and shows + hides
///   instantly.
/// - `accessibilityLabel` carries the reason so VoiceOver users
///   hear the same message sighted users read.
///
/// Presentation API is a single static `show(in:reason:reduceMotion:)`
/// that handles install, teardown of any previous banner, and the
/// lifecycle timers. Callers don't manage instances.
@MainActor
final class SkinWarningBanner: NSView {

    /// Seconds the banner is visible at full opacity before starting
    /// its fade-out. Total banner lifetime = fadeIn + hold + fadeOut.
    static let holdDuration: TimeInterval = 5.0

    /// Fade duration in seconds. Skipped entirely when Reduce Motion
    /// is enabled — the banner appears and disappears instantly.
    static let fadeDuration: TimeInterval = 0.25

    private let label: NSTextField
    private var dismissWorkItem: DispatchWorkItem?

    init(reason: String) {
        self.label = NSTextField(labelWithString: reason)
        super.init(frame: .zero)

        wantsLayer = true
        // Amber-ish warning fill so it reads as "something's off"
        // without looking like a fatal error. System colors would
        // adapt to dark mode automatically, but the skinned window
        // may be transparent — a fixed color keeps the banner
        // legible on any skin.
        layer?.backgroundColor = NSColor(
            red: 0.90, green: 0.60, blue: 0.10, alpha: 0.95
        ).cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .black
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.staticText)
        setAccessibilityLabel(reason)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        fatalError("SkinWarningBanner is not storyboard-instantiable")
    }

    // MARK: - Presentation

    /// Install a banner at the top of `host` carrying `reason`. Any
    /// previously-installed banner is removed first so we never stack
    /// (multiple skin switches in a row should only ever show the
    /// latest reason). Returns the installed banner so tests can
    /// inspect it; callers in production ignore the return value.
    @discardableResult
    static func show(
        in host: NSView,
        reason: String,
        reduceMotion: Bool
    ) -> SkinWarningBanner {
        // Tear down any prior banner. Walking subviews avoids needing
        // the caller to track state; the banner is identified by type.
        for subview in host.subviews where subview is SkinWarningBanner {
            (subview as? SkinWarningBanner)?.dismissWorkItem?.cancel()
            subview.removeFromSuperview()
        }

        let banner = SkinWarningBanner(reason: reason)
        banner.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(banner, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            banner.topAnchor.constraint(equalTo: host.topAnchor),
            banner.heightAnchor.constraint(equalToConstant: 40),
        ])

        if reduceMotion {
            banner.alphaValue = 1.0
        } else {
            banner.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fadeDuration
                banner.animator().alphaValue = 1.0
            }
        }

        // Schedule auto-dismiss. Storing the work item on the banner
        // lets a subsequent `show(...)` cancel this one's fade-out
        // before it fires — the replacement banner owns its own timer.
        let dismiss = DispatchWorkItem { [weak banner] in
            banner?.dismiss(reduceMotion: reduceMotion)
        }
        banner.dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(
            deadline: .now() + holdDuration,
            execute: dismiss
        )

        return banner
    }

    private func dismiss(reduceMotion: Bool) {
        if reduceMotion {
            removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }
}
