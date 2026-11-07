import SwiftUI

// MARK: - 设计系统（深色高级质感）
//
// 参照三张 Dribbble 作品重建：墨绿近黑画布、比画布略亮一级的大圆角浮起卡片、
// 极细描边代替阴影、超大等宽数字、12pt 灰标签、柠檬绿强调 + 一条绿系 AI 渐变。
//
// 这里只放「长得一样」的东西（色、圆角、间距、字号、通用小部件），
// 业务含义一律不进这个文件 —— 涨跌红绿、金额口径仍然走 PnLColor / Formatting。

extension Color {
    /// 用十六进制字面量建色，避免到处写 `/255` 把色值算成小数后看不出原设计值。
    init(hex: UInt32, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// 一套设计令牌。深浅两套只有色值不同，尺寸与层级完全一致。
struct DsPalette {
    let isLight: Bool

    init(isLight: Bool) { self.isLight = isLight }

    // 画布：深色是墨绿近黑，浅色是极淡的冷灰。
    // 深色分支一律引用 TechGreen —— 与 AppTheme 的根背景层、弹窗背板同源，
    // 主题才不会在主页面与次级页面之间断掉。
    var canvasTop: Color { isLight ? Color(hex: 0xF7F8FA) : TechGreen.canvasTop }
    var canvasBottom: Color { isLight ? Color(hex: 0xEDEFF3) : TechGreen.canvasBottom }

    // 卡片：比画布亮一级即可，靠 1px 描边界定范围，不用阴影（阴影在近黑上看不见）。
    var card: Color { isLight ? Color.white : TechGreen.surface }
    var cardSoft: Color { isLight ? Color(hex: 0xF2F3F6) : TechGreen.surfaceSoft }
    var hairline: Color { isLight ? Color.black.opacity(0.07) : Color.white.opacity(0.07) }

    var ink: Color { isLight ? Color(hex: 0x101013) : Color.white }
    var ink2: Color { isLight ? Color(hex: 0x6E6E76) : Color(hex: 0x8C8C93) }
    var ink3: Color { isLight ? Color(hex: 0x9A9AA2) : Color(hex: 0x5B5B62) }

    var accent: Color { isLight ? Color(hex: 0x2F5BE8) : TechGreen.accent }
    var accentDim: Color { accent.opacity(isLight ? 0.12 : 0.18) }

    var canvas: LinearGradient {
        LinearGradient(colors: [canvasTop, canvasBottom], startPoint: .top, endPoint: .bottom)
    }

    static func of(_ appearance: AppAppearance) -> DsPalette {
        DsPalette(isLight: AppTheme.palette(for: appearance).isLight)
    }
}

/// 尺寸与层级常量。改这里就能整体收紧或放松节奏。
enum DS {
    static let radius: CGFloat = 22
    static let heroRadius: CGFloat = 26
    static let chipRadius: CGFloat = 12
    static let pad: CGFloat = 16
    static let pageInset: CGFloat = 18
    static let gap: CGFloat = 12
    /// 分区之间比卡片之间更松一点，读的时候才有段落感。
    static let sectionGap: CGFloat = 20

    // 字号：只留六级，避免每页各写一个数。
    static let fsHero: CGFloat = 34
    /// 次级大数字（卡片内的汇总值，比 hero 小一档）。
    static let fsStat: CGFloat = 26
    static let fsTitle: CGFloat = 17
    static let fsRow: CGFloat = 15
    static let fsLabel: CGFloat = 12
    static let fsMicro: CGFloat = 10.5

    /// AI 那一块专用的绿系渐变，整个 App 只有它用渐变。
    static var aiGradient: LinearGradient { TechGreen.aiGradient }
}

// MARK: - 卡片底

/// 统一卡片容器：实色卡面 + 1px 描边 + 连续圆角。
struct DsSurfaceModifier: ViewModifier {
    let palette: DsPalette
    var radius: CGFloat = DS.radius
    var padding: CGFloat = DS.pad
    /// 需要重点强调的卡（例如账户主卡）可以叠一层极淡的同色光。
    var glow: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background {
                shape.fill(palette.card)
            }
            .overlay {
                if let glow {
                    shape.fill(glow.opacity(0.06))
                }
            }
            .overlay {
                shape.strokeBorder(palette.hairline, lineWidth: 1)
            }
            .clipShape(shape)
    }
}

extension View {
    func dsSurface(_ palette: DsPalette,
                   radius: CGFloat = DS.radius,
                   padding: CGFloat = DS.pad,
                   glow: Color? = nil) -> some View {
        modifier(DsSurfaceModifier(palette: palette, radius: radius, padding: padding, glow: glow))
    }
}

// MARK: - 分区标题

/// 「市场脉搏 …………… 全部 ›」这种一行标题。右侧可选文字 + 点击。
struct DsSectionHeader: View {
    let palette: DsPalette
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .scaledFont(DS.fsTitle, weight: .semibold)
                .foregroundStyle(palette.ink)
            Spacer(minLength: 6)
            if let trailing {
                Button {
                    guard let action else { return }
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 2) {
                        Text(trailing).scaledFont(DS.fsLabel, weight: .medium)
                        if action != nil {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .foregroundStyle(palette.ink2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(action == nil)
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - 小部件

/// 左侧圆角小图标砖：参考稿里每行、每张卡前面都有一枚。
struct DsIconTile: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 38
    var palette: DsPalette = DsPalette(isLight: false)

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
            .fill(tint.opacity(palette.isLight ? 0.12 : 0.18))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(tint)
            }
    }
}

/// 涨跌胶囊：方向符号 + 百分比。颜色只做辅助，文字本身已能读。
struct DsDeltaPill: View {
    let text: String
    let tone: Color
    var palette: DsPalette = DsPalette(isLight: false)

    var body: some View {
        Text(text)
            .scaledFont(DS.fsLabel, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(tone.opacity(palette.isLight ? 0.10 : 0.16))
            }
    }
}

/// 迷你走势线：只画一条折线加淡渐变填充，不带坐标轴。
///
/// 用 `Path` 手画而不是上 Charts：这张图在列表里出现十几次，
/// Charts 的坐标轴与动画开销会让长列表滚动明显发涩。
struct DsSparkline: View {
    let values: [Double]
    let tint: Color
    var lineWidth: CGFloat = 1.6

    var body: some View {
        GeometryReader { geo in
            let path = Self.linePath(values: values, size: geo.size, lineWidth: lineWidth)
            ZStack {
                if let path {
                    Self.fillPath(from: path, size: geo.size)
                        .fill(LinearGradient(colors: [tint.opacity(0.26), tint.opacity(0.0)],
                                             startPoint: .top,
                                             endPoint: .bottom))
                    path.stroke(tint, style: StrokeStyle(lineWidth: lineWidth,
                                                         lineCap: .round,
                                                         lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// 归一化到绘制区域。点数不足 2 个时返回 nil —— 一个点画不出走势，不臆造。
    static func linePath(values: [Double], size: CGSize, lineWidth: CGFloat = 1.6) -> Path? {
        let points = values.filter { $0.isFinite }
        guard points.count > 1, size.width > 1, size.height > 1 else { return nil }
        var minValue = points[0]
        var maxValue = points[0]
        for value in points {
            minValue = min(minValue, value)
            maxValue = max(maxValue, value)
        }
        // 全等序列（例如停牌）给一条居中的水平线，不要除零。
        let span = maxValue - minValue
        let usableHeight = size.height - lineWidth * 2
        var path = Path()
        for (index, value) in points.enumerated() {
            let ratio = span > 0 ? (value - minValue) / span : 0.5
            let x = size.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = size.height - lineWidth - usableHeight * CGFloat(ratio)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    static func fillPath(from path: Path, size: CGSize) -> Path {
        var closed = path
        closed.addLine(to: CGPoint(x: size.width, y: size.height))
        closed.addLine(to: CGPoint(x: 0, y: size.height))
        closed.closeSubpath()
        return closed
    }
}

// MARK: - 主页大件

/// 账户主卡：标题 + 超大金额 + 涨跌一行 + 右侧箭头。
struct DsHeroCard: View {
    let palette: DsPalette
    let title: String
    let amount: String
    let deltaText: String
    let deltaTone: Color
    /// 副标题（数据时点之类），空串就不占位。
    var footnote: String = ""
    var sparkline: [Double] = []
    var onOpen: (() -> Void)? = nil
    /// 总额可不可信：不可信时传灰色，让数字在视觉上就低一档，
    /// 而不是「数字一模一样、只有小字不同」—— 后者没人会注意。
    var amountTone: Color? = nil
    /// 标题旁的小标记，例如「缓存估算」。
    var badge: String? = nil
    var badgeTone: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .scaledFont(DS.fsLabel, weight: .medium)
                    .foregroundStyle(palette.ink2)
                if let badge {
                    Text(badge)
                        .scaledFont(9.5, weight: .semibold)
                        .foregroundStyle(badgeTone ?? palette.ink2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule().fill((badgeTone ?? palette.ink2).opacity(palette.isLight ? 0.12 : 0.18))
                        }
                }
                Spacer(minLength: 6)
                if let onOpen {
                    Button {
                        Haptics.tap()
                        onOpen()
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.ink2)
                            .frame(width: 28, height: 28)
                            .background { Circle().fill(palette.cardSoft) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看资产明细")
                }
            }

            Text(amount)
                .scaledFont(DS.fsHero, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(amountTone ?? palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(deltaTone)
                Text(deltaText)
                    .scaledFont(DS.fsLabel, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(deltaTone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if sparkline.count > 1 {
                DsSparkline(values: sparkline, tint: palette.ink2.opacity(0.8), lineWidth: 1.4)
                    .frame(height: 34)
                    .padding(.top, 2)
            }

            if !footnote.isEmpty {
                Text(footnote)
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .lineLimit(3)
            }
        }
        .dsSurface(palette, radius: DS.heroRadius, padding: 18)
    }
}

/// 两宫格小卡（持仓市值 / 可用现金）。
struct DsStatTile: View {
    let palette: DsPalette
    let symbol: String
    let title: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 10) {
            DsIconTile(symbol: symbol,
                       tint: tint ?? palette.ink2,
                       size: 32,
                       palette: palette)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(DS.fsMicro, weight: .medium)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                Text(value)
                    .scaledFont(DS.fsRow, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .dsSurface(palette, radius: 18, padding: 12)
    }
}

/// AI 洞察横条：全 App 唯一的渐变色块。
struct DsAICard: View {
    let palette: DsPalette
    let title: String
    let subtitle: String
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.22)).frame(width: 38, height: 38)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .scaledFont(DS.fsRow, weight: .semibold)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .scaledFont(DS.fsMicro)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DS.aiGradient) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 快捷入口方块（网格 / 收息 / 基准…）。
struct DsQuickTile: View {
    let palette: DsPalette
    let symbol: String
    let title: String
    var badge: String? = nil
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity)
                    if let badge {
                        Text(badge)
                            .scaledFont(8.5, weight: .bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background { Capsule().fill(palette.accent) }
                            .offset(x: 8, y: -6)
                    }
                }
                .frame(height: 22)
                Text(title)
                    .scaledFont(DS.fsMicro, weight: .medium)
                    .foregroundStyle(palette.ink2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .dsSurface(palette, radius: 18, padding: 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 列表行外壳：图标砖 + 主副标题 + 右侧数值区，整行可点。
struct DsRowShell<Right: View>: View {
    let palette: DsPalette
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var sparkline: [Double] = []
    var sparkTint: Color = Color(hex: 0x8C8C93)
    let right: Right

    /// 显式初始化器：`@ViewBuilder` 修饰存储闭包属性时，成员初始化器是否继承
    /// 这个属性在各 Swift 版本上并不一致，这里直接构建出内容最稳。
    init(palette: DsPalette,
         symbol: String,
         tint: Color,
         title: String,
         subtitle: String,
         sparkline: [Double] = [],
         sparkTint: Color = Color(hex: 0x8C8C93),
         @ViewBuilder right: () -> Right) {
        self.palette = palette
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.sparkline = sparkline
        self.sparkTint = sparkTint
        self.right = right()
    }

    var body: some View {
        HStack(spacing: 12) {
            DsIconTile(symbol: symbol, tint: tint, size: 38, palette: palette)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(DS.fsRow, weight: .semibold)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if sparkline.count > 1 {
                DsSparkline(values: sparkline, tint: sparkTint)
                    .frame(width: 54, height: 24)
            }
            right
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
