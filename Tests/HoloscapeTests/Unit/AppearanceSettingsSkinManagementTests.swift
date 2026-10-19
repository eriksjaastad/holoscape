import AppKit
import XCTest
@testable import Holoscape

@MainActor
final class AppearanceSettingsSkinManagementTests: XCTestCase {
    private var root: URL!
    private var configService: ConfigService!
    private var engine: SkinEngine!
    private var library: SkinLibraryService!

    override func setUp() async throws {
        try await super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("appearance-skins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configService = ConfigService(configDir: root.appendingPathComponent("config"))
        engine = SkinEngine(skinsDirectoryOverride: root.appendingPathComponent("skins"), bundledSkinsDirectoryOverride: root.appendingPathComponent("bundle"))
        library = SkinLibraryService(engine: engine)
    }

    override func tearDown() async throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    func testButtonsAreAccessibleAndSafeByDefault() {
        let controller = TestAppearanceController(config: configService.load().appearance, configService: configService, skinEngine: engine, skinLibraryService: library)
        XCTAssertTrue(controller._createSkinButtonForTesting.accessibilityIdentifier() == "skin-create-button")
        XCTAssertFalse(controller._duplicateSkinButtonForTesting.isEnabled)
        XCTAssertFalse(controller._revealSkinButtonForTesting.isEnabled)
        XCTAssertFalse(controller._deleteSkinButtonForTesting.isEnabled)
    }

    func testCreateRefreshesSelectsAndUsesDelegateApplyPath() throws {
        let controller = TestAppearanceController(config: configService.load().appearance, configService: configService, skinEngine: engine, skinLibraryService: library)
        controller.promptedNames = ["Aurora"]
        let delegate = AppearanceDelegateSpy()
        controller.settingsDelegate = delegate

        controller._performCreateForTesting()

        XCTAssertTrue(engine.availableSkins().contains("Aurora"))
        XCTAssertEqual(controller._skinPopupForTesting.titleOfSelectedItem, "Aurora")
        XCTAssertEqual(delegate.selectedNames, ["Aurora"])
        XCTAssertEqual(delegate.changedConfigs.last?.skinName, "Aurora")
    }

    func testDuplicateRefreshesSelectsAndUsesDelegateApplyPath() throws {
        _ = try library.create(name: "Source")
        let controller = TestAppearanceController(config: configService.load().appearance, configService: configService, skinEngine: engine, skinLibraryService: library)
        controller._skinPopupForTesting.selectItem(withTitle: "Source")
        controller.promptedNames = ["Copy"]
        let delegate = AppearanceDelegateSpy()
        controller.settingsDelegate = delegate

        controller._performDuplicateForTesting()

        XCTAssertEqual(engine.loadSkin(named: "Copy")?.name, "Copy")
        XCTAssertEqual(controller._skinPopupForTesting.titleOfSelectedItem, "Copy")
        XCTAssertEqual(delegate.selectedNames, ["Copy"])
    }

    func testDeleteChooserExcludesActiveSkinAndDeletesConfirmedInactiveSkin() throws {
        _ = try library.create(name: "Active")
        _ = try library.create(name: "Inactive")
        var config = configService.load().appearance
        config.skinName = "Active"
        let controller = TestAppearanceController(config: config, configService: configService, skinEngine: engine, skinLibraryService: library)
        controller.skinChosenForDeletion = "Inactive"

        controller._performDeleteForTesting()

        XCTAssertEqual(controller.deletionChoices, ["Inactive"])
        XCTAssertTrue(controller.confirmationRequested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("skins/Active").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("skins/Inactive").path))
    }

    func testDeleteIsDisabledWhenNoInactiveUserSkinExists() throws {
        _ = try library.create(name: "Active")
        var config = configService.load().appearance
        config.skinName = "Active"
        let controller = TestAppearanceController(config: config, configService: configService, skinEngine: engine, skinLibraryService: library)
        XCTAssertFalse(controller._deleteSkinButtonForTesting.isEnabled)
        controller._performDeleteForTesting()
        XCTAssertFalse(controller.confirmationRequested)
    }

    func testRevealUsesSelectedResolvedURLWithoutOpeningFinderInTest() throws {
        let created = try library.create(name: "Revealable")
        let controller = TestAppearanceController(config: configService.load().appearance, configService: configService, skinEngine: engine, skinLibraryService: library)
        controller._skinPopupForTesting.selectItem(withTitle: "Revealable")

        controller._performRevealForTesting()

        XCTAssertEqual(controller.revealedURL, created)
    }

    func testTypedServiceErrorIsPresented() {
        let controller = TestAppearanceController(config: configService.load().appearance, configService: configService, skinEngine: engine, skinLibraryService: library)
        controller.promptedNames = ["Default"]
        controller._performCreateForTesting()
        XCTAssertEqual(controller.presentedError as? SkinLibraryError, .invalidName("Default"))
    }
}

@MainActor
private final class AppearanceDelegateSpy: AppearanceSettingsDelegate {
    var selectedNames: [String] = []
    var changedConfigs: [AppearanceConfig] = []
    func appearanceSettingsDidChange(_ settings: AppearanceConfig) { changedConfigs.append(settings) }
    func appearanceSettingsDidSelectSkin(_ name: String) { selectedNames.append(name) }
    func appearanceSettingsDidRequestScrollbackStorage() {}
}

@MainActor
private final class TestAppearanceController: AppearanceSettingsWindowController {
    var promptedNames: [String] = []
    var presentedError: Error?
    var confirmationRequested = false
    var deletionChoices: [String] = []
    var skinChosenForDeletion: String?
    var revealedURL: URL?

    override func promptForSkinName(title: String, message: String) -> String? { promptedNames.isEmpty ? nil : promptedNames.removeFirst() }
    override func confirmSkinDeletion(name: String) -> Bool { confirmationRequested = true; return true }
    override func chooseSkinForDeletion(from names: [String]) -> String? {
        deletionChoices = names
        return skinChosenForDeletion
    }
    override func revealSkinURL(_ url: URL) { revealedURL = url }
    override func showSkinError(_ error: Error) { presentedError = error }
}
