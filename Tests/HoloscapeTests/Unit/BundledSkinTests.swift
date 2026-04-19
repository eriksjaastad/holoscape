import XCTest
@testable import Holoscape

/// Task 13 coverage — bundled-skin enumeration + resolution + the
/// ninepatch-sidecar wiring through `SkinContext.convert`.
///
/// `Bundle.main.resourceURL` during test runs points at the test bundle,
/// not the Holoscape executable. So SkinEngine's `bundledSkinsDirectory`
/// honors an `HOLOSCAPE_BUNDLE_SKINS_DIR` env-var override — these tests
/// use it to stage a fake bundle root in a temp dir. The env var is
/// test-only; production uses `Bundle.main.resourceURL/Skins/`.
@MainActor
final class BundledSkinTests: XCTestCase {

    private var tempRoot: URL!
    private var userSkins: URL!
    private var bundledSkins: URL!
    private var originalConfigEnv: String?
    private var originalBundleEnv: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-bundledskin-\(UUID().uuidString)")
        userSkins = tempRoot.appendingPathComponent("user/skins")
        bundledSkins = tempRoot.appendingPathComponent("bundle/Skins")
        try FileManager.default.createDirectory(at: userSkins, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledSkins, withIntermediateDirectories: true)

        originalConfigEnv = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"]
        originalBundleEnv = ProcessInfo.processInfo.environment["HOLOSCAPE_BUNDLE_SKINS_DIR"]
        setenv("HOLOSCAPE_CONFIG_DIR", tempRoot.appendingPathComponent("user").path, 1)
        setenv("HOLOSCAPE_BUNDLE_SKINS_DIR", bundledSkins.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        restoreEnv("HOLOSCAPE_CONFIG_DIR", original: originalConfigEnv)
        restoreEnv("HOLOSCAPE_BUNDLE_SKINS_DIR", original: originalBundleEnv)
        try super.tearDownWithError()
    }

    // MARK: - Enumeration

    func testAvailableSkinsIncludesBundled() throws {
        try writeSkin(at: bundledSkins.appendingPathComponent("BundledTest"), windowColor: "#112233")
        let engine = SkinEngine()
        let names = engine.availableSkins()
        XCTAssertEqual(names.first, "Default", "Default stays first in the list")
        XCTAssertTrue(names.contains("BundledTest"),
                      "Bundled skins must appear in the picker alongside Default and user skins")
    }

    func testAvailableSkinsDedupesUserOverBundled() throws {
        // Same folder name in both locations. User dir wins — we want the
        // name to appear exactly once, sourced from the user location.
        try writeSkin(at: bundledSkins.appendingPathComponent("SharedName"), windowColor: "#aaaaaa")
        try writeSkin(at: userSkins.appendingPathComponent("SharedName"), windowColor: "#bbbbbb")
        let engine = SkinEngine()
        let occurrences = engine.availableSkins().filter { $0 == "SharedName" }.count
        XCTAssertEqual(occurrences, 1, "User + bundled with same name must appear exactly once in the picker")
    }

    // MARK: - Resolution

    func testLoadCompositeResolvesBundledSkin() throws {
        try writeSkin(at: bundledSkins.appendingPathComponent("BundledOnly"), windowColor: "#112233")
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "BundledOnly")
        XCTAssertEqual(loaded.name, "BundledOnly")
        guard let surfaces = loaded.surfaces,
              case .color(let color) = surfaces[.windowBackground]?.fill else {
            XCTFail("Expected window.background surface with color fill from the bundled manifest")
            return
        }
        // NSColor equality via sRGB components (0x11 = 17/255 ≈ 0.0667).
        XCTAssertEqual(color.redComponent, 17.0/255.0, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 34.0/255.0, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, 51.0/255.0, accuracy: 0.01)
    }

    func testUserSkinOverridesBundledByName() throws {
        // Same name, different window colors. loadComposite must return the
        // user version — proves resolveSkinDir picks user first.
        try writeSkin(at: bundledSkins.appendingPathComponent("SharedName"), windowColor: "#111111")
        try writeSkin(at: userSkins.appendingPathComponent("SharedName"),    windowColor: "#999999")
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "SharedName")
        guard let surfaces = loaded.surfaces,
              case .color(let color) = surfaces[.windowBackground]?.fill else {
            XCTFail("Expected window.background color fill")
            return
        }
        // 0x99 = 153/255 ≈ 0.6. Distinguishes user (#999) from bundle (#111).
        XCTAssertEqual(color.redComponent, 153.0/255.0, accuracy: 0.01,
                       "User-dir skin must override bundled skin of the same name")
    }

    // MARK: - Ninepatch wiring (Part 1.A pin)

    func testNinepatchSidecarFlowsThroughConvert() throws {
        // The load path used to pass nil for the sidecar inside
        // convertFill — a TODO comment acknowledged it. Part 1.A of
        // Task 13 wires it through via a ninepatches:[String: …] map.
        // This test pins the fix: load a skin with an image-fill surface
        // + a matching sidecar, and assert the resolved fill carries the
        // sidecar.
        let skin = userSkins.appendingPathComponent("NinepatchPin")
        try FileManager.default.createDirectory(
            at: skin.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        // Write a minimal valid PNG (16x16 red) so loadImages can decode it.
        let png = pngBytes(width: 16, height: 16, red: 0xff, green: 0x00, blue: 0x00)
        try png.write(to: skin.appendingPathComponent("assets/tile.png"))
        try Data(#"{"stretchX": [4, 12], "stretchY": [4, 12]}"#.utf8)
            .write(to: skin.appendingPathComponent("assets/tile.ninepatch.json"))
        try Data(#"""
        {
          "version": "2.0",
          "name": "NinepatchPin",
          "surfaces": {
            "sidebar.container": {
              "fill": { "kind": "image", "path": "assets/tile.png", "tile": "ninepatch" }
            }
          }
        }
        """#.utf8).write(to: skin.appendingPathComponent("skin.json"))

        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "NinepatchPin")
        guard let surfaces = loaded.surfaces,
              case .image(_, let tile, let sidecar, _) = surfaces[.sidebarContainer]?.fill else {
            XCTFail("Expected image fill on sidebarContainer")
            return
        }
        XCTAssertEqual(tile, .ninepatch)
        XCTAssertNotNil(sidecar, "Ninepatch sidecar must flow through loadComposite → convert")
        XCTAssertEqual(sidecar?.stretchX, [4, 12])
        XCTAssertEqual(sidecar?.stretchY, [4, 12])
    }

    // MARK: - Helpers

    nonisolated private func writeSkin(at dir: URL, windowColor: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {
          "version": "2.0",
          "name": "\(dir.lastPathComponent)",
          "surfaces": {
            "window.background": { "fill": { "kind": "color", "value": "\(windowColor)" } }
          }
        }
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("skin.json"))
    }

    nonisolated private func restoreEnv(_ name: String, original: String?) {
        if let original {
            setenv(name, original, 1)
        } else {
            unsetenv(name)
        }
    }

    /// Minimal uncompressed PNG — width × height pixels of a single RGB
    /// color. Avoids pulling in PIL/CoreGraphics for a test fixture.
    /// Uses a single IDAT with filter byte 0 per row, zlib stored-block
    /// encoding (no compression).
    nonisolated private func pngBytes(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> Data {
        // PNG signature
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        // IHDR
        var ihdr = Data()
        ihdr.append(uint32BE(UInt32(width)))
        ihdr.append(uint32BE(UInt32(height)))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])  // 8-bit, RGB color, no interlace
        out.append(chunk(type: "IHDR", data: ihdr))

        // IDAT — raw pixels framed with filter byte 0 per row, wrapped in
        // zlib stored-block format (no compression).
        var raw = Data()
        for _ in 0..<height {
            raw.append(0)  // filter: none
            for _ in 0..<width {
                raw.append(red)
                raw.append(green)
                raw.append(blue)
            }
        }
        out.append(chunk(type: "IDAT", data: zlibStored(raw)))

        // IEND
        out.append(chunk(type: "IEND", data: Data()))
        return out
    }

    nonisolated private func uint32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }

    nonisolated private func chunk(type: String, data: Data) -> Data {
        var out = Data()
        out.append(uint32BE(UInt32(data.count)))
        let typeBytes = Data(type.utf8)
        out.append(typeBytes)
        out.append(data)
        var crcInput = Data()
        crcInput.append(typeBytes)
        crcInput.append(data)
        out.append(uint32BE(crc32(crcInput)))
        return out
    }

    /// zlib "stored" format — no compression. One or more blocks each
    /// with a 5-byte header (BFINAL/BTYPE=00, LEN, NLEN). Keeps the
    /// fixture-PNG small and avoids pulling in zlib compression APIs.
    nonisolated private func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])  // zlib header (DEFLATE, FCHECK per RFC 1950)
        let maxBlock = 65535
        var remaining = data
        while !remaining.isEmpty {
            let blockSize = min(maxBlock, remaining.count)
            let isLast: UInt8 = (blockSize == remaining.count) ? 1 : 0
            let len = UInt16(blockSize)
            out.append(isLast)  // BFINAL (low bit), BTYPE=00
            out.append(UInt8(len & 0xff))
            out.append(UInt8(len >> 8))
            let nlen = ~len
            out.append(UInt8(nlen & 0xff))
            out.append(UInt8(nlen >> 8))
            out.append(remaining.prefix(blockSize))
            remaining = remaining.dropFirst(blockSize)
        }
        // Adler-32 checksum of the raw data.
        out.append(uint32BE(adler32(data)))
        return out
    }

    nonisolated private func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        let mod: UInt32 = 65521
        for byte in data {
            a = (a &+ UInt32(byte)) % mod
            b = (b &+ a) % mod
        }
        return (b << 16) | a
    }

    nonisolated private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) != 0 ? 0xedb88320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return crc ^ 0xffffffff
    }
}
