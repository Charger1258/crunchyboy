import XCTest

final class QueueWidgetTests: XCTestCase {
    @MainActor func testWidgetLayoutsAndEmptyQueue() {
        let app = XCUIApplication()
        app.launchArguments = ["--queue-widget-ui-test"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Queue"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your next episode"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Continue your adventure"].exists)
        XCTAssertTrue(app.staticTexts["All caught up"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "queue-widget-layouts"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
