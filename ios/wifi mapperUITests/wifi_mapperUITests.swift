import XCTest
final class wifi_mapperUITests: XCTestCase {
    @MainActor func testInspectorViewsAndSelection() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-fixture"]; app.launch()
        app.tabBars.buttons["Signal"].tap()
        XCTAssertTrue(app.staticTexts["SIMULATED TEST DATA"].waitForExistence(timeout: 15))
        capture("Signal")
        app.swipeUp(); capture("RSSI density and statistics")
        app.tabBars.buttons["Networks"].tap()
        XCTAssertTrue(app.staticTexts["Demo Office"].waitForExistence(timeout: 5)); app.staticTexts["Demo Office"].tap(); capture("Networks")
        app.tabBars.buttons["Controls"].tap()
        XCTAssertTrue(app.buttons["connectUSB"].waitForExistence(timeout: 5)); capture("Controls")
        app.tabBars.buttons["Diagnostics"].tap()
        XCTAssertTrue(app.staticTexts["Firmware / protocol"].waitForExistence(timeout: 5)); capture("Diagnostics")
    }
    @MainActor func testSpatialMapAndOptions() throws {
        let app=XCUIApplication();app.launchArguments=["--ui-test-fixture"];app.launch()
        XCTAssertTrue(app.staticTexts["SIMULATED MAP"].waitForExistence(timeout:15))
        XCTAssertTrue(app.buttons["Fit map"].exists)
        capture("Top-down signal trail and heatmap")
        app.buttons["Map options"].tap()
        XCTAssertTrue(app.staticTexts["Live surface"].waitForExistence(timeout:5))
        capture("Mapping options and quality")
        app.buttons["Done"].tap()
        app.buttons["Saved surveys"].tap()
        XCTAssertTrue(app.navigationBars["Surveys"].waitForExistence(timeout:5))
        app.buttons["Done"].tap()
    }
    @MainActor func testRealCameraSurveyLifecycle() throws {
        let app=XCUIApplication();app.launch()
        app.buttons["surveyButton"].tap()
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout:3) {springboard.buttons["Allow"].tap()}
        XCTAssertTrue(app.buttons["Stop & save"].waitForExistence(timeout:15))
        capture("Real AR camera preview")
        app.buttons["Top down"].tap()
        XCTAssertTrue(app.buttons["Fit map"].waitForExistence(timeout:5))
        capture("Real AR top-down trace")
        app.buttons["surveyButton"].tap()
        XCTAssertTrue(app.buttons["Start survey"].waitForExistence(timeout:12))
        app.buttons["Saved surveys"].tap()
        XCTAssertTrue(app.navigationBars["Surveys"].waitForExistence(timeout:5))
        capture("Saved real AR survey")
        app.buttons["Done"].tap()
    }
    @MainActor func testUSBMappingDrain() throws {
        let app=XCUIApplication();app.launch()
        app.buttons["Connect USB"].tap()
        guard app.staticTexts["USB Ethernet · ready"].waitForExistence(timeout:12) else { throw XCTSkip("Requires ESP32 connected to iPhone over USB") }
        app.buttons["surveyButton"].tap()
        XCTAssertTrue(app.buttons["Stop & save"].waitForExistence(timeout:10))
        app.buttons["Top down"].tap()
        capture("Live USB spatial survey")
        app.buttons["surveyButton"].tap()
        XCTAssertTrue(app.buttons["Start survey"].waitForExistence(timeout:5), "A confirmed drain must finish before the eight-second fallback")
        capture("USB survey saved after drain")
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
