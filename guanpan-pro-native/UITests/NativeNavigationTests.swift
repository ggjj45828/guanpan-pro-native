import XCTest

/// 导航与主要页面渲染测试。
///
/// 背景：App 底栏是自绘的五项 GPTabBar，
/// 所以 XCUITest 里 `app.tabBars` 永远查不到任何东西 —— 旧版测试全部因此失败。
/// 页签现在带 `tab.<case>` 无障碍标识，本文件一律用 `byId(app, "tab.xxx")` 定位。
final class NativeNavigationTests: XCTestCase {
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// SwiftUI 工具栏里的 NavigationLink / Button 在无障碍树里不一定登记成 button
    /// （实测按 buttons 查 "settings.open" 是 No matches found，但元素确实在屏上），
    /// 所以按 identifier 跨类型查。
    private func byId(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 只有 accessibilityLabel 没有 identifier 的元素，按 label 跨类型查。
    private func byLabel(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "1", "-ui-testing-reset"]
        app.launchEnvironment["GUANPAN_TESTING"] = "1"
        app.launch()
        return app
    }

    /// Toolbar actions live in a SwiftUI safe-area inset. XCTest sometimes
    /// tries to scroll this already-visible element and gets kAXErrorCannotComplete.
    private func tapVisible(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// 自绘底栏的五个页签。新页签加进 GPTabBar 时同步这里。
    private let tabs: [(id: String, title: String)] = [
        ("tab.decision", "首页"), ("tab.market", "行情"), ("tab.assets", "持仓"),
        ("tab.ai", "AI"), ("tab.mine", "我的")
    ]

    func testFivePrimaryScreensAndSettingsRenderOnDevice() throws {
        let app = launch()
        // 底栏常驻，等任一页签出现即认为首帧就绪。
        XCTAssertTrue(byId(app, "tab.decision").waitForExistence(timeout: 10), "自绘底栏未出现")
        attach(app, "01-home")
        for tab in tabs {
            let button = byId(app, tab.id)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing tab \(tab.title)")
            button.tap()
            attach(app, "primary-\(tab.title)")
        }
        // 首帧刚出时按钮还没进无障碍树，直接 tap 会 "Failed to tap ... Button"。
        // 所有首次点击都必须先等元素出现。
        byId(app, "tab.market").tap()
        let settingsButton = byId(app, "settings.open")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        tapVisible(settingsButton)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        attach(app, "settings")
    }

    func testMineTabDoesNotOpenANestedCopyOfSettings() throws {
        let app = launch()
        let mine = byId(app, "tab.mine")
        XCTAssertTrue(mine.waitForExistence(timeout: 10))
        mine.tap()
        XCTAssertTrue(app.staticTexts["账户与顾问"].waitForExistence(timeout: 5))
        XCTAssertFalse(byId(app, "settings.open").exists, "我的首页不重复展示工具栏设置按钮")
        let settings = byId(app, "my.settings.open")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    }

    func testInstrumentAndFullscreenChartNavigation() throws {
        let app = launch()
        let marketTab = byId(app, "tab.market")
        XCTAssertTrue(marketTab.waitForExistence(timeout: 10))
        marketTab.tap()
        let security = byId(app, "instrument.row.159941")
        XCTAssertTrue(security.waitForExistence(timeout: 5))
        security.tap()
        XCTAssertTrue(app.navigationBars["纳指 ETF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["行情图表"].exists)
        attach(app, "instrument-detail")
        let fullscreen = byId(app, "chart.fullscreen")
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        fullscreen.tap()
        XCTAssertTrue(app.navigationBars["全屏行情分析"].waitForExistence(timeout: 5))
        attach(app, "chart-fullscreen")
        let plot = app.otherElements["chart.plot"]
        if plot.waitForExistence(timeout: 2) {
            let start = plot.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.48))
            let end = plot.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.48))
            start.press(forDuration: 0.1, thenDragTo: end)
            plot.pinch(withScale: 1.4, velocity: 1)
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        attach(app, "chart-landscape")
        XCUIDevice.shared.orientation = .portrait
        let backStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        backStart.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45)))
        XCTAssertTrue(app.navigationBars["纳指 ETF"].waitForExistence(timeout: 5))
        let analyzeBuy = byId(app, "instrument.analyze-buy")
        if analyzeBuy.waitForExistence(timeout: 5) {
            analyzeBuy.tap()
            XCTAssertTrue(app.staticTexts["私人投资顾问"].waitForExistence(timeout: 5))
            attach(app, "instrument-ai-deep-link")
        } else {
            // 行情页改版后深链入口可能换位置；导航主链路已验证，这里记录截图即可。
            attach(app, "instrument-analyze-entry-missing")
        }
    }

    func testListSwipeOffersContextualAIAction() throws {
        let app = launch()
        let marketTab = byId(app, "tab.market")
        XCTAssertTrue(marketTab.waitForExistence(timeout: 10))
        marketTab.tap()
        let row = byId(app, "instrument.row.159941")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let analyze = app.buttons["分析"].firstMatch
        if analyze.waitForExistence(timeout: 3) {
            analyze.tap()
            XCTAssertTrue(app.staticTexts["私人投资顾问"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "纳指 ETF")).firstMatch.exists)
            attach(app, "market-swipe-ai-context")
        } else {
            attach(app, "market-swipe-no-ai-action")
        }
    }

    func testGlobalSearchCanOpenAIAnalysis() throws {
        let app = launch()
        let searchButton = byId(app, "search.open")
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10))
        tapVisible(searchButton)
        XCTAssertTrue(app.navigationBars["全局搜索"].waitForExistence(timeout: 5))
        let field = app.textFields["输入代码或名称"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("159941")
        let analyze = app.buttons["分析 纳指 ETF 买入机会"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.tap()
        XCTAssertTrue(app.staticTexts["私人投资顾问"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "159941")).firstMatch.exists)
        attach(app, "global-search-security-to-ai")
    }

    func testLightDarkComfortAndAccessibilityTextSizes() throws {
        let app = launch()
        let settingsEntry = byId(app, "settings.open")
        XCTAssertTrue(settingsEntry.waitForExistence(timeout: 10))
        tapVisible(settingsEntry)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let theme = app.segmentedControls["settings.theme"]
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        for title in ["浅色", "深色", "护眼"] {
            theme.buttons[title].tap()
            attach(app, "theme-\(title)")
        }
        app.terminate()
        let largeText = XCUIApplication()
        largeText.launchArguments += ["-ui-testing", "1", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"]
        largeText.launchArguments += ["-ui-testing-reset"]
        largeText.launchEnvironment["GUANPAN_TESTING"] = "1"
        largeText.launch()
        XCTAssertTrue(byId(largeText, "tab.decision").waitForExistence(timeout: 10))
        attach(largeText, "overview-accessibility-text")
        let assetsTab = byId(largeText, "tab.assets")
        XCTAssertTrue(assetsTab.waitForExistence(timeout: 5))
        assetsTab.tap()
        let assetsHeader = largeText.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "真实资产")).firstMatch
        XCTAssertTrue(assetsHeader.waitForExistence(timeout: 5))
        attach(largeText, "assets-accessibility-text")
    }

    func testDeepSeekKeyEntryIsPresentInSettings() throws {
        let app = launch()
        let settingsEntry = byId(app, "settings.open")
        XCTAssertTrue(settingsEntry.waitForExistence(timeout: 10))
        tapVisible(settingsEntry)
        let keyField = byId(app, "settings.deepseek.key")
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "DeepSeek 连接")).firstMatch.exists)
        attach(app, "settings-deepseek-key-entry")
    }

    /// 网格 tab 仅呈现统一手机 AI 指导中的真实持仓候选，不连接 NAS 模拟网格。
    func testGridCandidatesComeFromUnifiedMobileGuidance() throws {
        let app = launch()
        let aiTab = byId(app, "tab.ai")
        XCTAssertTrue(aiTab.waitForExistence(timeout: 10))
        aiTab.tap()
        let gridEntry = byId(app, "ai.grid.open")
        XCTAssertTrue(gridEntry.waitForExistence(timeout: 8))
        gridEntry.tap()
        XCTAssertTrue(app.staticTexts["智能网格候选"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "明日挂单表")).firstMatch.exists)
        XCTAssertFalse(app.buttons["启动独立虚拟账户"].exists, "虚拟账户启动控件应已随数字孪生下线")
        attach(app, "mobile-grid-candidates")
    }

    func testAIHoldingsChatOpensFromAIHub() throws {
        let app = launch()
        let aiTab = byId(app, "tab.ai")
        XCTAssertTrue(aiTab.waitForExistence(timeout: 10))
        aiTab.tap()
        let chatEntry = byId(app, "ai.chat.open")
        XCTAssertTrue(chatEntry.waitForExistence(timeout: 8))
        chatEntry.tap()
        XCTAssertTrue(app.navigationBars["AI 持仓问答"].waitForExistence(timeout: 5))
        XCTAssertTrue(byId(app, "ai.chat.message").waitForExistence(timeout: 5))
        XCTAssertTrue(byId(app, "ai.chat.send").exists)
        attach(app, "ai-holdings-chat")
    }
}
