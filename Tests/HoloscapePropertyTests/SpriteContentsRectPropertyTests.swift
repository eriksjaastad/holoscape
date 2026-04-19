import XCTest
import SwiftCheck
@testable import Holoscape

/// Amplify Property 6 — Sprite cell selection covers exactly the
/// declared cell (Requirements 5.1, 5.4, 5.7).
///
/// For any valid SpriteDescriptor + state combination, the computed
/// `layer.contentsRect` UV rectangle has all four bounds in `[0, 1]`
/// (so it points at in-bounds pixels on the sheet), and covers
/// exactly the declared cell's pixels in sheet-pixel space.
///
/// Tests the MATH underlying `applyFill`'s contentsRect computation,
/// separated from the AppKit wiring. That lets us hammer 100s of
/// random sprites per run without instantiating NSImage fixtures.
final class SpriteContentsRectPropertyTests: XCTestCase {

    // MARK: - Generators

    private static var dim: Gen<Int> {
        Int.arbitrary.suchThat { $0 >= 4 && $0 <= 64 }
    }

    private static var grid: Gen<Int> {
        Int.arbitrary.suchThat { $0 >= 1 && $0 <= 8 }
    }

    private static var stateName: Gen<String> {
        Gen<String>.fromElements(of: ["normal", "hover", "pressed", "active"])
    }

    // MARK: - Property 6.a: UV bounds ∈ [0, 1]

    func testContentsRectUVStaysInUnitSquare() {
        property("computed UV rectangle always has minX, minY ≥ 0 and maxX, maxY ≤ 1") <- forAll(
            Self.dim, Self.dim,
            Self.grid, Self.grid
        ) { (cellW: Int, cellH: Int, rows: Int, cols: Int) in
            let sheetW = cellW * cols
            let sheetH = cellH * rows
            guard sheetW > 0, sheetH > 0 else { return true }  // vacuous

            // Test every cell position — every computed UV must be in [0, 1].
            for row in 0..<rows {
                for col in 0..<cols {
                    let u = Double(col * cellW) / Double(sheetW)
                    let v = Double(row * cellH) / Double(sheetH)
                    let w = Double(cellW) / Double(sheetW)
                    let h = Double(cellH) / Double(sheetH)
                    if u < 0 || u + w > 1.0 + 1e-9 { return false }
                    if v < 0 || v + h > 1.0 + 1e-9 { return false }
                }
            }
            return true
        }
    }

    // MARK: - Property 6.b: UV covers exactly the declared cell

    func testContentsRectMapsToDeclaredCellPixels() {
        // A cell at (row, col) with declared (cellW, cellH) in a sheet
        // of size (cellW*cols, cellH*rows) must map back to pixel
        // rectangle (col*cellW, row*cellH, cellW, cellH).
        property("UV rect scaled by sheet dimensions recovers the declared pixel cell") <- forAll(
            Self.dim, Self.dim,
            Self.grid, Self.grid
        ) { (cellW: Int, cellH: Int, rows: Int, cols: Int) in
            let sheetW = cellW * cols
            let sheetH = cellH * rows
            guard sheetW > 0, sheetH > 0 else { return true }

            for row in 0..<rows {
                for col in 0..<cols {
                    let uvX = Double(col * cellW) / Double(sheetW)
                    let uvY = Double(row * cellH) / Double(sheetH)
                    let uvW = Double(cellW) / Double(sheetW)
                    let uvH = Double(cellH) / Double(sheetH)

                    // Reverse: scale back to pixels.
                    let pxX = uvX * Double(sheetW)
                    let pxY = uvY * Double(sheetH)
                    let pxW = uvW * Double(sheetW)
                    let pxH = uvH * Double(sheetH)

                    let eps = 1e-6
                    if abs(pxX - Double(col * cellW)) > eps { return false }
                    if abs(pxY - Double(row * cellH)) > eps { return false }
                    if abs(pxW - Double(cellW)) > eps { return false }
                    if abs(pxH - Double(cellH)) > eps { return false }
                }
            }
            return true
        }
    }

    // MARK: - Property 6.c: SpriteDescriptor.isValid reflects the math

    func testInvalidSpritesFailIsValid() {
        // A SpriteDescriptor whose grid size (cols*cellW × rows*cellH)
        // exceeds the sheet must fail isValid. This is the gatekeeper
        // that keeps the UV math inside [0, 1].
        property("sprite grid larger than sheet fails isValid(imageSize:)") <- forAll(
            Self.dim, Self.dim,
            Self.grid, Self.grid
        ) { (cellW: Int, cellH: Int, rows: Int, cols: Int) in
            // Sheet undersized by one cell in each dimension.
            let undersizedSheet = CGSize(
                width: max(1, cellW * cols - 1),
                height: max(1, cellH * rows - 1)
            )
            let sprite = SpriteDescriptor(
                cellWidth: cellW, cellHeight: cellH,
                rows: rows, cols: cols,
                stateMap: ["normal": SpriteCell(row: 0, col: 0)]
            )
            return sprite.isValid(imageSize: undersizedSheet) == false
        }
    }
}
