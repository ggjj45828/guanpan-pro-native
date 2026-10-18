import XCTest

final class WorkspaceExperienceTests: XCTestCase {
    private func launch(style: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GUANPAN_TESTING"] = "1"
        app.launchEnvironment["GUANPAN_UI_FIXTURE"] = "1"
        app.launchEnvironment["GUANPAN_UI_STYLE"] = style
        app.launch()
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testFiveWorkspacesAreReachableWithoutNASInLightAndDark() {
        for style in ["light", "dark"] {
            let app = launch(style: style)
            XCTAssertTrue(app.staticTexts["workspace.title"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.staticTexts["workspace.title"].label, "账户总览")
            capture(app, style + "-overview")
            for (tab, title) in [("行情", "行情工作台"), ("AI 决策", "投资决策"), ("量化实验室", "策略实验室"), ("资产", "我的资产")] {
                app.tabBars.buttons[tab].tap()
                XCTAssertTrue(app.staticTexts["workspace.title"].waitForExistence(timeout: 10))
                XCTAssertEqual(app.staticTexts["workspace.title"].label, title)
                capture(app, style + "-" + tab)
            }
            XCTAssertFalse(app.staticTexts["场外历史"].exists)
            app.terminate()
        }
    }
    @MainActor func testOfflineAdvisorRespondsAndConversationSurvivesRelaunch() {
        let app = launch()
        app.tabBars.buttons["AI 决策"].tap()
        app.buttons["和私人顾问聊聊"].tap()
        let field = app.textViews["advisor.question"].waitForExistence(timeout: 5) ? app.textViews["advisor.question"] : app.textFields["advisor.question"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("risk plan")
        app.buttons["advisor.send"].tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "离线规则顾问")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, "offline-advisor")
        app.terminate(); app.launch()
        app.tabBars.buttons["AI 决策"].tap(); app.buttons["和私人顾问聊聊"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "risk plan")).firstMatch.waitForExistence(timeout: 10))
    }
}
