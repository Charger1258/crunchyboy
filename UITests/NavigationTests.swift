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
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        let featured = app.buttons["featuredShow"]
        _ = featured.waitForExistence(timeout: 20)
        capture("02-home")
        if featured.exists {
            featured.tap()
            _ = app.buttons.matching(identifier: "episodeRow").firstMatch.waitForExistence(timeout: 40)
            capture("03-episodes")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        capture("04-search")
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Subtitle language"].waitForExistence(timeout: 5))
        capture("05-settings")
    }
}
