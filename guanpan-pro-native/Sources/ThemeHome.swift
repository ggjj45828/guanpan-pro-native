import Foundation
import SwiftUI

// MARK: - 首页数据快照（五套主题共用同一份）

/// 五套首页布局读的是同一个 `HomeSnapshot`：
/// 切主题只换排版，持仓、行情、AI 结论、NAS 状态一个字都不会变。
struct HomeSnapshot {
    let now: Date
    let guidance: NextDailyGuidance?
    let lead: NextGuidanceItem?
    let positions: [NextPosition]
    let quotes: [String: NextQuote]
    let totalEquity: Decimal
    let pnlAmount: Decimal?
    let pnlPercent: Double?
    let cashPercent: Double
    let nasConfigured: Bool
    let nasReachable: Bool?
    let nasProbedAt: Date?
    let actionableCount: Int
    let profileTags: [String]
    let openPlanCount: Int
    let dataState: String
    let hasPositions: Bool

    var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return formatter.string(from: now)
    }

    var greeting: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        switch calendar.component(.hour, from: now) {
        case 5..<9: return "早上好"
        case 9..<12: return "上午好"
        case 12..<14: return "中午好"
        case 14..<18: return "下午好"
        default: return "晚上好"
        }
    }

    var headline: String {
        guard let guidance else { return "正在读取你的真实持仓…" }
        return guidance.summary
    }

    /// AI 卡正文：优先用「每只持仓一句话的结论」，而不是把顶部摘要原样再抄一遍。
    /// 参考稿里 AI 卡写的就是逐只标的的判断（"半导体…可关注一次反T机会。A500暂不建议操作。"）。
    var aiLines: [String] {
        let items = Array((guidance?.items ?? []).prefix(2))
        let lines = items.compactMap { $0.whyToday.first }.filter { !$0.isEmpty }
        return lines.isEmpty ? [headline] : lines
    }

    var marketStateText: String {
        guard let lead else { return "数据不足" }
        return lead.state.rawValue
    }

    var marketStateDetail: String {
        guard let lead else { return "还没有足够数据判断市场状态" }
        return lead.whyToday.first ?? "按日 K 与分时结构判断"
    }

    var nasText: String {
        guard nasConfigured else { return "未配置" }
        guard let nasReachable, let nasProbedAt else { return "待检测" }
        let age = max(0, Date().timeIntervalSince(nasProbedAt))
        guard age <= 360 else { return "状态待检测" }
        let minutes = Int(age / 60)
        if nasReachable { return minutes < 1 ? "刚刚检测在线" : "\(minutes) 分钟前在线" }
        return minutes < 1 ? "刚刚检测离线" : "\(minutes) 分钟前离线"
    }

    var nasOnline: Bool {
        nasConfigured && nasReachable == true && nasProbedAt.map { Date().timeIntervalSince($0) <= 360 } == true
    }

    @MainActor
    static func make(model: NextAppModel) -> HomeSnapshot {
        let guidance = model.dailyGuidance
        let quotes = Dictionary(uniqueKeysWithValues: model.quotes.map { ($0.key, $0.value.quote) })
        let positions = model.book.positions.filter { $0.units > 0 }
        var marketValue: Decimal = 0
        var costBasis: Decimal = 0
        for position in positions {
            if let quote = quotes[position.code], quote.price > 0 {
                marketValue += quote.price * Decimal(position.units)
            } else {
                marketValue += position.bookCost
            }
            costBasis += position.bookCost
        }
        let equity = marketValue + model.book.cash
        let pnl: Double? = costBasis > 0 ? NextNum.double((marketValue - costBasis) / costBasis * 100) : nil
        let cashPercent = equity > 0 ? NextNum.double(model.book.cash / equity * 100) : 0
        let items = guidance?.items ?? []
        let lead = items.first(where: { $0.isActionable }) ?? items.first
        return HomeSnapshot(now: Date(), guidance: guidance, lead: lead, positions: positions,
                            quotes: quotes, totalEquity: equity, pnlAmount: costBasis > 0 ? marketValue - costBasis : nil,
                            pnlPercent: pnl, cashPercent: cashPercent,
                            nasConfigured: !model.preferences.nasBaseURL.isEmpty,
                            nasReachable: model.nasReachable,
                            nasProbedAt: model.nasProbedAt,
                            actionableCount: items.filter(\.isActionable).count,
                            profileTags: model.profile.styleTags,
                            openPlanCount: model.candidatePlans.filter { $0.state.isOpen }.count,
                            dataState: guidance?.dataState ?? "本地规则",
                            hasPositions: !positions.isEmpty)
    }
}

// MARK: - 首页入口

struct ThemeHomeScreen: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p

    var body: some View {
        let snapshot = HomeSnapshot.make(model: model)
        ZStack {
            HomeBackground(theme: p.theme)
            Group {
                switch p.theme {
                case .editorial: EditorialHome(snapshot: snapshot)
                case .modern: ModernHome(snapshot: snapshot)
                case .dashboard: DashboardHome(snapshot: snapshot)
                case .magazine: MagazineHome(snapshot: snapshot)
                case .puzzle: PuzzleHome(snapshot: snapshot)
                }
            }
        }
        .task {
            if !model.preferences.nasBaseURL.isEmpty { await model.probeNAS(notifyOnFailure: false) }
            if model.dailyGuidance == nil { await model.refreshGuidance() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                if !model.preferences.nasBaseURL.isEmpty { await model.probeNAS(notifyOnFailure: false) }
            }
        }
    }
}

// MARK: - 背景（原创矢量装饰，不依赖任何图片资源）

private struct HomeBackground: View {
    @Environment(\.gp) private var p
    let theme: AppTheme

    var body: some View {
        ZStack {
            LinearGradient(colors: [p.canvas, p.canvasEdge, p.canvas],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            switch theme {
            case .editorial:
                EditorialBackdrop(tint: p.chartGold, ink: p.ink)
            case .magazine:
                MagazineBackdrop(tint: p.primary, ink: p.ink)
            case .puzzle:
                PuzzleBackdrop(tints: PuzzlePalette.tones(p.tokens).map(\.fill))
            case .dashboard:
                DashboardBackdrop(glow: p.primary, accent: p.secondary)
            case .modern:
                ModernBackdrop(tint: p.primary)
            }
        }
    }
}

/// 东方编辑室：暖色圆斑 + 远处城市剪影（原创路径，不是截图）。
private struct EditorialBackdrop: View {
    let tint: Color
    let ink: Color
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle().fill(tint.opacity(0.16))
                    .frame(width: geo.size.width * 0.9)
                    .offset(x: geo.size.width * 0.35, y: -geo.size.height * 0.06)
                    .blur(radius: 30)
                CitySilhouette().fill(ink.opacity(0.05))
                    .frame(width: geo.size.width * 0.7, height: 90)
                    .offset(x: 0, y: 78)
                // ③ 编辑室风格装饰插画人物（矢量原创，低透明度融入背景，不依赖图片）。
                ZStack(alignment: .bottomLeading) {
                    EditorialFigure(ink: ink, tint: tint)
                        .frame(width: min(geo.size.width * 0.52, CGFloat(200)), height: geo.size.height * 0.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .offset(x: -geo.size.width * 0.03, y: geo.size.height * 0.02)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }
}

/// ③ 编辑室风格装饰插画人物：矢量原创，原创路径（非截图）。
/// 低透明度，作为一个在暖色圆斑与城市剪影之间的"人物"装饰层，
/// 让东方编辑室首页更有"编辑室里有人在盯盘"的氛围，而非纯金融排版。
private struct EditorialFigure: View {
    let ink: Color
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // 裙身 / 大衣：上窄下宽的弧线轮廓
                Path { path in
                    path.move(to: CGPoint(x: geo.size.width * 0.34, y: geo.size.height * 0.46))
                    path.addCurve(to: CGPoint(x: geo.size.width * 0.16, y: geo.size.height),
                                  control1: CGPoint(x: geo.size.width * 0.20, y: geo.size.height * 0.70),
                                  control2: CGPoint(x: geo.size.width * 0.10, y: geo.size.height * 0.92))
                    path.addLine(to: CGPoint(x: geo.size.width * 0.84, y: geo.size.height))
                    path.addCurve(to: CGPoint(x: geo.size.width * 0.66, y: geo.size.height * 0.46),
                                  control1: CGPoint(x: geo.size.width * 0.90, y: geo.size.height * 0.92),
                                  control2: CGPoint(x: geo.size.width * 0.80, y: geo.size.height * 0.70))
                    path.addQuadCurve(to: CGPoint(x: geo.size.width * 0.34, y: geo.size.height * 0.46),
                                      control: CGPoint(x: geo.size.width * 0.50, y: geo.size.height * 0.38))
                }
                .fill(ink.opacity(0.055))
                // 一侧手臂 + 手持文档（折角纸张）
                Path { path in
                    path.move(to: CGPoint(x: geo.size.width * 0.60, y: geo.size.height * 0.50))
                    path.addQuadCurve(to: CGPoint(x: geo.size.width * 0.86, y: geo.size.height * 0.66),
                                      control: CGPoint(x: geo.size.width * 0.78, y: geo.size.height * 0.54))
                }
                .stroke(ink.opacity(0.06), style: StrokeStyle(lineWidth: geo.size.width * 0.07, lineCap: .round))
                RoundedRectangle(cornerRadius: geo.size.width * 0.02, style: .continuous)
                    .fill(tint.opacity(0.10))
                    .frame(width: geo.size.width * 0.20, height: geo.size.height * 0.24)
                    .rotationEffect(.degrees(-14))
                    .offset(x: geo.size.width * 0.74, y: geo.size.height * 0.40)
                // 头发（脑后大弧，飘逸感）
                Path { path in
                    path.addEllipse(in: CGRect(x: geo.size.width * 0.34, y: geo.size.height * 0.04,
                                               width: geo.size.width * 0.30, height: geo.size.height * 0.26))
                }
                .fill(ink.opacity(0.07))
                // 脸
                Circle().fill(tint.opacity(0.12))
                    .frame(width: geo.size.width * 0.17, height: geo.size.height * 0.16)
                    .offset(x: geo.size.width * 0.05, y: geo.size.height * 0.12)
            }
        }
    }
}

private struct CitySilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let base = rect.maxY
        let unit = rect.width / 12
        let heights: [CGFloat] = [0.32, 0.52, 0.4, 0.68, 0.48, 0.8, 0.56, 0.72, 0.44, 0.6, 0.36, 0.5]
        path.move(to: CGPoint(x: 0, y: base))
        for (index, ratio) in heights.enumerated() {
            let x = CGFloat(index) * unit
            let top = base - rect.height * ratio
            path.addLine(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x + unit * 0.82, y: top))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: base))
        path.closeSubpath()
        return path
    }
}

private struct MagazineBackdrop: View {
    let tint: Color
    let ink: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                BlossomBranch()
                    .stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: geo.size.width * 0.55, height: 150)
                    .offset(y: 28)
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: CGFloat(6 + index * 2))
                        .offset(x: -CGFloat(18 + index * 26), y: CGFloat(60 + index * 14))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .allowsHitTesting(false)
    }
}

private struct BlossomBranch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: 0))
        path.addCurve(to: CGPoint(x: rect.midX + 10, y: rect.height * 0.55),
                      control1: CGPoint(x: rect.width * 0.7, y: rect.height * 0.12),
                      control2: CGPoint(x: rect.width * 0.62, y: rect.height * 0.42))
        path.addCurve(to: CGPoint(x: rect.midX - 26, y: rect.height * 0.72),
                      control1: CGPoint(x: rect.midX - 2, y: rect.height * 0.62),
                      control2: CGPoint(x: rect.midX - 14, y: rect.height * 0.66))
        return path
    }
}

private struct PuzzleBackdrop: View {
    let tints: [Color]
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(tints.prefix(3).enumerated()), id: \.offset) { index, color in
                    RoundedRectangle(cornerRadius: 60, style: .continuous)
                        .fill(color.opacity(0.10))
                        .frame(width: geo.size.width * (0.42 + CGFloat(index) * 0.1))
                        .rotationEffect(.degrees(Double(index) * 24 - 12))
                        .offset(x: CGFloat(index) * 90 - 40, y: CGFloat(index) * 220 - 40)
                        .blur(radius: 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

private struct DashboardBackdrop: View {
    let glow: Color
    let accent: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                RadialGradient(colors: [glow.opacity(0.28), .clear],
                               center: .topLeading, startRadius: 10, endRadius: geo.size.width * 0.9)
                RadialGradient(colors: [accent.opacity(0.16), .clear],
                               center: .topTrailing, startRadius: 6, endRadius: geo.size.width * 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ModernBackdrop: View {
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            Circle().fill(tint.opacity(0.10))
                .frame(width: geo.size.width * 0.8)
                .offset(x: geo.size.width * 0.4, y: -geo.size.height * 0.14)
                .blur(radius: 28)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 通用小组件

/// 自绘顶部条：搜索 + 设置，两个入口与原来一模一样，只是跟着主题换样式。
private struct HomeTopBar: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    var leading: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let leading {
                Text(leading).font(.system(size: 12, weight: .semibold)).foregroundStyle(p.muted)
            }
            Spacer()
            Button { model.showSearch = true } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(p.ink).frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("全局搜索证券")
            Button { model.push(.settings, in: .decision) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(p.ink).frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("设置")
        }
    }
}

/// 涨跌小色块 + 百分比。所有价格变动统一走这里，保证五套主题都是「红涨绿跌」。
private struct ChangePill: View {
    @Environment(\.gp) private var p
    let percent: Double?
    var compact = false

    var body: some View {
        let tone = p.changeTone(percent ?? 0)
        Text(percent.map { "\($0 >= 0 ? "+" : "")\(String(format: "%.2f", $0))%" } ?? "—")
            .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(tone)
            .lineLimit(1).minimumScaleFactor(0.8)
    }
}

/// 迷你走势线：只用真实分时/日 K 收盘价，取不到就不画。
private struct Sparkline: View {
    let values: [Double]
    let tone: Color
    var body: some View {
        GeometryReader { geo in
            let points = normalized(in: geo.size)
            if points.count > 1 {
                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(tone, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                Path { path in
                    path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                    path.addLine(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [tone.opacity(0.28), tone.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, size.width > 0, size.height > 0 else { return [] }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let span = max(0.000001, high - low)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let ratio = (value - low) / span
            return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(ratio)) * 0.92 + 2)
        }
    }
}

/// 主要指数：上证（新浪）+ 深证成指 / 创业板指（腾讯→东财→新浪链），全部真实数据。
private struct HomeIndexBoard: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    enum Style: Equatable { case chips, cards, tiles, editorialRow }
    let style: Style

    @State private var rows: [IndexRow] = []
    @State private var message = ""
    @State private var loading = false

    struct IndexRow: Identifiable {
        let id: String
        /// 短名（编辑室四联卡用，参考稿就是「上证 / 深证 / 创业板」）。
        let name: String
        /// 全名（现代/杂志/仪表盘的指数卡用，参考稿是「上证指数 / 深证成指 / 创业板指」）。
        let fullName: String
        let price: Double
        let percent: Double?
        let spark: [Double]
    }

    private var columns: [GridItem] {
        // 三个指数一律等宽；各主题只改变色彩与装饰，不再让指数卡因主题切换而忽宽忽窄。
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(rows) { row in
                    cell(row)
                }
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 9)).foregroundStyle(p.muted).lineLimit(2)
            }
        }
        .task { if rows.isEmpty { await load() } }
    }

    @ViewBuilder
    private func cell(_ row: IndexRow) -> some View {
        let tone = p.changeTone(row.percent ?? 0)
        switch style {
        case .chips, .editorialRow:
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(p.muted).lineLimit(1)
                Text(NextNum.text(row.price, digits: 2))
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(tone)
                    .lineLimit(1).minimumScaleFactor(0.7)
                ChangePill(percent: row.percent, compact: true)
            }
            .padding(.horizontal, 7).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 100, alignment: .topLeading)
            .background(p.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: p.chipRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: p.chipRadius, style: .continuous).stroke(tone.opacity(0.18), lineWidth: 0.8))
        case .cards:
            VStack(alignment: .leading, spacing: 5) {
                Text(row.fullName).font(.system(size: 10, weight: .medium)).foregroundStyle(p.muted).lineLimit(1)
                Text(NextNum.text(row.price, digits: 2))
                    .font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tone).lineLimit(1).minimumScaleFactor(0.65)
                ChangePill(percent: row.percent)
                Sparkline(values: row.spark, tone: tone).frame(height: 22)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 100, alignment: .topLeading)
            .background(p.paper, in: RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous).stroke(p.line, lineWidth: 0.8))
        case .tiles:
            VStack(alignment: .leading, spacing: 5) {
                Text(row.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted).lineLimit(1)
                Text(NextNum.text(row.price, digits: 2))
                    .font(.system(size: 15, weight: .bold, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(tone).lineLimit(1).minimumScaleFactor(0.6)
                ChangePill(percent: row.percent, compact: true)
                Sparkline(values: row.spark, tone: tone).frame(height: 18)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 100, alignment: .topLeading)
            .background(p.paperAlt, in: RoundedRectangle(cornerRadius: p.chipRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: p.chipRadius, style: .continuous).stroke(tone.opacity(0.22), lineWidth: 0.8))
        }
    }

    private var nasCell: some View {
        let snapshot = HomeSnapshot.make(model: model)
        return VStack(alignment: .leading, spacing: 3) {
            Text("NAS").font(.system(size: 9.5, weight: .medium)).foregroundStyle(p.muted).lineLimit(1)
            Text(snapshot.nasText).font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(snapshot.nasOnline ? p.jade : p.muted).lineLimit(1)
            Text(snapshot.nasText).font(.system(size: 9)).foregroundStyle(p.muted).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: p.chipRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.chipRadius, style: .continuous).stroke(p.jade.opacity(0.28), lineWidth: 0.8))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var result: [IndexRow] = []
        var problems: [String] = []
        // 上证指数走既有新浪指数通道
        do {
            let all = try await GlobalIndexFeed.fetch()
            if let sh = all.first(where: { $0.symbol == "s_sh000001" }) {
                result.append(IndexRow(id: "000001", name: "上证", fullName: "上证指数", price: sh.price,
                                       percent: sh.price > 0 ? sh.changePercent : nil, spark: []))
            }
        } catch { problems.append("上证指数取不到") }
        // 深证成指 / 创业板指走多源报价链 + 日 K 迷你走势
        let codes = ["399001", "399006"]
        do {
            let quotes = try await NextMarketDataService.fetchQuotes(codes: codes)
            for code in codes {
                guard let quote = quotes.value.first(where: { $0.code == code }) else { continue }
                var spark: [Double] = []
                if let daily = try? await NextMarketDataService.fetchDaily(code: code) {
                    spark = daily.value.samples.suffix(30).compactMap { $0.close > 0 ? NextNum.double($0.close) : nil }
                }
                let label = code == "399001" ? "深证" : "创业板"
                let fullLabel = code == "399001" ? "深证成指" : "创业板指"
                result.append(IndexRow(id: code, name: label, fullName: fullLabel, price: NextNum.double(quote.price),
                                       percent: quote.changePercent.map { NextNum.double($0) }, spark: spark))
            }
        } catch {
            problems.append("深证/创业板指数取不到")
        }
        rows = result
        message = problems.isEmpty ? "" : problems.joined(separator: "；")
    }
}

/// 今日最重要机会：五套主题共用同一张卡的三种画法。
private struct LeadOpportunityCard: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    enum Style: Equatable { case editorial, modern, dashboard, magazine, puzzle }
    let snapshot: HomeSnapshot
    let style: Style

    private var item: NextGuidanceItem? { snapshot.lead }
    private var quote: NextQuote? { item.flatMap { snapshot.quotes[$0.code] } }

    private var tPlan: NextTPlan? {
        if let t = item?.tPlan, case let .ready(plan) = t { return plan }
        return nil
    }

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                emptyCard
            }
        }
    }

    private func content(_ item: NextGuidanceItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.system(size: 15, weight: .bold)).foregroundStyle(cardInk).lineLimit(1)
                        Text(item.code).font(.system(size: 10, design: .monospaced)).foregroundStyle(cardMuted).lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let quote {
                            Text(NextMoney.text(quote.price, digits: 3))
                                .font(.system(size: 22, weight: .bold, design: ThemeType.numberFont(p.theme)))
                                .foregroundStyle(p.changeTone(NextNum.double(quote.changePercent ?? 0)))
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        ChangePill(percent: quote?.changePercent.map { NextNum.double($0) })
                    }
                }
                Spacer(minLength: 4)
                strategyPill(item)
            }
            Text(item.headline)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(cardInk)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let plan = tPlan {
                HStack(spacing: 10) {
                    miniStat("卖出", NextMoney.text(plan.sellPrice, digits: 3))
                    miniStat("买回", NextMoney.text(plan.buyPrice, digits: 3))
                    miniStat("份额", "\(plan.units) 份")
                    miniStat("预计净收益", "¥\(NextMoney.text(plan.netGain, digits: 0))")
                }
                Text("置信度 \(plan.confidence.level.rawValue)｜\(item.profileNote ?? "按你的执行门槛推荐")")
                    .font(.system(size: 9)).foregroundStyle(cardMuted).lineLimit(2)
            } else if let note = item.profileNote {
                Text(note).font(.system(size: 9)).foregroundStyle(cardMuted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    model.requestTab(.decision, route: .decision(item.code))
                } label: {
                    Text("看完整 AI 指导").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accentInk)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(accentFill, in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    model.requestTab(.assets, route: .instrument(item.code))
                } label: {
                    Text("持仓详情").font(.system(size: 11, weight: .semibold)).foregroundStyle(cardMuted)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.hasPositions ? "今天没有值得动手的机会" : "还没有真实持仓")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink)
            Text(snapshot.hasPositions
                 ? "AI 扫描完全部持仓：当前都不满足你设定的执行门槛，继续持有即可。"
                 : "先在「持仓」里录入真实持仓，AI 才能给出属于你的价格和份额。")
                .font(.system(size: 10)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.requestTab(.assets, route: nil)
            } label: {
                Text(snapshot.hasPositions ? "查看持仓" : "去录入持仓")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(p.forest)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paper, in: RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous).stroke(p.line, lineWidth: 0.8))
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8.5)).foregroundStyle(cardMuted).lineLimit(1)
            Text(value).font(.system(size: 11, weight: .semibold, design: ThemeType.numberFont(p.theme)))
                .foregroundStyle(cardInk).lineLimit(1).minimumScaleFactor(0.75)
        }
    }

    private func strategyPill(_ item: NextGuidanceItem) -> some View {
        let tone = pillTone(item)
        return Text(item.strategy.rawValue)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tone.ink)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tone.fill, in: Capsule())
            .lineLimit(1)
    }

    private func pillTone(_ item: NextGuidanceItem) -> (fill: Color, ink: Color) {
        switch p.theme {
        case .puzzle:
            switch item.strategy {
            case .tTrade: return (Color(hex: 0xC0AEF7), Color(hex: 0x3A2470))
            case .grid: return (Color(hex: 0x8CC4F7), Color(hex: 0x10395E))
            case .hold: return (Color(hex: 0x9BE3BF), Color(hex: 0x0F5138))
            default: return (Color(hex: 0xF9BBD0), Color(hex: 0x8C2E52))
            }
        case .dashboard:
            return (p.primary.opacity(0.22), p.primary)
        default:
            return (p.tint, p.forest)
        }
    }

    // 主题差异
    private var cardInk: Color {
        switch style {
        case .dashboard: return p.ink
        default: return p.ink
        }
    }
    private var cardMuted: Color { p.muted }
    private var cardPadding: CGFloat {
        switch style {
        case .editorial, .magazine: return 14
        case .puzzle: return 14
        default: return 12
        }
    }
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous).fill(p.paper)
    }
    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous)
            .stroke(style == .magazine ? p.line : p.line.opacity(0.9), lineWidth: 0.8)
    }
    private var accentFill: Color {
        switch style {
        case .dashboard: return p.primary.opacity(0.22)
        case .puzzle: return Color(hex: 0xC0AEF7).opacity(0.55)
        case .magazine: return p.tint
        default: return p.tint
        }
    }
    private var accentInk: Color {
        switch style {
        case .dashboard: return p.primary
        default: return p.forest
        }
    }
}

/// 持仓摘要：总市值/盈亏 + 前几只 + 现金比例。
private struct HoldingsSummaryCard: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let snapshot: HomeSnapshot
    var showsRing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("我的持仓（\(snapshot.positions.count)）")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.ink)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("总市值").font(.system(size: 10)).foregroundStyle(p.muted)
                        Text(NextMoney.text(snapshot.totalEquity, digits: 0))
                            .font(.system(size: 17, weight: .bold, design: ThemeType.numberFont(p.theme)))
                            .foregroundStyle(p.ink).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    HStack(spacing: 5) {
                        Text("总盈亏").font(.system(size: 10)).foregroundStyle(p.muted)
                        if let pnl = snapshot.pnlPercent {
                            let tone = p.changeTone(pnl)
                            if let amount = snapshot.pnlAmount {
                                Text("\(amount >= 0 ? "+" : "-")¥\(NextMoney.text(abs(amount), digits: 0))")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(tone)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                            Text("(\(pnl >= 0 ? "+" : "")\(String(format: "%.2f", pnl))%)")
                                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(tone)
                        } else {
                            Text("—").font(.system(size: 11)).foregroundStyle(p.muted)
                        }
                    }
                }
                Spacer(minLength: 4)
                if showsRing { cashRing }
            }
            ForEach(snapshot.positions.prefix(4)) { position in
                HStack(spacing: 8) {
                    Text(position.name).font(.system(size: 11, weight: .medium)).foregroundStyle(p.ink).lineLimit(1)
                    Text(position.code).font(.system(size: 9, design: .monospaced)).foregroundStyle(p.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    if let quote = snapshot.quotes[position.code] {
                        Text(NextMoney.text(quote.price, digits: 3))
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(p.ink)
                        ChangePill(percent: quote.changePercent.map { NextNum.double($0) }, compact: true)
                    } else {
                        Text("无报价").font(.system(size: 9)).foregroundStyle(p.muted)
                    }
                }
                .padding(.vertical, 3)
            }
            Button { model.requestTab(.assets, route: nil) } label: {
                HStack(spacing: 3) {
                    Text("查看全部持仓").font(.system(size: 10, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(p.forest)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.paper, in: RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous).stroke(p.line, lineWidth: 0.8))
    }

    /// 仓位环：参考稿给的是「仓位 78%」而不是「现金 23%」——说清楚"钱有多少在场上"更直观。
    private var cashRing: some View {
        let position = max(0, min(100, 100 - snapshot.cashPercent))
        return ZStack {
            Circle().stroke(p.line, lineWidth: 5)
            Circle().trim(from: 0, to: max(0.02, min(1, position / 100)))
                .stroke(p.forest, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("仓位").font(.system(size: 8)).foregroundStyle(p.muted)
                Text("\(Int(position.rounded()))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(p.ink)
            }
        }
        .frame(width: 50, height: 50)
    }
}

// MARK: - 1. 东方编辑室

/// ① AI 顾问圆形头像（矢量占位，原创路径，不依赖图片资源）。
/// 同时用于首页问候区与「AI 今日指导」卡片角标。
private struct AdvisorAvatar: View {
    @Environment(\.gp) private var p
    let size: CGFloat
    init(size: CGFloat = 44) { self.size = size }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [p.chartGold, p.chartGold.opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            PersonSilhouette()
                .fill(Color.white.opacity(0.95))
                .frame(width: size * 0.62, height: size * 0.62)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: size > 30 ? 1.5 : 1))
        .shadow(color: p.chartGold.opacity(0.25), radius: 4, x: 0, y: 2)
    }
}

/// 头像内的人物剪影：头 + 肩，原创矢量，针对正方形区域绘制。
private struct PersonSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.width / 2
        var path = Path()
        // 头
        let headR = rect.width * 0.20
        let headCy = rect.height * 0.30
        path.addArc(center: CGPoint(x: cx, y: headCy), radius: headR,
                    startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        // 肩 / 身体（梯形圆角轮廓）
        let shoulderY = rect.height * 0.54
        let shoulderHalf = rect.width * 0.32
        let bottomY = rect.height * 1.04
        let bottomHalf = rect.width * 0.46
        var body = Path()
        body.move(to: CGPoint(x: cx - shoulderHalf, y: shoulderY))
        body.addQuadCurve(to: CGPoint(x: cx - bottomHalf, y: bottomY),
                          control: CGPoint(x: cx - shoulderHalf * 1.12, y: rect.height * 0.82))
        body.addLine(to: CGPoint(x: cx + bottomHalf, y: bottomY))
        body.addQuadCurve(to: CGPoint(x: cx + shoulderHalf, y: shoulderY),
                          control: CGPoint(x: cx + shoulderHalf * 1.12, y: rect.height * 0.82))
        body.addQuadCurve(to: CGPoint(x: cx - shoulderHalf, y: shoulderY),
                          control: CGPoint(x: cx, y: rect.height * 0.44))
        path.addPath(body)
        return path
    }
}

private struct EditorialHome: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let snapshot: HomeSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HomeTopBar()
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(snapshot.greeting)！")
                            .font(.system(size: 30, weight: .bold, design: .serif)).foregroundStyle(p.ink)
                        Text(snapshot.dateText)
                            .font(.system(size: 12)).foregroundStyle(p.muted)
                    }
                    Spacer(minLength: 4)
                    // ① AI 顾问头像（问候区）
                    AdvisorAvatar(size: 46)
                }
                Text(snapshot.headline)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(p.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.paperAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.chartGold.opacity(0.3), lineWidth: 0.8))
                HomeIndexBoard(style: .chips)
                aiCard
                sectionTitle("今日最重要机会", accent: p.chartGold)
                LeadOpportunityCard(snapshot: snapshot, style: .editorial)
                sectionTitle("真实持仓", accent: p.jade)
                HoldingsSummaryCard(snapshot: snapshot, showsRing: true)
                footerRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // ① AI 顾问头像（AI 卡角标）
                AdvisorAvatar(size: 40)
                Text("AI 今日指导").font(.system(size: 17, weight: .bold, design: .serif)).foregroundStyle(p.heroInk)
                Spacer(minLength: 4)
                Button { model.requestTab(.decision, route: .decision(nil)) } label: {
                    HStack(spacing: 2) {
                        Text("查看详情").font(.system(size: 10, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(p.heroMutedInk)
                }
                .buttonStyle(.plain)
            }
            // 逐只标的的判断：顶部那一块已经写过摘要，这里不重复，直接讲结论与理由。
            ForEach(Array(snapshot.aiLines.prefix(2).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12.5, weight: .medium)).foregroundStyle(p.heroInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                metaChip("市场状态 · \(snapshot.marketStateText)")
                metaChip("机会 \(snapshot.actionableCount) 个")
                metaChip("画像 · \(snapshot.profileTags.first ?? "学习中")")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.heroGradient, in: RoundedRectangle(cornerRadius: p.heroRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.heroRadius, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 0.8))
        .shadow(color: p.chartGold.opacity(0.18), radius: 10, x: 0, y: 4)
    }

    private func metaChip(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(p.heroInk)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.35), in: Capsule())
    }

    private func sectionTitle(_ title: String, accent: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(accent).frame(width: 3, height: 13)
            Text(title).font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(p.ink)
            Spacer()
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button { model.requestTab(.decision, route: .decision(nil)) } label: {
                footerChip("sparkles", "AI 今日指导")
            }
            .buttonStyle(.plain)
            Button { model.requestTab(.market, route: nil) } label: {
                footerChip("chart.xyaxis.line", "行情")
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Text("NAS \(snapshot.nasText)").font(.system(size: 9)).foregroundStyle(p.muted)
        }
        .padding(.top, 4)
    }

    private func footerChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(p.forest)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(p.paper, in: Capsule())
        .overlay(Capsule().stroke(p.line, lineWidth: 0.8))
    }
}

// MARK: - 2. 现代卡片

private struct ModernHome: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let snapshot: HomeSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HomeTopBar()
                VStack(alignment: .leading, spacing: 2) {
                    Text("观盘").font(.system(size: 28, weight: .bold)).foregroundStyle(p.ink)
                    Text("AI 私人投资顾问").font(.system(size: 11)).foregroundStyle(p.muted)
                }
                HStack(spacing: 8) {
                    quickTab("今日机会", active: true, route: .decision(nil))
                    quickTab("持仓总览", active: false, route: nil, tab: .assets)
                    quickTab("市场行情", active: false, route: nil, tab: .market)
                }
                aiHero
                HomeIndexBoard(style: .cards)
                HoldingsSummaryCard(snapshot: snapshot, showsRing: true)
                LeadOpportunityCard(snapshot: snapshot, style: .modern)
                nasRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var aiHero: some View {
        Button { model.requestTab(.decision, route: .decision(nil)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.18)).frame(width: 34, height: 34)
                        Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI 今日指导").font(.system(size: 16, weight: .bold)).foregroundStyle(p.heroInk)
                        Text("已扫描 \(snapshot.positions.count) 只真实持仓")
                            .font(.system(size: 9.5)).foregroundStyle(p.heroMutedInk)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        Text("查看详情").font(.system(size: 9.5, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(p.heroMutedInk)
                }
                Text(snapshot.headline)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(p.heroInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    pill("市场 \(snapshot.marketStateText)")
                    pill("机会 \(snapshot.actionableCount)")
                    pill("候选计划 \(snapshot.openPlanCount)")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.heroGradient, in: RoundedRectangle(cornerRadius: p.heroRadius, style: .continuous))
            .shadow(color: p.primary.opacity(0.25), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.22), in: Capsule())
    }

    private func quickTab(_ title: String, active: Bool, route: GPRoute?, tab: NextTab = .decision) -> some View {
        Button {
            if let route { model.requestTab(tab, route: route) } else { model.requestTab(tab, route: nil) }
        } label: {
            Text(title).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? .white : p.ink)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(active ? p.primary : p.paper, in: Capsule())
                .overlay(Capsule().stroke(active ? Color.clear : p.line, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private var nasRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 12)).foregroundStyle(p.forest)
            Text("NAS 长期研究：\(snapshot.nasText)").font(.system(size: 10)).foregroundStyle(p.muted)
            Spacer()
            Button { model.push(.profile, in: .decision) } label: {
                Text("AI 对我的了解").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.forest)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(p.paper, in: RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous).stroke(p.line, lineWidth: 0.8))
    }
}

// MARK: - 3. 交易仪表盘

private struct DashboardHome: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let snapshot: HomeSnapshot
    @State private var tab = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                tabHeader
                HomeIndexBoard(style: .tiles)
                aiHero
                opportunityBoard
                HoldingsSummaryCard(snapshot: snapshot, showsRing: false)
                newsRow
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var tabHeader: some View {
        HStack(spacing: 14) {
            ForEach(Array(["市场", "持仓", "AI 指导", "新闻"].enumerated()), id: \.offset) { index, title in
                Button {
                    tab = index
                    if index == 3 { model.requestTab(.decision, route: .news) }
                    else if index == 2 { model.requestTab(.decision, route: .decision(nil)) }
                    else if index == 1 { model.requestTab(.assets, route: nil) }
                    else if index == 0 { model.requestTab(.market, route: nil) }
                } label: {
                    VStack(spacing: 3) {
                        Text(title).font(.system(size: 13, weight: index == tab ? .bold : .medium))
                            .foregroundStyle(index == tab ? p.ink : p.muted)
                        Capsule().fill(index == tab ? p.primary : Color.clear).frame(width: 18, height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            HomeTopBar()
        }
    }

    private var opportunityBoard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("重点机会").font(.system(size: 13, weight: .bold)).foregroundStyle(p.ink)
                Spacer()
                Text("按你的门槛排序").font(.system(size: 9)).foregroundStyle(p.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array((snapshot.guidance?.items ?? []).prefix(4))) { item in
                        opportunityTile(item)
                    }
                    if (snapshot.guidance?.items.isEmpty ?? true) {
                        Text("今天没有可执行机会").font(.system(size: 10)).foregroundStyle(p.muted)
                    }
                }
            }
        }
    }

    private var newsRow: some View {
        HStack(spacing: 8) {
            Text("新闻与市场解读").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.ink)
            Spacer()
            Button { model.requestTab(.decision, route: .news) } label: {
                Text("查看持仓相关新闻").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(p.paper, in: RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous))
    }

    private var aiHero: some View {
        Button { model.requestTab(.decision, route: .decision(nil)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.14)).frame(width: 34, height: 34)
                        Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AI 今日指导").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        Text(snapshot.dataState).font(.system(size: 9)).foregroundStyle(p.heroMutedInk).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    ZStack {
                        Circle().fill(p.secondary).frame(width: 24, height: 24)
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: 0x101828))
                    }
                }
                Text(snapshot.headline).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                HStack(spacing: 10) {
                    dashStat("状态", snapshot.marketStateText)
                    dashStat("机会", "\(snapshot.actionableCount)")
                    dashStat("计划", "\(snapshot.openPlanCount)")
                    dashStat("置信度", snapshot.lead?.confidence.level.rawValue ?? "—")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.heroGradient, in: RoundedRectangle(cornerRadius: p.heroRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: p.heroRadius, style: .continuous).stroke(p.primary.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func dashStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8)).foregroundStyle(p.heroMutedInk)
            Text(value).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white).lineLimit(1)
        }
    }

    private func opportunityTile(_ item: NextGuidanceItem) -> some View {
        let quote = snapshot.quotes[item.code]
        let tone = p.changeTone(NextNum.double(quote?.changePercent ?? 0))
        var tPlan: NextTPlan?
        if let t = item.tPlan, case let .ready(plan) = t { tPlan = plan }
        return Button { model.requestTab(.decision, route: .decision(item.code)) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 12, weight: .bold)).foregroundStyle(p.ink).lineLimit(1)
                Text(item.strategy.rawValue).font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(p.primary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(p.primary.opacity(0.18), in: Capsule())
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let quote {
                        Text(NextMoney.text(quote.price, digits: 3))
                            .font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(tone)
                    }
                    ChangePill(percent: quote?.changePercent.map { NextNum.double($0) }, compact: true)
                }
                if let plan = tPlan {
                    Text("卖 \(NextMoney.text(plan.sellPrice, digits: 3)) · 买回 \(NextMoney.text(plan.buyPrice, digits: 3))")
                        .font(.system(size: 8.5)).foregroundStyle(p.muted).lineLimit(1)
                    Text("\(plan.units) 份 · 净 ¥\(NextMoney.text(plan.netGain, digits: 0))")
                        .font(.system(size: 8.5)).foregroundStyle(p.muted).lineLimit(1)
                } else {
                    Text("数据不足，不出价").font(.system(size: 8.5)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            .padding(10)
            .frame(width: 152, alignment: .leading)
            .background(p.paper, in: RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous).stroke(p.primary.opacity(0.3), lineWidth: 0.9))
        }
        .buttonStyle(.plain)
    }

}

// MARK: - 4. 杂志卡片

private struct MagazineHome: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let snapshot: HomeSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HomeTopBar()
                VStack(alignment: .leading, spacing: 3) {
                    Text("观盘投资手册").font(.system(size: 25, weight: .bold, design: .serif)).foregroundStyle(p.ink)
                    HStack(spacing: 6) {
                        Text("AI 私人投资顾问").font(.system(size: 10)).foregroundStyle(p.muted)
                        Spacer()
                        Text(snapshot.dateText).font(.system(size: 9.5, weight: .medium)).foregroundStyle(p.muted)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(p.tint, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }
                observationCard
                HomeIndexBoard(style: .cards)
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.primary)
                    Text("今日重点机会").font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(p.ink)
                    Spacer()
                    Button { model.requestTab(.decision, route: .decision(nil)) } label: {
                        Text("查看全部").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.primary)
                    }
                    .buttonStyle(.plain)
                }
                LeadOpportunityCard(snapshot: snapshot, style: .magazine)
                HairlineRule()
                HoldingsSummaryCard(snapshot: snapshot, showsRing: false)
                if !snapshot.profileTags.isEmpty {
                    HStack(spacing: 6) {
                        Text("AI 认为你是").font(.system(size: 10)).foregroundStyle(p.muted)
                        Text(snapshot.profileTags.prefix(3).joined(separator: " · ")).font(.system(size: 10, weight: .semibold)).foregroundStyle(p.ink)
                        Spacer()
                        Button { model.push(.profile, in: .decision) } label: {
                            Text("详情").font(.system(size: 9, weight: .semibold)).foregroundStyle(p.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var observationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(p.chartGold.opacity(0.22)).frame(width: 26, height: 26)
                    Image(systemName: "sun.max.fill").font(.system(size: 12)).foregroundStyle(p.chartGold)
                }
                Text("今日市场观察").font(.system(size: 15, weight: .bold, design: .serif)).foregroundStyle(p.ink)
                Spacer(minLength: 4)
                Button { model.requestTab(.decision, route: .decision(nil)) } label: {
                    Text("更多").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.primary)
                }
                .buttonStyle(.plain)
            }
            Text(snapshot.marketStateText + "：" + snapshot.marketStateDetail)
                .font(.system(size: 12)).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(snapshot.headline)
                .font(.system(size: 12)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.heroSurface, in: RoundedRectangle(cornerRadius: p.heroRadius, style: .continuous))
    }
}

private struct HairlineRule: View {
    @Environment(\.gp) private var p
    var body: some View {
        Rectangle().fill(p.line).frame(height: 0.6)
    }
}

// MARK: - 5. 创意拼图

private struct PuzzleHome: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    let snapshot: HomeSnapshot

    private var tones: [(fill: Color, ink: Color)] { PuzzlePalette.tones(p.tokens) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HomeTopBar()
                VStack(alignment: .leading, spacing: 2) {
                    Text("观盘").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(p.ink)
                    Text("AI 私人投资顾问 · " + snapshot.dateText)
                        .font(.system(size: 10)).foregroundStyle(p.muted)
                }
                HStack(spacing: 10) {
                    tile(tone: tones[0].fill, width: nil) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Image(systemName: "sun.max.fill").font(.system(size: 12)).foregroundStyle(tones[0].ink)
                                Text("AI 今日指导").font(.system(size: 12, weight: .bold)).foregroundStyle(tones[0].ink)
                            }
                            Text("\(snapshot.actionableCount) 个机会").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(tones[0].ink)
                            Text(snapshot.actionableCount > 0 ? "按你的门槛排序" : "今天整体无需调整")
                                .font(.system(size: 9.5)).foregroundStyle(tones[0].ink.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                                Text("查看").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(tones[0].ink)
                        }
                    } action: { model.requestTab(.decision, route: .news) }
                    tile(tone: tones[1].fill, width: nil) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Text("市场状态").font(.system(size: 12, weight: .bold)).foregroundStyle(tones[1].ink)
                                Spacer(minLength: 0)
                                Image(systemName: "chart.bar.fill").font(.system(size: 12)).foregroundStyle(tones[1].ink)
                            }
                            Text(snapshot.marketStateText).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(tones[1].ink)
                            Text(snapshot.marketStateDetail).font(.system(size: 9)).foregroundStyle(tones[1].ink.opacity(0.85))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack(spacing: 10) {
                    positionTile(snapshot.positions.first, tone: tones[2], toneIndex: 2)
                    positionTile(snapshot.positions.count > 1 ? snapshot.positions[1] : nil, tone: tones[3], toneIndex: 3)
                }
                HStack(spacing: 10) {
                    positionTile(snapshot.positions.count > 2 ? snapshot.positions[2] : nil, tone: tones[4], toneIndex: 4)
                    positionTile(snapshot.positions.count > 3 ? snapshot.positions[3] : nil, tone: tones[5], toneIndex: 5)
                }
                HStack(spacing: 10) {
                    tile(tone: p.paper, width: nil) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("总市值").font(.system(size: 9.5)).foregroundStyle(p.muted)
                            Text(NextMoney.text(snapshot.totalEquity, digits: 0))
                                .font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(p.ink)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            HStack(spacing: 4) {
                                Text("盈亏").font(.system(size: 9)).foregroundStyle(p.muted)
                                ChangePill(percent: snapshot.pnlPercent, compact: true)
                            }
                        }
                    } action: { model.requestTab(.assets, route: nil) }
                    tile(tone: p.paper, width: nil) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("NAS 状态").font(.system(size: 9.5)).foregroundStyle(p.muted)
                            Text(snapshot.nasText).font(.system(size: 13, weight: .heavy, design: .rounded))
                                .foregroundStyle(snapshot.nasOnline ? p.jade : p.muted)
                            Text("新闻与市场解读").font(.system(size: 9)).foregroundStyle(p.muted)
                        }
                    } action: { model.requestTab(.decision, route: .decision(nil)) }
                }
                if !snapshot.profileTags.isEmpty {
                    Button { model.push(.profile, in: .decision) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.text.rectangle").font(.system(size: 10))
                            Text("AI 对你的了解：" + snapshot.profileTags.prefix(3).joined(separator: " · "))
                                .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(p.primary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(p.tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private func tile<Content: View>(tone: Color, width: CGFloat?, @ViewBuilder content: () -> Content,
                                     action: (() -> Void)? = nil) -> some View {
        let body = content()
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(tone, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        return Group {
            if let action {
                Button(action: action) { body }.buttonStyle(.plain)
            } else {
                body
            }
        }
    }

    private func positionTile(_ position: NextPosition?, tone: (fill: Color, ink: Color), toneIndex: Int) -> some View {
        Group {
            if let position {
                let quote = snapshot.quotes[position.code]
                let item = snapshot.guidance?.items.first(where: { $0.code == position.code })
                Button { model.requestTab(.assets, route: .instrument(position.code)) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(shortName(position.name)).font(.system(size: 11.5, weight: .bold)).foregroundStyle(tone.ink).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "cube.fill").font(.system(size: 9)).foregroundStyle(tone.ink.opacity(0.5))
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if let quote {
                                Text(NextMoney.text(quote.price, digits: 3))
                                    .font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(tone.ink)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                            Text(quote?.changePercent.map { "\(NextNum.double($0) >= 0 ? "+" : "")\(String(format: "%.2f", NextNum.double($0)))%" } ?? "—")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(tone.ink.opacity(0.75))
                        }
                        Text(item?.strategy.rawValue ?? "持有观察")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(tone.ink)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(tone.ink.opacity(0.14), in: Capsule())
                        if let days = snapshot.guidance?.items.first(where: { $0.code == position.code })?.confidence.level.rawValue {
                            Text("置信度 \(days)").font(.system(size: 8.5)).foregroundStyle(tone.ink.opacity(0.75)).lineLimit(1)
                        }
                        // 底部两行把"持有了多少、赚了多少"补齐，避免块里下半截留白。
                        HStack(spacing: 4) {
                            Text("\(position.units) 份").font(.system(size: 9)).foregroundStyle(tone.ink.opacity(0.7))
                            Spacer(minLength: 0)
                            if let quote, position.units > 0 {
                                let pnl = (quote.price - position.costPerUnit) * Decimal(position.units)
                                Text("\(pnl >= 0 ? "+" : "-")¥\(NextMoney.text(abs(pnl), digits: 0))")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(tone.ink.opacity(0.85))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                        Text("成本 \(NextMoney.text(position.costPerUnit, digits: 3))")
                            .font(.system(size: 8.5)).foregroundStyle(tone.ink.opacity(0.6)).lineLimit(1)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                    .background(tone.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("空位").font(.system(size: 11, weight: .bold)).foregroundStyle(p.muted)
                    Text("录入持仓后自动填满").font(.system(size: 9)).foregroundStyle(p.muted)
                }
                .padding(11)
                .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
                .background(p.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(p.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }

    private func shortName(_ name: String) -> String {
        var value = name
        for suffix in ["ETF", "etf"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        return value.count > 7 ? String(value.prefix(7)) : value
    }
}
