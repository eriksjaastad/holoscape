import AppKit

@MainActor
final class ChannelVesselView: NSView {
    let topCapView = NSView()
    let viewportView = NSView()
    let bottomCapView = NSView()

    private let bodyShellView = NSView()
    private let trafficLightShelfView = NSView()
    private let shelfAccentView = NSView()
    private let joinRailView = NSView()
    private let leadingHighlightView = NSView()
    private let capDividerView = NSView()
    private let viewportRimView = NSView()
    private let viewportGlowView = NSView()
    private let footerLipView = NSView()

    private var topCapHeightConstraint: NSLayoutConstraint?
    private var bottomCapHeightConstraint: NSLayoutConstraint?
    private var bodyTopConstraint: NSLayoutConstraint?
    private var bodyBottomConstraint: NSLayoutConstraint?
    private var launcherConstraints: [NSLayoutConstraint] = []
    private var sidebarConstraints: [NSLayoutConstraint] = []
    private weak var launcherView: NSView?
    private weak var sidebarView: NSView?
    private var variant: ChannelVesselVariant = .plain

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("channel-vessel")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        bodyShellView.translatesAutoresizingMaskIntoConstraints = false
        bodyShellView.wantsLayer = true
        bodyShellView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(bodyShellView)

        for section in [topCapView, viewportView, bottomCapView] {
            section.translatesAutoresizingMaskIntoConstraints = false
            section.wantsLayer = true
            section.layer?.backgroundColor = NSColor.clear.cgColor
            bodyShellView.addSubview(section)
        }

        topCapView.identifier = NSUserInterfaceItemIdentifier("channel-vessel-top-cap")
        viewportView.identifier = NSUserInterfaceItemIdentifier("channel-vessel-viewport")
        bottomCapView.identifier = NSUserInterfaceItemIdentifier("channel-vessel-bottom-cap")

        configureChromeViews()

        let bodyTop = bodyShellView.topAnchor.constraint(equalTo: topAnchor)
        let bodyBottom = bodyShellView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bodyTopConstraint = bodyTop
        bodyBottomConstraint = bodyBottom

        let topCapHeight = topCapView.heightAnchor.constraint(equalToConstant: 72)
        let bottomCapHeight = bottomCapView.heightAnchor.constraint(equalToConstant: 48)
        topCapHeightConstraint = topCapHeight
        bottomCapHeightConstraint = bottomCapHeight

        NSLayoutConstraint.activate([
            bodyTop,
            bodyShellView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyShellView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyBottom,

            topCapView.topAnchor.constraint(equalTo: bodyShellView.topAnchor),
            topCapView.leadingAnchor.constraint(equalTo: bodyShellView.leadingAnchor),
            topCapView.trailingAnchor.constraint(equalTo: bodyShellView.trailingAnchor),
            topCapHeight,

            viewportView.topAnchor.constraint(equalTo: topCapView.bottomAnchor),
            viewportView.leadingAnchor.constraint(equalTo: bodyShellView.leadingAnchor),
            viewportView.trailingAnchor.constraint(equalTo: bodyShellView.trailingAnchor),

            bottomCapView.topAnchor.constraint(equalTo: viewportView.bottomAnchor),
            bottomCapView.leadingAnchor.constraint(equalTo: bodyShellView.leadingAnchor),
            bottomCapView.trailingAnchor.constraint(equalTo: bodyShellView.trailingAnchor),
            bottomCapHeight,
            bottomCapView.bottomAnchor.constraint(equalTo: bodyShellView.bottomAnchor),
        ])

        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func apply(layout: ChannelVesselLayoutDescriptor) {
        topCapHeightConstraint?.constant = layout.capStart
        bottomCapHeightConstraint?.constant = layout.capEnd
        variant = layout.variant ?? .plain
        applyChrome()
        refreshLauncherConstraints()
        refreshSidebarConstraints()
    }

    func mountLauncher(_ launcher: NSView) {
        launcherView = launcher
        launcher.removeFromSuperview()
        topCapView.addSubview(launcher)
        launcher.translatesAutoresizingMaskIntoConstraints = false
        refreshLauncherConstraints()
    }

    func mountSidebar(_ sidebar: NSView) {
        sidebarView = sidebar
        sidebar.removeFromSuperview()
        viewportView.addSubview(sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        refreshSidebarConstraints()
    }

    private func configureChromeViews() {
        joinRailView.translatesAutoresizingMaskIntoConstraints = false
        joinRailView.wantsLayer = true
        joinRailView.layer?.backgroundColor = NSColor.clear.cgColor
        bodyShellView.addSubview(joinRailView)

        leadingHighlightView.translatesAutoresizingMaskIntoConstraints = false
        leadingHighlightView.wantsLayer = true
        leadingHighlightView.layer?.backgroundColor = NSColor.clear.cgColor
        bodyShellView.addSubview(leadingHighlightView)

        trafficLightShelfView.translatesAutoresizingMaskIntoConstraints = false
        trafficLightShelfView.wantsLayer = true
        trafficLightShelfView.layer?.backgroundColor = NSColor.clear.cgColor
        trafficLightShelfView.layer?.cornerRadius = 10
        trafficLightShelfView.layer?.masksToBounds = true
        topCapView.addSubview(trafficLightShelfView)

        shelfAccentView.translatesAutoresizingMaskIntoConstraints = false
        shelfAccentView.wantsLayer = true
        shelfAccentView.layer?.cornerRadius = 2
        shelfAccentView.layer?.backgroundColor = NSColor.clear.cgColor
        trafficLightShelfView.addSubview(shelfAccentView)

        capDividerView.translatesAutoresizingMaskIntoConstraints = false
        capDividerView.wantsLayer = true
        capDividerView.layer?.backgroundColor = NSColor.clear.cgColor
        topCapView.addSubview(capDividerView)

        viewportRimView.translatesAutoresizingMaskIntoConstraints = false
        viewportRimView.wantsLayer = true
        viewportRimView.layer?.backgroundColor = NSColor.clear.cgColor
        viewportRimView.layer?.cornerRadius = 16
        viewportRimView.layer?.masksToBounds = true
        viewportView.addSubview(viewportRimView)

        viewportGlowView.translatesAutoresizingMaskIntoConstraints = false
        viewportGlowView.wantsLayer = true
        viewportGlowView.layer?.backgroundColor = NSColor.clear.cgColor
        viewportRimView.addSubview(viewportGlowView)

        footerLipView.translatesAutoresizingMaskIntoConstraints = false
        footerLipView.wantsLayer = true
        footerLipView.layer?.cornerRadius = 1.5
        footerLipView.layer?.backgroundColor = NSColor.clear.cgColor
        bottomCapView.addSubview(footerLipView)

        NSLayoutConstraint.activate([
            joinRailView.topAnchor.constraint(equalTo: topAnchor),
            joinRailView.trailingAnchor.constraint(equalTo: bodyShellView.trailingAnchor),
            joinRailView.bottomAnchor.constraint(equalTo: bodyShellView.bottomAnchor),
            joinRailView.widthAnchor.constraint(equalToConstant: 8),

            leadingHighlightView.topAnchor.constraint(equalTo: bodyShellView.topAnchor, constant: 6),
            leadingHighlightView.leadingAnchor.constraint(equalTo: bodyShellView.leadingAnchor, constant: 2),
            leadingHighlightView.bottomAnchor.constraint(equalTo: bodyShellView.bottomAnchor, constant: -10),
            leadingHighlightView.widthAnchor.constraint(equalToConstant: 3),

            trafficLightShelfView.topAnchor.constraint(equalTo: topCapView.topAnchor, constant: 8),
            trafficLightShelfView.leadingAnchor.constraint(equalTo: topCapView.leadingAnchor, constant: 12),
            trafficLightShelfView.trailingAnchor.constraint(equalTo: topCapView.trailingAnchor, constant: -10),
            trafficLightShelfView.heightAnchor.constraint(equalToConstant: 32),

            shelfAccentView.trailingAnchor.constraint(equalTo: trafficLightShelfView.trailingAnchor, constant: -8),
            shelfAccentView.centerYAnchor.constraint(equalTo: trafficLightShelfView.centerYAnchor),
            shelfAccentView.widthAnchor.constraint(equalToConstant: 28),
            shelfAccentView.heightAnchor.constraint(equalToConstant: 4),

            capDividerView.leadingAnchor.constraint(equalTo: topCapView.leadingAnchor, constant: 12),
            capDividerView.trailingAnchor.constraint(equalTo: topCapView.trailingAnchor, constant: -10),
            capDividerView.bottomAnchor.constraint(equalTo: topCapView.bottomAnchor, constant: -1),
            capDividerView.heightAnchor.constraint(equalToConstant: 1),

            viewportRimView.topAnchor.constraint(equalTo: viewportView.topAnchor, constant: 6),
            viewportRimView.leadingAnchor.constraint(equalTo: viewportView.leadingAnchor, constant: 4),
            viewportRimView.trailingAnchor.constraint(equalTo: viewportView.trailingAnchor, constant: -4),
            viewportRimView.bottomAnchor.constraint(equalTo: viewportView.bottomAnchor, constant: -6),

            viewportGlowView.topAnchor.constraint(equalTo: viewportRimView.topAnchor),
            viewportGlowView.leadingAnchor.constraint(equalTo: viewportRimView.leadingAnchor),
            viewportGlowView.trailingAnchor.constraint(equalTo: viewportRimView.trailingAnchor),
            viewportGlowView.heightAnchor.constraint(equalToConstant: 18),

            footerLipView.topAnchor.constraint(equalTo: bottomCapView.topAnchor, constant: 7),
            footerLipView.leadingAnchor.constraint(equalTo: bottomCapView.leadingAnchor, constant: 18),
            footerLipView.trailingAnchor.constraint(equalTo: bottomCapView.trailingAnchor, constant: -14),
            footerLipView.heightAnchor.constraint(equalToConstant: 3),
        ])
    }

    private func refreshLauncherConstraints() {
        NSLayoutConstraint.deactivate(launcherConstraints)
        launcherConstraints.removeAll()
        guard let launcher = launcherView else { return }
        let topAnchor: NSLayoutYAxisAnchor
        let topSpacing: CGFloat
        if variant == .mercuryControlSpine {
            topAnchor = trafficLightShelfView.bottomAnchor
            topSpacing = 8
        } else {
            topAnchor = topCapView.topAnchor
            topSpacing = 0
        }
        let constraints = [
            launcher.topAnchor.constraint(equalTo: topAnchor, constant: topSpacing),
            launcher.leadingAnchor.constraint(equalTo: topCapView.leadingAnchor, constant: 12),
            launcher.trailingAnchor.constraint(equalTo: topCapView.trailingAnchor, constant: -10),
            launcher.bottomAnchor.constraint(equalTo: topCapView.bottomAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate(constraints)
        launcherConstraints = constraints
    }

    private func refreshSidebarConstraints() {
        NSLayoutConstraint.deactivate(sidebarConstraints)
        sidebarConstraints.removeAll()
        guard let sidebar = sidebarView else { return }
        let insets = sidebarInsets(for: variant)
        let constraints = [
            sidebar.topAnchor.constraint(equalTo: viewportView.topAnchor, constant: insets.top),
            sidebar.leadingAnchor.constraint(equalTo: viewportView.leadingAnchor, constant: insets.left),
            sidebar.trailingAnchor.constraint(equalTo: viewportView.trailingAnchor, constant: -insets.right),
            sidebar.bottomAnchor.constraint(equalTo: viewportView.bottomAnchor, constant: -insets.bottom),
        ]
        NSLayoutConstraint.activate(constraints)
        sidebarConstraints = constraints
    }

    private func applyChrome() {
        guard let layer = bodyShellView.layer else { return }

        bodyTopConstraint?.constant = outerInsets(for: variant).top
        bodyBottomConstraint?.constant = -outerInsets(for: variant).bottom

        switch variant {
        case .plain, .unsupported(_):
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderColor = nil
            layer.borderWidth = 0
            layer.shadowOpacity = 0

            topCapView.layer?.backgroundColor = NSColor.clear.cgColor
            topCapView.layer?.borderColor = nil
            topCapView.layer?.borderWidth = 0

            viewportView.layer?.backgroundColor = NSColor.clear.cgColor
            viewportView.layer?.borderColor = nil
            viewportView.layer?.borderWidth = 0
            viewportView.layer?.cornerRadius = 0
            viewportView.layer?.masksToBounds = false

            bottomCapView.layer?.backgroundColor = NSColor.clear.cgColor
            bottomCapView.layer?.borderColor = nil
            bottomCapView.layer?.borderWidth = 0

            joinRailView.isHidden = true
            leadingHighlightView.isHidden = true
            trafficLightShelfView.isHidden = true
            trafficLightShelfView.layer?.borderWidth = 0
            shelfAccentView.layer?.backgroundColor = NSColor.clear.cgColor
            capDividerView.layer?.backgroundColor = NSColor.clear.cgColor
            viewportRimView.layer?.backgroundColor = NSColor.clear.cgColor
            viewportRimView.layer?.borderColor = nil
            viewportRimView.layer?.borderWidth = 0
            viewportGlowView.layer?.backgroundColor = NSColor.clear.cgColor
            footerLipView.layer?.backgroundColor = NSColor.clear.cgColor

        case .mercuryControlSpine:
            layer.backgroundColor = cgColor("#394248")
            layer.borderColor = cgColor("#838c93")
            layer.borderWidth = 1
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.28
            layer.shadowRadius = 10
            layer.shadowOffset = CGSize(width: 2, height: -1)

            topCapView.layer?.backgroundColor = cgColor("#4a535a", alpha: 0.68)
            topCapView.layer?.borderColor = cgColor("#737c84", alpha: 0.62)
            topCapView.layer?.borderWidth = 0.5

            viewportView.layer?.backgroundColor = cgColor("#11171b")
            viewportView.layer?.borderColor = cgColor("#657179")
            viewportView.layer?.borderWidth = 1
            viewportView.layer?.cornerRadius = 18
            viewportView.layer?.masksToBounds = true

            bottomCapView.layer?.backgroundColor = cgColor("#333b41", alpha: 0.82)
            bottomCapView.layer?.borderColor = cgColor("#5d676e", alpha: 0.48)
            bottomCapView.layer?.borderWidth = 0.5

            joinRailView.isHidden = false
            joinRailView.layer?.backgroundColor = cgColor("#171d22")
            joinRailView.layer?.borderColor = cgColor("#8e979d", alpha: 0.48)
            joinRailView.layer?.borderWidth = 1

            leadingHighlightView.isHidden = false
            leadingHighlightView.layer?.backgroundColor = cgColor("#a5b0b8", alpha: 0.7)

            trafficLightShelfView.isHidden = false
            trafficLightShelfView.layer?.backgroundColor = cgColor("#2a3339")
            trafficLightShelfView.layer?.borderColor = cgColor("#758088")
            trafficLightShelfView.layer?.borderWidth = 1
            shelfAccentView.layer?.backgroundColor = cgColor("#ffb347")

            capDividerView.layer?.backgroundColor = cgColor("#88939b", alpha: 0.42)

            viewportRimView.layer?.backgroundColor = cgColor("#0d1317", alpha: 0.35)
            viewportRimView.layer?.borderColor = cgColor("#566169", alpha: 0.72)
            viewportRimView.layer?.borderWidth = 1
            viewportGlowView.layer?.backgroundColor = cgColor("#6fa6c5", alpha: 0.08)

            footerLipView.layer?.backgroundColor = cgColor("#97a2aa", alpha: 0.58)
        }
    }

    private func sidebarInsets(for variant: ChannelVesselVariant) -> NSEdgeInsets {
        switch variant {
        case .mercuryControlSpine:
            return NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 8)
        case .plain, .unsupported(_):
            return NSEdgeInsetsZero
        }
    }

    private func outerInsets(for variant: ChannelVesselVariant) -> NSEdgeInsets {
        switch variant {
        case .mercuryControlSpine:
            return NSEdgeInsets(top: 6, left: 0, bottom: 24, right: 0)
        case .plain, .unsupported(_):
            return NSEdgeInsetsZero
        }
    }

    private func cgColor(_ hex: String, alpha: CGFloat? = nil) -> CGColor {
        let base = NSColor(hex: hex) ?? .clear
        if let alpha {
            return base.withAlphaComponent(alpha).cgColor
        }
        return base.cgColor
    }
}
