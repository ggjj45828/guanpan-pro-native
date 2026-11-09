import SwiftUI

/// 值不值得买 · 全持仓。
///
/// 以前六维雷达只在「点开某只持仓 → 个股详情 → 值不值得买」里，
/// 想横向比较几只票得一只一只点进去。这一页把同一套 `RadarEngine` 铺开到
/// 全部持仓与自选，口径完全一致（本机日线计算、不联网、缺数据不凑分）。
///
/// 刻意不做的事：
/// · 不排序成「排行榜」，也不发买卖信号 —— 六维分是"这只票现在长什么样"，
///   不是"该不该买"；
/// · 缺维度的标的直接标出来，不拿平均分掩盖数据不足。
struct WatchRadarView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    /// 推入已有导航栈时为 true：不自建 NavigationStack、隐藏「完成」按钮。
    var embedded: Bool = false

    struct Item: Identifiable {
        let code: String
        let name: String
        /// 「持仓」或「自选」——同一只票两边都有时按持仓算。
        let source: String
        var id: String { code }
    }

    @State private var results: [String: RadarResult] = [:]
    /// 取不到就写原因，绝不显示 0 分或默认分。
    @State private var failures: [String: String] = [:]
    @State private var loadingCodes: Set<String> = []
    @State private var expandedCode: String?
    @State private var started = false

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: store.resolvedAppearance).isLight)
    }

    /// 持仓在前（按市值降序，和持仓页顺序一致），自选在后。
    private var items: [Item] {
        var seen = Set<String>()
        var list: [Item] = []
        let holdings = store.data.holdings
            .filter { $0.quantity > 0 }
            .sorted { $0.marketValue > $1.marketValue }
        for holding in holdings {
            let code = holding.code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, seen.insert(code).inserted else { continue }
            list.append(Item(code: code, name: holding.name, source: "持仓"))
        }
        for quote in store.data.quotes {
            let code = quote.code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, seen.insert(code).inserted else { continue }
            list.append(Item(code: code, name: quote.name, source: "自选"))
        }
        return list
    }

    var body: some View {
        PageHost(embedded: embedded) {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.sectionGap) {
                    introCard
                    if items.isEmpty {
                        emptyCard
                    } else {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                    disclaimer
                }
                .padding(.horizontal, palette.pageInset)
                .padding(.vertical, 14)
            }
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("值不值得买")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !embedded { Button("完成") { dismiss() }.tint(palette.accent) }
                }
            }
            .onAppear(perform: startLoadingIfNeeded)
        }
    }

    // MARK: 说明

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11, weight: .semibold))
                Text("六维条件复核 · 本机规则计算，不联网")
                    .scaledFont(palette.fsLabel, weight: .medium)
                Spacer(minLength: 0)
                Text("\(items.count) 只")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
            }
            .foregroundStyle(palette.ink2)

            Text("趋势 / 位置 / 量能 / 动量 / 风险 / 赔率，全部用本机日线算。不含 PE、PB、资金流这类拿不到的数据；某一维数据不够就不显示，不用 50 分凑。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(palette.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.radius, padding: 0)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有可评估的标的")
                .scaledFont(palette.fsTitle, weight: .semibold)
                .foregroundStyle(palette.ink)
            Text("先录入持仓，或在自选里加几只票，这里会按同一套六维口径逐只复核。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(palette.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.radius, padding: 0)
    }

    private var disclaimer: some View {
        Text("高分不等于立即买入：这只说明当前日线结构偏强，不含估值、不含你个人的持有期限与资金安排。任何结论都要先过风险预算与仓位上限。")
            .scaledFont(palette.fsMicro)
            .foregroundStyle(palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 行

    private func row(_ item: Item) -> some View {
        let result = results[item.code]
        let failure = failures[item.code]
        let expanded = expandedCode == item.code

        return Button {
            Haptics.tap()
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedCode = expanded ? nil : item.code
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name.isEmpty ? item.code : item.name)
                            .scaledFont(palette.fsRow, weight: .medium)
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                        Text("\(item.code) · \(item.source)")
                            .scaledFont(palette.fsMicro)
                            .foregroundStyle(palette.ink3)
                    }
                    Spacer(minLength: 4)
                    if loadingCodes.contains(item.code) {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                    } else if let result {
                        totalBadge(result)
                    } else if failure != nil {
                        Text("无数据")
                            .scaledFont(palette.fsMicro, weight: .medium)
                            .foregroundStyle(palette.ink3)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background { Capsule().fill(palette.cardSoft) }
                    }
                }

                if let result {
                    if expanded {
                        VStack(spacing: 6) {
                            ForEach(result.dimensions) { dimension in
                                dimensionRow(dimension)
                            }
                        }
                        Text(result.summary)
                            .scaledFont(palette.fsMicro)
                            .foregroundStyle(palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    } else {
                        Text(result.summary)
                            .scaledFont(palette.fsMicro)
                            .foregroundStyle(palette.ink2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let failure {
                    Text(failure)
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                }
            }
            .padding(palette.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsSurface(palette, radius: palette.radius, padding: 0)
        }
        .buttonStyle(.plain)
    }

    private func totalBadge(_ result: RadarResult) -> some View {
        let text = result.total.map { "\(Int($0.rounded()))" } ?? "—"
        let tone = result.total.map { scoreColor($0) } ?? palette.ink3
        return VStack(spacing: 1) {
            Text(text)
                .scaledFont(palette.fsRow, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(tone)
            Text(result.hasEnoughData ? "六维" : "维度不足")
                .scaledFont(8.5)
                .foregroundStyle(palette.ink3)
        }
    }

    private func dimensionRow(_ dimension: RadarDimension) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(dimension.kind.title)
                .scaledFont(palette.fsMicro, weight: .medium)
                .foregroundStyle(palette.ink2)
                .frame(width: 32, alignment: .leading)
            Text("\(Int(dimension.value.rounded()))")
                .scaledFont(palette.fsMicro, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(scoreColor(dimension.value))
                .frame(width: 26, alignment: .trailing)
            Text(dimension.note)
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 与个股详情页的雷达卡同口径：国内红涨，66 以上偏强、33 以下偏弱。
    private func scoreColor(_ value: Double) -> Color {
        if value >= 66 { return PnLColor.up }
        if value >= 33 { return palette.ink }
        return PnLColor.down
    }

    // MARK: 加载

    private func startLoadingIfNeeded() {
        guard !started else { return }
        started = true
        let targets = items
        Task { @MainActor in
            for item in targets {
                await reload(item)
            }
        }
    }

    @MainActor
    private func reload(_ item: Item) async {
        loadingCodes.insert(item.code)
        defer { loadingCodes.remove(item.code) }
        failures[item.code] = nil
        do {
            let bars = try await store.fetchDailyBars(code: item.code, count: 260)
            if let result = RadarEngine.evaluate(bars: bars) {
                results[item.code] = result
            } else {
                failures[item.code] = "日线不足 30 根，无法复核六维。"
            }
        } catch {
            failures[item.code] = "取数失败：\(error.localizedDescription)"
        }
    }
}
