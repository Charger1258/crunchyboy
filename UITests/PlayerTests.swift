import XCTest

final class PlayerTests: XCTestCase {
    @MainActor func testLandscapeSubtitlesSeekingNextEpisodeAndPortraitExit() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--player-ui-test"]
        app.launch()
        let caption = app.staticTexts["subtitle-text"]
        XCTAssertTrue(caption.waitForExistence(timeout: 15))
        let landscape = expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }, evaluatedWith: nil)
        wait(for: [landscape], timeout: 10)
        func reveal() {
            if !app.buttons["Subtitles"].exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap() }
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        reveal()
        if app.buttons["Pause"].exists { app.buttons["Pause"].tap() }
        XCTAssertEqual(caption.label, "English subtitles are visible.")
        capture("player-01-landscape-English")
        app.buttons["Forward 10 seconds"].tap()
        let sought = expectation(for: NSPredicate { _, _ in caption.label.contains("synchronized after seeking") }, evaluatedWith: nil)
        wait(for: [sought], timeout: 5)
        app.buttons["Back 10 seconds"].tap()
        XCTAssertTrue(app.sliders["Episode timeline"].exists)
        app.buttons["Subtitles"].tap(); app.buttons["Arabic"].tap()
        let arabic = expectation(for: NSPredicate { _, _ in caption.label.contains("الترجمة العربية") }, evaluatedWith: nil)
        wait(for: [arabic], timeout: 5)
        capture("player-02-Arabic")
        app.buttons["next-episode"].tap()
        let retained = expectation(for: NSPredicate { _, _ in caption.exists && caption.label.contains("الترجمة العربية") }, evaluatedWith: nil)
        wait(for: [retained], timeout: 10)
        reveal()
        if app.buttons["Pause"].exists { app.buttons["Pause"].tap() }
        XCTAssertEqual(app.buttons["Subtitles"].value as? String, "Arabic")
        capture("player-03-next-episode-retains-language")
        app.buttons["Subtitles"].tap(); app.buttons["Off"].tap()
        XCTAssertFalse(caption.exists)
        app.buttons["Subtitles"].tap(); app.buttons["English"].tap()
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.staticTexts["Who’s watching?"].waitForExistence(timeout: 10))
        let portrait = expectation(for: NSPredicate { _, _ in app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width }, evaluatedWith: nil)
        wait(for: [portrait], timeout: 10)
    }
}
