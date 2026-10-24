import XCTest

final class WorkspaceExperienceTests: XCTestCase {
    private func launch(theme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GUANPAN_TESTING"] = "1"
        app.launchEnvironment["GUANPAN_UI_FIXTURE"] = "1"
        app.launchArguments += ["-guanpan.native.visualTheme", theme]
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testFiveThemeHomeAndAdvisorScreenshots() {
        let themes = [
            ("eastern", "01-东方编辑室"),
            ("modern", "02-现代卡片"),
            ("dashboard", "03-交易仪表盘"),
            ("magazine", "04-杂志卡片"),
            ("bento", "05-创意拼图")
        ]
        for (theme, name) in themes {
            let app = launch(theme: theme)
            XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.staticTexts["AI 今日指导"].firstMatch.waitForExistence(timeout: 15))
            capture(app, name + "-首页-演示数据")

            app.tabBars.buttons["行情"].tap()
            XCTAssertTrue(app.staticTexts["workspace.title"].waitForExistence(timeout: 10))
            capture(app, name + "-行情-演示数据")

            app.tabBars.buttons["持仓"].tap()
            XCTAssertTrue(app.staticTexts["真实持仓"].firstMatch.waitForExistence(timeout: 10))
            capture(app, name + "-持仓-演示数据")

            app.tabBars.buttons["AI"].tap()
            XCTAssertTrue(app.staticTexts["真实持仓 · 统一指导"].firstMatch.waitForExistence(timeout: 10))
            capture(app, name + "-AI指导-演示数据")
            XCTAssertFalse(app.buttons["自动下单"].exists)
            app.terminate()
        }
    }

    @MainActor func testMySettingsAndSyncOpenDistinctPages() {
        let app = launch(theme: "modern")
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 15))
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 10))

        let appSettings = app.buttons["more.app-settings"]
        XCTAssertTrue(appSettings.waitForExistence(timeout: 10))
        appSettings.tap()
        XCTAssertTrue(app.navigationBars["应用设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["视觉主题"].waitForExistence(timeout: 10))
        app.navigationBars["应用设置"].buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 10))

        let dataSync = app.buttons["more.data-sync"]
        XCTAssertTrue(dataSync.waitForExistence(timeout: 10))
        dataSync.tap()
        XCTAssertTrue(app.navigationBars["数据与同步"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["视觉主题"].exists)
        app.terminate()
    }

    @MainActor func testMyToolCardsNavigateWithoutTerminatingApp() {
        let app = launch(theme: "modern")
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 15))
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 10))

        for (card, title) in [("more.investor-profile", "AI 对我的了解"),
                              ("more.ai-settings", "手机 AI 设置"),
                              ("more.analysis-tools", "分析工具"),
                              ("more.planning-tools", "计划与复盘"),
                              ("more.app-settings", "应用设置"),
                              ("more.data-sync", "数据与同步")] {
            let button = app.buttons[card]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing \(card)")
            button.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "Failed to open \(title)")
            XCTAssertTrue(app.state == .runningForeground)
            app.navigationBars[title].buttons["我的"].tap()
            XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 10))
        }
        app.terminate()
    }
}
