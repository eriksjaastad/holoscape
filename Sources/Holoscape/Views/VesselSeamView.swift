import AppKit

@MainActor
final class VesselSeamView: NSView {
    private let recessBandView = NSView()
    private let ridgeBandView = NSView()
    private let shadowBandView = NSView()
    private let topBridgeView = NSView()

    private var style: VesselSeamStyle = .flat

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("vessel-seam")
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        for band in [recessBandView, ridgeBandView, shadowBandView, topBridgeView] {
            band.wantsLayer = true
            addSubview(band)
        }

        apply(style: .flat)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()

        let width = bounds.width
        let height = bounds.height
        let recessWidth = max(4, round(width * 0.35))
        let ridgeWidth = max(3, round(width * 0.2))
        let shadowWidth = max(0, width - recessWidth - ridgeWidth)

        recessBandView.frame = NSRect(x: 0, y: 0, width: recessWidth, height: height)
        ridgeBandView.frame = NSRect(x: recessWidth, y: 0, width: ridgeWidth, height: height)
        shadowBandView.frame = NSRect(x: recessWidth + ridgeWidth, y: 0, width: shadowWidth, height: height)
        topBridgeView.frame = NSRect(x: 0, y: 0, width: width, height: min(40, height))
    }

    func apply(style: VesselSeamStyle) {
        self.style = style
        switch style {
        case .flat, .unsupported(_):
            layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
            recessBandView.isHidden = true
            ridgeBandView.isHidden = true
            shadowBandView.isHidden = true
            topBridgeView.isHidden = true

        case .mechanical:
            layer?.backgroundColor = cgColor("#12171b")

            recessBandView.isHidden = false
            recessBandView.layer?.backgroundColor = cgColor("#171d22")

            ridgeBandView.isHidden = false
            ridgeBandView.layer?.backgroundColor = cgColor("#7a858d")

            shadowBandView.isHidden = false
            shadowBandView.layer?.backgroundColor = cgColor("#22292f")

            topBridgeView.isHidden = false
            topBridgeView.layer?.backgroundColor = cgColor("#39434a", alpha: 0.82)
            topBridgeView.layer?.borderColor = cgColor("#79848b", alpha: 0.55)
            topBridgeView.layer?.borderWidth = 1
        }
        needsLayout = true
    }

    private func cgColor(_ hex: String, alpha: CGFloat? = nil) -> CGColor {
        let base = NSColor(hex: hex) ?? .clear
        if let alpha {
            return base.withAlphaComponent(alpha).cgColor
        }
        return base.cgColor
    }
}
