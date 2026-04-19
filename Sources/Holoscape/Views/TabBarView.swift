import AppKit

@MainActor
protocol TabBarViewDelegate: AnyObject {
    func tabBarView(_ tabBar: TabBarView, didSelectChannelWithId id: UUID)
}

@MainActor
class TabBarView: NSView {
    weak var tabDelegate: TabBarViewDelegate?

    /// When non-nil, surfaces are resolved from the skin context. When
    /// nil, falls back to the pre-skinning hardcoded constants below so
    /// this view still renders standalone (used in XCUITest fixtures).
    var skinContext: SkinContext? {
        didSet { refreshFromSkin() }
    }

    // Built-in defaults matching the pre-skinning colors. Used only when
    // `skinContext == nil`; the SkinContext path produces identical
    // colors because `SkinContext.builtInDefaults` seeds the same values.
    private static let barBg = NSColor(red: 0.06, green: 0.06, blue: 0.12, alpha: 1.0).cgColor
    private static let activeTabBg = NSColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0).cgColor
    private static let idleBg = NSColor(red: 0.10, green: 0.22, blue: 0.12, alpha: 1.0).cgColor
    private static let permissionBg = NSColor(red: 0.24, green: 0.16, blue: 0.08, alpha: 1.0).cgColor

    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private var tabButtons: [UUID: NSButton] = [:]
    /// Tracking areas owned by the tab bar. One per button, re-built
    /// whenever `updateTabs` creates or removes buttons. Stored on the
    /// owning NSButton, but we retain references here so `teardown`
    /// can remove them when a button is retired (and so tests can
    /// inspect the per-button count).
    private var tabTrackingAreas: [UUID: NSTrackingArea] = [:]
    private var activeChannelId: UUID?
    private var notifications: [UUID: String] = [:]

    // MARK: - Amplify Task 11.3 sprite state tracking
    //
    // Per-tab hover + pressed state. When the cursor enters a tab, the
    // button's UUID lands in `hoveredTabId`; mouseDown moves it to
    // `pressedTabId` (which takes priority over hover for rendering).
    // `applyTabStyle` reads these and passes the resolved SpriteState
    // to `applyFill`. Both are `private(set) internal` so tests can
    // read them; only TabBarView's own handlers mutate.
    private(set) var hoveredTabId: UUID?
    private(set) var pressedTabId: UUID?

    private let tabHeight: CGFloat = 32
    private let tabPadding: CGFloat = 8
    private let tabSpacing: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupScrollView()
        setupSkinObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScrollView()
        setupSkinObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupScrollView() {
        wantsLayer = true
        layer?.backgroundColor = Self.barBg

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.setAccessibilityElement(false)
        contentView.setAccessibilityRole(.group)
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            contentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
    }

    private func setupSkinObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(skinDidChange(_:)),
            name: .skinDidChange,
            object: nil
        )
    }

    @objc private func skinDidChange(_ note: Notification) {
        refreshFromSkin()
    }

    /// Re-render container and every existing tab button from the
    /// current SkinContext. Routes through `applyFill(_:to:fallback:)`
    /// so gradient and image fills land correctly, not just color.
    /// Also called from `layout()` so gradient sublayers resize when
    /// the view grows — CAGradientLayer.autoresizingMask alone isn't
    /// always enough for sublayers under an NSView-backed layer.
    private func refreshFromSkin() {
        if let layer {
            applyFill(.tabBarContainer, to: layer, fallback: Self.barBg)
        }
        for (id, button) in tabButtons {
            applyTabStyle(button, channelId: id)
        }
    }

    override func layout() {
        super.layout()
        // Re-apply fills so any gradient sublayers pick up the new
        // bounds. Cheap when the fill is a solid color (just reassigns
        // backgroundColor); necessary for gradient and image fills
        // whose visible rendering depends on the parent layer's size.
        refreshFromSkin()
    }

    /// Apply a surface's full fill (color / gradient / image) to the
    /// given layer. When no skin is wired OR the resolved fill produces
    /// nothing visible, paint the hardcoded `fallback` color so the
    /// pre-skinning look is preserved.
    ///
    /// `spriteState` threads through to `SkinContext.applyFill` so
    /// sprite-sheet fills pick the correct UV cell for the caller's
    /// interactive state. Default `.normal` preserves the pre-Task-11.3
    /// behavior for any callers that haven't opted into state tracking.
    private func applyFill(
        _ key: SurfaceKey,
        to layer: CALayer,
        fallback: CGColor,
        spriteState: SpriteState = .normal
    ) {
        guard let ctx = skinContext else {
            layer.backgroundColor = fallback
            return
        }
        let resolved = ctx.currentState(for: key)
        let backingScale = window?.backingScaleFactor ?? 2.0
        ctx.applyFill(to: layer, from: resolved, backingScale: backingScale, spriteState: spriteState)
    }

    /// Apply a surface's fill to a layer, treating a transparent/no-fill
    /// outcome as "leave the layer alone" (used for `tabBarTabNormal`
    /// which has no hardcoded fallback — default is transparent).
    private func applyTransparentFill(
        _ key: SurfaceKey,
        to layer: CALayer,
        spriteState: SpriteState = .normal
    ) {
        guard let ctx = skinContext else {
            layer.backgroundColor = nil
            return
        }
        let resolved = ctx.currentState(for: key)
        let backingScale = window?.backingScaleFactor ?? 2.0
        ctx.applyFill(to: layer, from: resolved, backingScale: backingScale, spriteState: spriteState)
    }

    /// Amplify Task 11.3 — compute the SpriteState for `channelId`
    /// based on the view's per-tab hover + pressed tracking. Pressed
    /// wins over hover; hover wins over active; active wins over
    /// normal. The ordering matches user expectation (a pressed tab
    /// stays pressed even if it's also active, so the click feels
    /// responsive).
    ///
    /// Pulled out into its own function so the sprite-publishing tests
    /// can exercise the resolution rule without routing through AppKit.
    func spriteState(forTab channelId: UUID) -> SpriteState {
        if pressedTabId == channelId { return .pressed }
        if hoveredTabId == channelId { return .hover }
        if channelId == activeChannelId { return .active }
        return .normal
    }

    func updateTabs(channels: [any ChannelController], activeId: UUID?, pinnedIds: Set<UUID> = [], notifications: [UUID: String] = [:]) {
        activeChannelId = activeId
        self.notifications = notifications

        let currentIds = Set(channels.map { $0.channelId })

        // Remove buttons for channels that no longer exist
        for (id, button) in tabButtons where !currentIds.contains(id) {
            button.removeFromSuperview()
            tabButtons.removeValue(forKey: id)
        }

        var xOffset: CGFloat = tabSpacing

        for channel in channels {
            let button: NSButton
            if let existing = tabButtons[channel.channelId] {
                // Update existing button in place
                button = existing
                updateTabButton(button, for: channel)
            } else {
                // Only create new buttons for new channels
                button = makeTabButton(for: channel)
                contentView.addSubview(button)
                tabButtons[channel.channelId] = button
            }
            button.frame = NSRect(x: xOffset, y: 2, width: button.fittingSize.width + tabPadding * 2, height: tabHeight - 4)
            xOffset += button.frame.width + tabSpacing
        }

        contentView.frame = NSRect(x: 0, y: 0, width: max(xOffset, scrollView.contentView.bounds.width), height: tabHeight)
    }

    private func buildTabTitle(for channel: any ChannelController) -> String {
        var title = channel.displayLabel
        if let elapsed = ElapsedTimeFormatter.format(since: channel.activatedAt) {
            title += " (\(elapsed))"
        } else if channel.state == .connecting {
            title += " ..."
        }
        if channel.hasUnread {
            title = "\u{25CF} " + title
        }
        return title
    }

    private func updateTabButton(_ button: NSButton, for channel: any ChannelController) {
        let title = buildTabTitle(for: channel)
        button.title = title
        button.wantsLayer = true
        button.layer?.cornerRadius = 4

        applyTabStyle(button, channelId: channel.channelId)

        button.setAccessibilityTitle(title)
        button.setAccessibilityIdentifier("tab-\(channel.displayLabel)")
        if let notificationType = notifications[channel.channelId] {
            switch notificationType {
            case "idle_prompt":
                button.setAccessibilityValue("ready")
            case "permission_prompt":
                button.setAccessibilityValue("needs-approval")
            default:
                button.setAccessibilityValue(notificationType)
            }
        } else {
            button.setAccessibilityValue(channel.channelId == activeChannelId ? "active" : "normal")
        }
    }

    /// Apply the correct background fill and text tint for a tab based
    /// on its current state (active / permission / idle / normal). Each
    /// branch routes through `applyFill` so gradient/image fills land;
    /// only the `normal` case uses `applyTransparentFill` because a
    /// normal tab has no hardcoded fallback (transparent is correct).
    private func applyTabStyle(_ button: NSButton, channelId: UUID) {
        guard let buttonLayer = button.layer else { return }
        // Amplify Task 11.3 — resolve per-tab sprite state once and
        // pass it through every applyFill call below. Surfaces with
        // sprite descriptors pick the correct cell; surfaces without
        // render as before (spriteState parameter is ignored).
        let state = spriteState(forTab: channelId)
        if channelId == activeChannelId {
            button.contentTintColor = NSColor.white
            applyFill(.tabBarTabActive, to: buttonLayer,
                      fallback: Self.activeTabBg, spriteState: state)
        } else if notifications[channelId] == "permission_prompt" {
            button.contentTintColor = NSColor.white
            applyFill(.tabBarTabPermission, to: buttonLayer,
                      fallback: Self.permissionBg, spriteState: state)
        } else if notifications[channelId] == "idle_prompt" {
            button.contentTintColor = NSColor.white
            applyFill(.tabBarTabIdle, to: buttonLayer,
                      fallback: Self.idleBg, spriteState: state)
        } else {
            button.contentTintColor = NSColor.lightGray
            // `.tabBarTabNormal` default is transparent — nil
            // backgroundColor, no visible fill unless the skin overrides.
            applyTransparentFill(.tabBarTabNormal, to: buttonLayer, spriteState: state)
        }
        // Amplify Task 13 — apply skin-defined font. Sourced from
        // `.tabBarTabActive` as the canonical tab surface; if a skin
        // wants per-state fonts in the future, that's a forward-compat
        // extension (ResolvedSurface.font varies by surface, which is
        // already the model). When the manifest omits font, `resolvedFont`
        // returns nil and we preserve the pre-Amplify monospaced font
        // set in `makeTabButton`.
        if let font = skinContext?.resolvedFont(for: .tabBarTabActive) {
            button.font = font
        }
        // Amplify Task 15 — border/corner/shadow from the skin.
        // Pill-shape clamp (Req 7.5): cornerRadius capped at
        // buttonHeight / 2 so a skin declaring corner: 9999
        // produces a pill, not a collapsed circle. `buttonLayer`
        // may be nil on very early layout passes — guard.
        if let ctx = skinContext {
            let resolved = ctx.currentState(for: .tabBarTabActive)
            ctx.applyBorderAndCorner(
                to: buttonLayer,
                from: resolved,
                clampCornerToHalfHeight: button.bounds.height
            )
        }
    }

    private func makeTabButton(for channel: any ChannelController) -> NSButton {
        let title = buildTabTitle(for: channel)

        // Amplify Task 11.3 — use TabButton (NSButton subclass) so we
        // can capture mouseDown/mouseUp for sprite-state publishing
        // without fighting AppKit's internal click machinery.
        let button = TabButton(title: title, target: self, action: #selector(tabClicked(_:)))
        button.tabBar = self
        button.channelId = channel.channelId
        button.bezelStyle = .recessed
        button.isBordered = false
        button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        button.wantsLayer = true
        button.layer?.cornerRadius = 4

        // Store channel ID as tag via identifier
        button.identifier = NSUserInterfaceItemIdentifier(channel.channelId.uuidString)

        // Expose to accessibility / XCUITest
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityTitle(title)
        button.setAccessibilityIdentifier("tab-\(channel.displayLabel)")
        updateTabButton(button, for: channel)
        return button
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
              let id = UUID(uuidString: idString) else { return }
        tabDelegate?.tabBarView(self, didSelectChannelWithId: id)
    }

    // MARK: - Amplify Task 11.3 sprite state handlers
    //
    // Called from TabButton's mouseEntered / mouseExited / mouseDown /
    // mouseUp overrides. Each mutates the appropriate state slot and
    // triggers a refresh of the affected button so the sprite cell
    // updates within one layout pass. No global refresh — only the
    // button whose state changed needs repainting.
    //
    // `internal` visibility (not fileprivate) so TabButton — a nested
    // subclass — can call into them. Tests can also read these to
    // verify the sprite state machine without simulating real NSEvents.

    func handleTabButtonMouseEntered(_ channelId: UUID) {
        hoveredTabId = channelId
        refreshTabStyle(for: channelId)
    }

    func handleTabButtonMouseExited(_ channelId: UUID) {
        if hoveredTabId == channelId {
            hoveredTabId = nil
            refreshTabStyle(for: channelId)
        }
    }

    func handleTabButtonMouseDown(_ channelId: UUID) {
        pressedTabId = channelId
        refreshTabStyle(for: channelId)
    }

    func handleTabButtonMouseUp(_ channelId: UUID) {
        if pressedTabId == channelId {
            pressedTabId = nil
            refreshTabStyle(for: channelId)
        }
    }

    /// Refresh one tab button's style without touching siblings.
    /// Called from the mouse-event handlers above — no need to
    /// re-paint the whole tab bar on every hover transition.
    private func refreshTabStyle(for channelId: UUID) {
        guard let button = tabButtons[channelId] else { return }
        applyTabStyle(button, channelId: channelId)
    }
}

/// Amplify Task 11.3 — NSButton subclass that captures
/// mouseEntered/mouseExited via an installed NSTrackingArea AND
/// mouseDown/mouseUp via overrides. Each event forwards the tab's
/// channelId to its owning TabBarView, which mutates its sprite-
/// state slots and triggers a localized refresh.
///
/// Subclass over composition because:
///   1. NSTrackingArea's owner needs to receive the tracking events;
///      subclassing keeps the event dispatch path short.
///   2. mouseDown override keeps the button's native click behavior
///      (super.mouseDown) while layering sprite-state mutation on top.
@MainActor
final class TabButton: NSButton {
    weak var tabBar: TabBarView?
    var channelId: UUID?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove stale areas so repeated layout passes don't leak
        // them into the tracking-area list.
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        if let id = channelId { tabBar?.handleTabButtonMouseEntered(id) }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if let id = channelId { tabBar?.handleTabButtonMouseExited(id) }
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if let id = channelId { tabBar?.handleTabButtonMouseDown(id) }
        super.mouseDown(with: event)
        // super.mouseDown runs the modal tracking loop — when it
        // returns, the button has already released. Clear pressed
        // state here rather than relying on a separate mouseUp call
        // (AppKit's tracking loop swallows mouseUp internally).
        if let id = channelId { tabBar?.handleTabButtonMouseUp(id) }
    }
}
