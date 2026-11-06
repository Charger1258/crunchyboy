import XCTest

final class NavigationTests: XCTestCase {
    @MainActor func testProfilesAndMainNavigation() throws {
        let app = XCUIApplication()
        app.launch()
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(app.staticTexts["Who’s watching?"].waitForExistence(timeout: 15))
        capture("01-profiles")
        let profile = app.buttons.matching(identifier: "profileChoice").firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5)); profile.tap()
        XCTAssertTrue(app.buttons["tab-0"].waitForExistence(timeout: 10))
        let featured = app.buttons["featuredShow"]
        _ = featured.waitForExistence(timeout: 20)
        capture("02-home")
        if featured.exists {
            featured.tap()
            _ = app.buttons.matching(identifier: "episodeRow").firstMatch.waitForExistence(timeout: 40)
            if app.buttons["Season 1"].exists { XCTAssertEqual(app.buttons["Season 1"].value as? String, "Selected") }
            capture("03-episodes")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.buttons["tab-1"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        capture("04-browse")
        app.buttons["tab-2"].tap()
        XCTAssertTrue(app.staticTexts["Your watch history"].waitForExistence(timeout: 5))
        capture("05-library")
        app.buttons["tab-3"].tap()
        XCTAssertTrue(app.staticTexts["Subtitle language"].waitForExistence(timeout: 5))
        capture("06-account")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Who’s watching?"].waitForExistence(timeout: 10))
        let unexpectedExit = expectation(for: NSPredicate { _, _ in app.state != .runningForeground }, evaluatedWith: nil)
        unexpectedExit.isInverted = true
        wait(for: [unexpectedExit], timeout: 5)
        XCTAssertFalse(app.buttons["tab-0"].exists, "Home must not be mounted behind the startup picker")
        capture("07-release-relaunch")
    }
}
