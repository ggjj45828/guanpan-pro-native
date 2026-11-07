import SwiftUI

// MARK: - 主题语义色：表单 / 弹窗 / 固定确认区的唯一取色入口
//
// 「静态合同」见 `Tools/theme_contract.json` 与 `Tools/theme_contract.py`：
// 契约里声明了每套主题各语义色的色值与最低对比度，CI 会核对这里的 hex 与
// 契约一致、算 WCAG 对比度、并扫描受管文件里是否又混进了系统默认浅色样式。
//
// 为什么不能用 `.foregroundStyle(.secondary)` / `Color.primary`：
// 系统语义色跟的是 `colorScheme`，而本项目底色跟的是 `AppAppearance`。
// 两者在 `.system`、手动强调色、以及深浅切换的瞬间可能不同步，
// 结果就是「深色卡片配浅底」「辅助文字糊成一片」。所有文字一律走这里的 token。

struct ThemeSemantics {
    let style: AppLayoutStyle
    let isLight: Bool
    let layout: ThemeLayout

    // 页面 / 弹窗底
    let pageTop: Color
    let pageBottom: Color
    // 卡片面
    let card: Color
    let cardSoft: Color
    // 文字三级
    let ink: Color
    let ink2: Color
    let ink3: Color
    // 强调色与其上的文字
    let accent: Color
    let onAccent: Color
    // 语义状态色（涨跌沿用 PnLColor，这里只放表单用的警示 / 成功）
    let warn: Color
    let danger: Color
    let ok: Color

    /// 细描边。对比度不校验：它是 7% 透明度的分隔线，不是文字。
    var hairline: Color { isLight ? Color.black.opacity(0.09) : Color.white.opacity(0.10) }

    /// 固定底部确认区的背板：实色卡片面，不透明，避免下层内容透上来。
    var confirmBar: Color { card }

    /// 从任意外观（含 `.system`）解析出一套确定语义色。
    static func of(_ raw: AppAppearance) -> ThemeSemantics {
        let resolved = AppAppearance.resolved(raw)
        return resolved.layoutStyle == .ocean ? ocean : tech
    }

    static let tech = ThemeSemantics(
        style: .tech, isLight: false, layout: .tech,
        pageTop: Color(hex: 0x0A100C),      // contract: tech.pageTop
        pageBottom: Color(hex: 0x030604),   // contract: tech.pageBottom
        card: Color(hex: 0x121916),         // contract: tech.card
        cardSoft: Color(hex: 0x1A241E),     // contract: tech.cardSoft
        ink: Color(hex: 0xFFFFFF),          // contract: tech.ink
        ink2: Color(hex: 0x8C8C93),         // contract: tech.ink2
        // 原 ink3 是 #5B5B62，在 #121916 卡面上只有 2.6:1，提示文字读不出来。
        ink3: Color(hex: 0x7A7A82),         // contract: tech.ink3
        accent: Color(hex: 0xC8F751),       // contract: tech.accent
        onAccent: Color(hex: 0x0A100C),     // contract: tech.onAccent
        warn: Color(hex: 0xFBA833),         // contract: tech.warn
        danger: Color(hex: 0xF2555A),       // contract: tech.danger
        ok: Color(hex: 0x12C48C)            // contract: tech.ok
    )

    static let ocean = ThemeSemantics(
        style: .ocean, isLight: true, layout: .ocean,
        pageTop: Color(hex: 0xF7F8FA),      // contract: ocean.pageTop
        pageBottom: Color(hex: 0xEDEFF3),   // contract: ocean.pageBottom
        card: Color(hex: 0xFFFFFF),         // contract: ocean.card
        cardSoft: Color(hex: 0xF2F3F6),     // contract: ocean.cardSoft
        ink: Color(hex: 0x101013),          // contract: ocean.ink
        ink2: Color(hex: 0x6E6E76),         // contract: ocean.ink2
        // 原 ink3 是 #9A9AA2，白卡上只有 2.8:1；加深到 3.6:1。
        ink3: Color(hex: 0x85858E),         // contract: ocean.ink3
        accent: Color(hex: 0x2F5BE8),       // contract: ocean.accent
        onAccent: Color(hex: 0xFFFFFF),     // contract: ocean.onAccent
        warn: Color(hex: 0xB26A00),         // contract: ocean.warn
        danger: Color(hex: 0xD63A3A),       // contract: ocean.danger
        ok: Color(hex: 0x0F9C6C)            // contract: ocean.ok
    )
}

// MARK: - 受管视图的通用外壳

extension View {
    /// 表单 / 弹窗根视图统一铺主题底。所有 `.sheet` 内容都要挂。
    func themedFormBackground(_ s: ThemeSemantics) -> some View {
        background {
            LinearGradient(colors: [s.pageTop, s.pageBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    /// 固定底部确认区：实色背板 + 顶部 1px 分隔线，内容不会被滚动带跑。
    func themedConfirmBar(_ s: ThemeSemantics) -> some View {
        self
            .padding(.horizontal, s.layout.pageInset)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background {
                s.confirmBar.ignoresSafeArea(edges: .bottom)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(s.hairline).frame(height: 1)
            }
    }
}
