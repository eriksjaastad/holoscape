import AppKit

@MainActor
final class ScreenVesselView: NSView {
    let viewportView = NSView()

    private let indicatorShelfView = NSView()
    private let indicatorAccentView = NSView()
    private let bodyBridgeView = NSView()
    private let viewportShadeView = NSView()
    private let footerTrackView = NSView()
    private var viewportConstraints: [NSLayoutConstraint] = []
    private var variant: ScreenVesselVariant = .plain

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("screen-vessel")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        indicatorShelfView.translatesAutoresizingMaskIntoConstraints = false
        indicatorShelfView.wantsLayer = true
        indicatorShelfView.layer?.cornerRadius = 9
        indicatorShelfView.layer?.masksToBounds = true
        addSubview(indicatorShelfView)

        indicatorAccentView.translatesAutoresizingMaskIntoConstraints = false
        indicatorAccentView.wantsLayer = true
        indicatorAccentView.layer?.cornerRadius = 1.5
        indicatorShelfView.addSubview(indicatorAccentView)

        bodyBridgeView.translatesAutoresizingMaskIntoConstraints = false
        bodyBridgeView.wantsLayer = true
        bodyBridgeView.layer?.cornerRadius = 5
        addSubview(bodyBridgeView)

        viewportView.identifier = NSUserInterfaceItemIdentifier("screen-vessel-viewport")
        viewportView.translatesAutoresizingMaskIntoConstraints = false
        viewportView.wantsLayer = true
        viewportView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(viewportView)

        viewportShadeView.translatesAutoresizingMaskIntoConstraints = false
        viewportShadeView.wantsLayer = true
        viewportShadeView.layer?.backgroundColor = NSColor.clear.cgColor
        viewportView.addSubview(viewportShadeView)

        footerTrackView.translatesAutoresizingMaskIntoConstraints = false
        footerTrackView.wantsLayer = true
        footerTrackView.layer?.cornerRadius = 1
        addSubview(footerTrackView)

        NSLayoutConstraint.activate([
            indicatorShelfView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            indicatorShelfView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            indicatorShelfView.widthAnchor.constraint(equalToConstant: 164),
            indicatorShelfView.heightAnchor.constraint(equalToConstant: 18),

            indicatorAccentView.leadingAnchor.constraint(equalTo: indicatorShelfView.leadingAnchor, constant: 10),
            indicatorAccentView.centerYAnchor.constraint(equalTo: indicatorShelfView.centerYAnchor),
            indicatorAccentView.widthAnchor.constraint(equalToConstant: 42),
            indicatorAccentView.heightAnchor.constraint(equalToConstant: 3),

            bodyBridgeView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            bodyBridgeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            bodyBridgeView.trailingAnchor.constraint(equalTo: indicatorShelfView.leadingAnchor, constant: -18),
            bodyBridgeView.heightAnchor.constraint(equalToConstant: 10),

            viewportShadeView.topAnchor.constraint(equalTo: viewportView.topAnchor),
            viewportShadeView.leadingAnchor.constraint(equalTo: viewportView.leadingAnchor),
            viewportShadeView.trailingAnchor.constraint(equalTo: viewportView.trailingAnchor),
            viewportShadeView.heightAnchor.constraint(equalToConstant: 18),

            footerTrackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            footerTrackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            footerTrackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -26),
            footerTrackView.heightAnchor.constraint(equalToConstant: 2),
        ])

        apply(layout: ScreenVesselLayoutDescriptor(
            viewportInsets: SkinLayoutInsets(top: 8, right: 8, bottom: 8, left: 8),
            variant: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func apply(layout: ScreenVesselLayoutDescriptor) {
        variant = layout.variant ?? .plain
        apply(insets: layout.viewportInsets)
        applyChrome()
    }

    func apply(insets: SkinLayoutInsets) {
        NSLayoutConstraint.deactivate(viewportConstraints)
        let constraints = [
            viewportView.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            viewportView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            viewportView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            viewportView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ]
        NSLayoutConstraint.activate(constraints)
        viewportConstraints = constraints
    }

    func mountContent(_ contentView: NSView) {
        contentView.removeFromSuperview()
        viewportView.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: viewportView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: viewportView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: viewportView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: viewportView.bottomAnchor),
        ])
    }

    private func applyChrome() {
        guard let layer else { return }

        switch variant {
        case .plain, .unsupported(_):
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderColor = nil
            layer.borderWidth = 0
            layer.cornerRadius = 0

            viewportView.layer?.backgroundColor = NSColor.clear.cgColor
            viewportView.layer?.borderColor = nil
            viewportView.layer?.borderWidth = 0
            viewportView.layer?.cornerRadius = 0
            viewportView.layer?.masksToBounds = false

            indicatorShelfView.isHidden = true
            indicatorShelfView.layer?.borderWidth = 0
            indicatorAccentView.layer?.backgroundColor = NSColor.clear.cgColor
            bodyBridgeView.layer?.backgroundColor = NSColor.clear.cgColor
            bodyBridgeView.layer?.borderColor = nil
            bodyBridgeView.layer?.borderWidth = 0
            viewportShadeView.layer?.backgroundColor = NSColor.clear.cgColor
            footerTrackView.layer?.backgroundColor = NSColor.clear.cgColor

        case .mercuryScreenBody:
            layer.backgroundColor = cgColor("#2e353a")
            layer.borderColor = cgColor("#626d75")
            layer.borderWidth = 1
            layer.cornerRadius = 16

            viewportView.layer?.backgroundColor = cgColor("#0f1418")
            viewportView.layer?.borderColor = cgColor("#2e3940")
            viewportView.layer?.borderWidth = 1
            viewportView.layer?.cornerRadius = 14
            viewportView.layer?.masksToBounds = true

            indicatorShelfView.isHidden = false
            indicatorShelfView.layer?.backgroundColor = cgColor("#3a4247", alpha: 0.92)
            indicatorShelfView.layer?.borderColor = cgColor("#69757c", alpha: 0.62)
            indicatorShelfView.layer?.borderWidth = 1
            indicatorAccentView.layer?.backgroundColor = cgColor("#7ba7bb", alpha: 0.7)

            bodyBridgeView.layer?.backgroundColor = cgColor("#434b51", alpha: 0.78)
            bodyBridgeView.layer?.borderColor = cgColor("#737d85", alpha: 0.42)
            bodyBridgeView.layer?.borderWidth = 1

            viewportShadeView.layer?.backgroundColor = cgColor("#6fa6c5", alpha: 0.05)
            footerTrackView.layer?.backgroundColor = cgColor("#7c878f", alpha: 0.36)
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
