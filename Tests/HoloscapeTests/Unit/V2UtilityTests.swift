import XCTest
@testable import Holoscape

final class V2UtilityTests: XCTestCase {

    // MARK: - ColorTheme

    func testAllSixThemesExist() {
        XCTAssertEqual(ColorTheme.allThemes.count, 6)
    }

    func testNamedFindsExistingTheme() {
        let dracula = ColorTheme.named("Dracula")
        XCTAssertNotNil(dracula)
        XCTAssertEqual(dracula?.name, "Dracula")
        XCTAssertEqual(dracula?.background, "#282a36")
    }

    func testNamedReturnsNilForUnknown() {
        XCTAssertNil(ColorTheme.named("NonExistent"))
    }

    func testAllThemesHave16AnsiColors() {
        for theme in ColorTheme.allThemes {
            XCTAssertEqual(theme.ansiColors.count, 16, "Theme \(theme.name) should have 16 ANSI colors")
        }
    }

    func testAllThemesHaveValidHexBackground() {
        for theme in ColorTheme.allThemes {
            XCTAssertTrue(theme.background.hasPrefix("#"), "Theme \(theme.name) background should be hex")
            XCTAssertEqual(theme.background.count, 7, "Theme \(theme.name) background should be 7 chars (#RRGGBB)")
        }
    }

    func testApplyWithoutOverrides() {
        let config = AppearanceConfig.default
        let result = ColorTheme.dracula.apply(to: config, overrides: nil)
        XCTAssertEqual(result.backgroundColor, "#282a36")
        XCTAssertEqual(result.ansiColors?["foreground"], "#f8f8f2")
    }

    func testApplyWithOverrides() {
        let config = AppearanceConfig.default
        let overrides = ["backgroundColor": "#000000", "foreground": "#ffffff"]
        let result = ColorTheme.dracula.apply(to: config, overrides: overrides)
        XCTAssertEqual(result.backgroundColor, "#000000")
        XCTAssertEqual(result.ansiColors?["foreground"], "#ffffff")
        // Non-overridden ANSI colors still come from theme
        XCTAssertEqual(result.ansiColors?["red"], "#ff5555")
    }

    // MARK: - TimestampInjector

    func testPrefixFormat() {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        var components = DateComponents()
        components.hour = 14
        components.minute = 30
        components.second = 45
        components.year = 2026
        components.month = 4
        components.day = 4
        let date = calendar.date(from: components)!
        let prefix = TimestampInjector.prefix(for: date)
        XCTAssertEqual(prefix, "[14:30:45] ")
    }

    func testPrefixMidnight() {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        var components = DateComponents()
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.year = 2026
        components.month = 1
        components.day = 1
        let date = calendar.date(from: components)!
        let prefix = TimestampInjector.prefix(for: date)
        XCTAssertEqual(prefix, "[00:00:00] ")
    }

    func testAddSecondsToGroupChatMessage() {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        var components = DateComponents()
        components.hour = 14
        components.minute = 30
        components.second = 45
        components.year = 2026
        components.month = 4
        components.day = 4
        let date = calendar.date(from: components)!

        let message = "[2:30 PM] erik: hello world"
        let result = TimestampInjector.addSeconds(to: message, date: date)
        XCTAssertEqual(result, "[2:30:45 PM] erik: hello world")
    }

    func testAddSecondsNoMatchReturnsOriginal() {
        let message = "no timestamp here"
        let result = TimestampInjector.addSeconds(to: message)
        XCTAssertEqual(result, "no timestamp here")
    }

    // MARK: - ElapsedTimeFormatter

    func testFormatNilReturnsNil() {
        XCTAssertNil(ElapsedTimeFormatter.format(since: nil))
    }

    func testFormatZeroMinutes() {
        let result = ElapsedTimeFormatter.format(since: Date())
        XCTAssertEqual(result, "0m")
    }

    func testFormat65Minutes() {
        let date = Date().addingTimeInterval(-65 * 60)
        let result = ElapsedTimeFormatter.format(since: date)
        XCTAssertEqual(result, "1h 5m")
    }

    func testFormat120Minutes() {
        let date = Date().addingTimeInterval(-120 * 60)
        let result = ElapsedTimeFormatter.format(since: date)
        XCTAssertEqual(result, "2h 0m")
    }

    func testFormat5Minutes() {
        let date = Date().addingTimeInterval(-5 * 60)
        let result = ElapsedTimeFormatter.format(since: date)
        XCTAssertEqual(result, "5m")
    }
}
