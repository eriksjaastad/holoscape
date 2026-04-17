import XCTest
@testable import Holoscape

/// Requirement 3.3: SkinContext falls back to built-in defaults for
/// surfaces not in the manifest. Requirement 12.4: state variants
/// evaluate in array order with last-match-wins semantics.
@MainActor
final class SkinContextResolutionTests: XCTestCase {

    // MARK: - Default fallback

    func testDefaultContextCoversEverySurfaceKey() {
        let snap = ReactiveUniformSnapshot()
        let ctx = SkinContext.builtInDefaults(reactive: snap)

        for key in SurfaceKey.allCases {
            _ = ctx.resolve(key)  // Must not crash; returns a default.
        }
        XCTAssertEqual(ctx.surfaces.count, SurfaceKey.allCases.count)
    }

    func testResolveReturnsDefaultForMissingSurface() {
        let snap = ReactiveUniformSnapshot()
        let ctx = SkinContext(surfaces: [:], reactive: snap)

        let resolved = ctx.resolve(.tabBarContainer)
        if case .color(let c) = resolved.fill {
            XCTAssertEqual(c.redComponent, 0.06, accuracy: 0.01)
        } else {
            XCTFail("Default tab bar container should be a color fill")
        }
    }

    // MARK: - State variant application

    func testCurrentStateWithNoVariantsReturnsBase() {
        let snap = ReactiveUniformSnapshot()
        let base = SkinContext.defaultSurface(for: .tabBarTabActive)
        let ctx = SkinContext(surfaces: [.tabBarTabActive: base], reactive: snap)

        let current = ctx.currentState(for: .tabBarTabActive)
        // Base fill unchanged.
        if case .color(let c1) = current.fill, case .color(let c2) = base.fill {
            XCTAssertEqual(c1, c2)
        } else {
            XCTFail("Fill should match base")
        }
    }

    func testStateVariantAppliesWhenMatches() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(3)  // error

        var base = SkinContext.defaultSurface(for: .tabBarTabActive)
        base.states = [
            StateVariant(
                name: "agentError",
                match: MatchExpression(conditions: ["agentState": .scalar(3)]),
                fill: .color("#ff0000")
            )
        ]
        let ctx = SkinContext(surfaces: [.tabBarTabActive: base], reactive: snap)

        let current = ctx.currentState(for: .tabBarTabActive)
        if case .color(let c) = current.fill {
            XCTAssertEqual(c.redComponent, 1.0, accuracy: 0.01, "Error variant should apply red fill")
        } else {
            XCTFail("Expected color fill after variant applied")
        }
    }

    func testStateVariantSkippedWhenNoMatch() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(0)  // idle — not matching error variant

        var base = SkinContext.defaultSurface(for: .tabBarTabActive)
        base.states = [
            StateVariant(
                name: "agentError",
                match: MatchExpression(conditions: ["agentState": .scalar(3)]),
                fill: .color("#ff0000")
            )
        ]
        let ctx = SkinContext(surfaces: [.tabBarTabActive: base], reactive: snap)

        let current = ctx.currentState(for: .tabBarTabActive)
        if case .color(let c) = current.fill {
            XCTAssertLessThan(c.redComponent, 0.5, "Base fill (not red) should still apply")
        } else {
            XCTFail("Expected color fill")
        }
    }

    func testLastMatchingStateWinsCSSCascade() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(3)

        var base = SkinContext.defaultSurface(for: .tabBarTabActive)
        base.states = [
            StateVariant(
                name: "anyError",
                match: MatchExpression(conditions: ["agentState": .operators(["$gte": 1])]),
                fill: .color("#ff0000")
            ),
            StateVariant(
                name: "errorSpecifically",
                match: MatchExpression(conditions: ["agentState": .scalar(3)]),
                fill: .color("#00ff00")  // Green wins — last match.
            )
        ]
        let ctx = SkinContext(surfaces: [.tabBarTabActive: base], reactive: snap)

        let current = ctx.currentState(for: .tabBarTabActive)
        if case .color(let c) = current.fill {
            XCTAssertEqual(c.greenComponent, 1.0, accuracy: 0.01, "Last matching variant (green) should win")
            XCTAssertLessThan(c.redComponent, 0.5, "Red variant should be overwritten")
        } else {
            XCTFail("Expected color fill")
        }
    }

    // MARK: - Operator evaluation

    func testEqualityOperator() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(2)
        let ctx = SkinContext.builtInDefaults(reactive: snap)

        let match = MatchExpression(conditions: ["agentState": .scalar(2)])
        XCTAssertTrue(ctx.evaluateMatch(match))

        let noMatch = MatchExpression(conditions: ["agentState": .scalar(3)])
        XCTAssertFalse(ctx.evaluateMatch(noMatch))
    }

    func testComparisonOperators() {
        let snap = ReactiveUniformSnapshot()
        snap.setChannelState(channelId: 1, isActive: 1, unread: 5)
        let ctx = SkinContext.builtInDefaults(reactive: snap)

        let gte = MatchExpression(conditions: ["channelUnread": .operators(["$gte": 1])])
        XCTAssertTrue(ctx.evaluateMatch(gte))

        let lt = MatchExpression(conditions: ["channelUnread": .operators(["$lt": 3])])
        XCTAssertFalse(ctx.evaluateMatch(lt))

        let between = MatchExpression(conditions: [
            "channelUnread": .operators(["$gte": 3, "$lte": 10])
        ])
        XCTAssertTrue(ctx.evaluateMatch(between))
    }

    func testMultiKeyMatchIsAnd() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(3)
        snap.setChannelState(channelId: 1, isActive: 1, unread: 2)
        let ctx = SkinContext.builtInDefaults(reactive: snap)

        let bothMatch = MatchExpression(conditions: [
            "agentState": .scalar(3),
            "channelIsActive": .scalar(1),
        ])
        XCTAssertTrue(ctx.evaluateMatch(bothMatch))

        let oneFails = MatchExpression(conditions: [
            "agentState": .scalar(3),
            "channelIsActive": .scalar(0),  // we're active, not inactive
        ])
        XCTAssertFalse(ctx.evaluateMatch(oneFails))
    }

    func testUnknownMatchKeyFailsGracefully() {
        let snap = ReactiveUniformSnapshot()
        let ctx = SkinContext.builtInDefaults(reactive: snap)

        let unknown = MatchExpression(conditions: ["nonexistentField": .scalar(1)])
        XCTAssertFalse(ctx.evaluateMatch(unknown), "Unknown keys should not match")
    }

    // MARK: - TimeSince

    func testTimeSinceMatchesRecentTransition() {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(1)  // stamps iTimeAgentStateChange
        let ctx = SkinContext.builtInDefaults(reactive: snap)

        let recent = MatchExpression(conditions: [
            "timeSince": .timeSince([
                "iTimeAgentStateChange": .operators(["$lt": 1.0])
            ])
        ])
        XCTAssertTrue(ctx.evaluateMatch(recent))
    }

    // MARK: - Convert descriptor → resolved surface

    func testConvertWithColorFill() {
        let desc = SurfaceDescriptor(fill: .color("#1a2b3c"))
        let resolved = SkinContext.convert(desc, for: .tabBarContainer)

        if case .color(let c) = resolved.fill {
            XCTAssertEqual(c.redComponent * 255, 0x1a, accuracy: 1.0)
            XCTAssertEqual(c.greenComponent * 255, 0x2b, accuracy: 1.0)
            XCTAssertEqual(c.blueComponent * 255, 0x3c, accuracy: 1.0)
        } else {
            XCTFail("Expected color fill")
        }
    }

    func testConvertWithCornerUniform() {
        let desc = SurfaceDescriptor(corner: .uniform(8))
        let resolved = SkinContext.convert(desc, for: .tabBarContainer)
        XCTAssertEqual(resolved.corner, .uniform(8))
    }

    func testConvertWithCornerAsymmetric() {
        let desc = SurfaceDescriptor(corner: .asymmetric(topLeft: 8, topRight: 8, bottomRight: 0, bottomLeft: 0))
        let resolved = SkinContext.convert(desc, for: .tabBarContainer)
        XCTAssertEqual(resolved.corner, .asymmetric(topLeft: 8, topRight: 8, bottomRight: 0, bottomLeft: 0))
    }

    func testConvertFallsBackToDefaultFillOnInvalidColor() {
        // Invalid hex string should leave base default in place.
        let desc = SurfaceDescriptor(fill: .color("not-a-color"))
        let resolved = SkinContext.convert(desc, for: .tabBarContainer)
        if case .color = resolved.fill {
            // Default color for tabBarContainer is the dark purple — accept any color result.
        } else {
            XCTFail("Invalid color should fall back to default fill")
        }
    }

    // MARK: - NSColor hex parser

    func testNSColorHexParserAcceptsValidFormats() {
        XCTAssertNotNil(NSColor(hex: "#ff0000"))
        XCTAssertNotNil(NSColor(hex: "ff0000"))
        XCTAssertNotNil(NSColor(hex: "#f00"))
        XCTAssertNotNil(NSColor(hex: "#ff0000aa"))
        XCTAssertNotNil(NSColor(hex: "#f00a"))
    }

    func testNSColorHexParserRejectsInvalid() {
        XCTAssertNil(NSColor(hex: ""))
        XCTAssertNil(NSColor(hex: "not-hex"))
        XCTAssertNil(NSColor(hex: "#gg0000"))
        XCTAssertNil(NSColor(hex: "#12345"))  // 5 chars is invalid
    }

    // MARK: - CALayer application smoke tests

    func testApplyColorFillToLayer() {
        let snap = ReactiveUniformSnapshot()
        let ctx = SkinContext.builtInDefaults(reactive: snap)
        let layer = CALayer()
        let resolved = ctx.resolve(.tabBarContainer)

        ctx.applyFill(to: layer, from: resolved)
        XCTAssertNotNil(layer.backgroundColor)
    }

    func testApplyGradientFillInsertsSublayer() {
        let snap = ReactiveUniformSnapshot()
        let ctx = SkinContext.builtInDefaults(reactive: snap)
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        let resolved = SkinContext.ResolvedSurface(
            fill: .gradient(.vertical, [
                GradientStop(offset: 0, color: "#000000"),
                GradientStop(offset: 1, color: "#ffffff"),
            ]),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )

        ctx.applyFill(to: layer, from: resolved)
        let gradientCount = layer.sublayers?.filter { $0 is CAGradientLayer }.count ?? 0
        XCTAssertEqual(gradientCount, 1, "Gradient fill should insert exactly one CAGradientLayer")
    }

    func testApplyGradientReplacesPreviousSublayer() {
        // Applying a gradient twice should leave exactly one sublayer, not two.
        let snap = ReactiveUniformSnapshot()
        let ctx = SkinContext.builtInDefaults(reactive: snap)
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        let resolved = SkinContext.ResolvedSurface(
            fill: .gradient(.horizontal, [
                GradientStop(offset: 0, color: "#ff0000"),
                GradientStop(offset: 1, color: "#0000ff"),
            ]),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )
        ctx.applyFill(to: layer, from: resolved)
        ctx.applyFill(to: layer, from: resolved)

        let gradientCount = layer.sublayers?.filter { $0 is CAGradientLayer }.count ?? 0
        XCTAssertEqual(gradientCount, 1, "Re-applying gradient must remove the previous sublayer")
    }

    func testApplyGradientWithInvalidHexAbortsCleanly() {
        // A bad hex in a gradient stop must NOT produce a mismatched CAGradientLayer.
        // Caller sees no sublayer inserted (rendering falls back to layer defaults).
        let snap = ReactiveUniformSnapshot()
        let ctx = SkinContext.builtInDefaults(reactive: snap)
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        let resolved = SkinContext.ResolvedSurface(
            fill: .gradient(.vertical, [
                GradientStop(offset: 0, color: "#000000"),
                GradientStop(offset: 1, color: "not-a-hex"),
            ]),
            border: nil, corner: .uniform(0), padding: .init(),
            shadow: nil, font: nil,
            text: .init(color: .white, shadow: nil),
            animation: nil, states: []
        )

        ctx.applyFill(to: layer, from: resolved)
        let gradientCount = layer.sublayers?.filter { $0 is CAGradientLayer }.count ?? 0
        XCTAssertEqual(gradientCount, 0, "Invalid gradient hex should abort, not insert broken sublayer")
    }

    func testApplyBorderAndCorner() {
        let snap = ReactiveUniformSnapshot()
        let ctx = SkinContext.builtInDefaults(reactive: snap)
        let layer = CALayer()

        var resolved = ctx.resolve(.tabBarContainer)
        resolved.border = SkinContext.ResolvedBorder(color: .black, width: 2.0)
        resolved.corner = .uniform(4.0)

        ctx.applyBorderAndCorner(to: layer, from: resolved)
        XCTAssertEqual(layer.borderWidth, 2.0)
        XCTAssertEqual(layer.cornerRadius, 4.0)
    }
}
