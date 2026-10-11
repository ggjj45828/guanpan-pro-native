import SwiftUI

/// Read-only approximation of the legacy asset look-through and market stress view.
/// Unknown instruments and off-exchange funds stay explicitly unclassified.
struct PortfolioAnalysisView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @State private var equityShock = -10.0
    @State private var hkShock = -12.0
    @State private var usShock = -15.0
    @State private var goldShock = -5.0
    @State private var bondShock = -2.0
    @State private var rmbAppreciation = 3.0
    @State private var fxSnapshot: ExchangeRateService.Snapshot?
    @State private var fxLoading = false
    @State private var fxMessage: String?

    private struct Exposure: Identifiable {
        let category: String
        let value: Double
        let currency: String
        let region: String
        let id: String
    }

    private var exposures: [Exposure] {
        store.data.holdings.filter { $0.quantity > 0 }.map { holding in
            let detail = classify(holding)
            return Exposure(category: detail.category, value: max(0, holding.marketValue), currency: detail.currency, region: detail.region, id: holding.id)
        }.sorted { $0.value > $1.value }
    }

    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }
    private var total: Double { exposures.reduce(0) { $0 + $1.value } + max(0, store.data.cash) }
    private var foreignValue: Double { exposures.filter { $0.currency == "USD" || $0.currency == "HKD" }.reduce(0) { $0 + $1.value } }
    private var fundValue: Double {
        store.data.holdings.filter { $0.kind == .fund && $0.quantity > 0 }.reduce(0) { $0 + max(0, $1.marketValue) }
    }

    private var impact: Double {
        store.data.holdings.filter { $0.quantity > 0 }.reduce(0) { sum, holding in
            let detail = classify(holding)
            let shock: Double
            switch detail.group {
            case "gold": shock = goldShock
            case "bond": shock = bondShock
            case "us": shock = usShock
            case "hk": shock = hkShock
            default: shock = equityShock
            }
            let fx = (detail.currency == "USD" || detail.currency == "HKD") ? rmbAppreciation : 0
            let combined = ((1 + shock / 100) * (1 - fx / 100) - 1) * 100
            return sum + max(0, holding.marketValue) * combined / 100
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("资产分类（基金未穿透）") {
                    if exposures.isEmpty { Text("暂无持仓数据").foregroundStyle(.secondary) }
                    ForEach(exposures) { item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.category)
                                Text("\(item.region) · \(item.currency)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text((item.value).cny())
                                Text((total > 0 ? item.value / total * 100 : 0).pct(1))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("现金", value: (max(0, store.data.cash)).cny())
                    LabeledContent("外币计价 ETF 敞口（估算）", value: (foreignValue).cny())
                    LabeledContent("占总资产", value: (total > 0 ? foreignValue / total * 100 : 0).pct(1))
                    if fundValue > 0 {
                        Text("场外基金 \((fundValue).cny()) 作为未穿透持仓单列；本页不推测基金底层地区、币种或类别。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .plainCard(isLight: isLight)
                Section("实时汇率") {
                    if let snapshot = fxSnapshot, !snapshot.rates.isEmpty {
                        ForEach(snapshot.rates) { rate in
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rate.name)
                                    Text(rate.source).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(rate.price.num(4))
                                    Text(fxChangeText(rate))
                                        .font(.caption)
                                        .foregroundStyle(fxColor(rate.changePct))
                                }
                            }
                        }
                        Text(fxFooter(snapshot))
                            .font(.footnote).foregroundStyle(.secondary)
                        Button {
                            Task { await refreshFX(force: true) }
                        } label: {
                            if fxLoading { Text("正在刷新…") } else { Text("刷新实时汇率") }
                        }
                        .disabled(fxLoading)
                    } else if fxLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在获取实时汇率…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(fxMessage ?? "实时汇率暂不可用。可点下方按钮重试，或在压力情景中手动设定人民币升值幅度。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重新获取实时汇率") { Task { await refreshFX(force: true) } }
                    }
                }
                .plainCard(isLight: isLight)
                Section("组合压力情景（手动设定）") {
                    shockField("A 股", value: $equityShock)
                    shockField("港股", value: $hkShock)
                    shockField("美股", value: $usShock)
                    shockField("黄金", value: $goldShock)
                    shockField("债券", value: $bondShock)
                    shockField("人民币升值", value: $rmbAppreciation)
                    LabeledContent("持仓估算影响", value: "\((impact).directionMark()) \((impact).cny())")
                        .foregroundStyle(PnLColor.of(impact))
                    LabeledContent("占总资产", value: (total > 0 ? impact / total * 100 : 0).pct(2))
                    Text("仅对当前持仓市值做静态情景估算；外币冲击按汇率折算近似计算。现金不受冲击。ETF 分类使用代码表或名称关键词，未知品种会标为未分类；基金未穿透。不是行情预测或最大亏损保证。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .toneCard(CardTone.pnl(impact), isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .navigationTitle("资产穿透与压力测试")
            .keyboardDoneToolbar()
            .task { await refreshFX(force: false) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    // MARK: - 实时汇率

    /// 抓取实时汇率。非强制刷新时优先复用 24 小时内的缓存，避免每次进入页面都打接口。
    @MainActor private func refreshFX(force: Bool) async {
        guard !fxLoading else { return }
        if !force, let cached = ExchangeRateService.cached(), !ExchangeRateService.isStale(cached) {
            fxSnapshot = cached
            return
        }
        // 刷新期间先展示旧值，避免数字闪空。
        if fxSnapshot == nil, let cached = ExchangeRateService.cached() { fxSnapshot = cached }
        fxLoading = true
        defer { fxLoading = false }
        if let snapshot = await ExchangeRateService.fetch() {
            fxSnapshot = snapshot
            fxMessage = nil
        } else if fxSnapshot == nil {
            fxMessage = "实时汇率未获取到（网络或接口异常）。可在下方压力情景中手动填写人民币升值幅度。"
        }
    }

    private func fxChangeText(_ rate: ExchangeRate) -> String {
        let sign = rate.changePct > 0 ? "+" : ""
        return sign + rate.changePct.pct(2)
    }

    /// 沿用国内看盘习惯：涨为红、跌为绿。
    private func fxColor(_ pct: Double) -> Color {
        if pct > 0 { return .red }
        if pct < 0 { return .green }
        return .secondary
    }

    private func fxFooter(_ snapshot: ExchangeRateService.Snapshot) -> String {
        let time = snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)
        var text = "报价为每单位外币兑人民币，取自公开行情接口，仅供参考。更新于 \(time)。"
        if ExchangeRateService.isStale(snapshot) { text += "当前为本地缓存，可能滞后。" }
        return text
    }

    @ViewBuilder private func shockField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text("\(title)（%）")
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
        }
    }

    private func classify(_ holding: Holding) -> (category: String, currency: String, region: String, group: String) {
        let map: [String: (String, String, String, String)] = [
            "159941": ("美股大盘", "USD", "美国", "us"), "513100": ("美股大盘", "USD", "美国", "us"),
            "159632": ("美股大盘", "USD", "美国", "us"), "513300": ("美股大盘", "USD", "美国", "us"),
            "159509": ("美股科技", "USD", "美国", "us"), "513050": ("中概互联", "USD", "美国/香港", "us"),
            "159605": ("中概互联", "USD", "美国/香港", "us"), "563020": ("A 股红利低波", "CNY", "中国 A 股", "a"),
            "512890": ("A 股红利低波", "CNY", "中国 A 股", "a"), "515100": ("A 股红利低波", "CNY", "中国 A 股", "a"),
            "159545": ("港股红利", "HKD", "中国香港", "hk"), "513630": ("港股红利", "HKD", "中国香港", "hk"),
            "520660": ("港股红利", "HKD", "中国香港", "hk"), "159352": ("A 股大盘", "CNY", "中国 A 股", "a"),
            "510300": ("A 股大盘", "CNY", "中国 A 股", "a"), "510500": ("A 股中盘", "CNY", "中国 A 股", "a"),
            "588000": ("A 股科创", "CNY", "中国 A 股", "a"), "159915": ("A 股成长", "CNY", "中国 A 股", "a"),
            "512880": ("A 股券商", "CNY", "中国 A 股", "a"), "518880": ("黄金", "CNY", "全球", "gold"),
            "511260": ("债券", "CNY", "中国", "bond"), "511010": ("债券", "CNY", "中国", "bond")
        ]
        let name = holding.name
        if holding.kind == .fund { return ("场外基金（未穿透）", "未穿透", "未穿透", "unknown") }
        if let mapped = map[holding.code] { return mapped }
        if name.contains("金") || name.contains("黄金") { return ("黄金", "CNY", "全球", "gold") }
        if name.contains("债") { return ("债券", "CNY", "中国", "bond") }
        if ["纳指", "纳斯达克", "标普", "道指", "美股"].contains(where: { name.contains($0) }) { return ("美股（名称推断）", "USD", "美国", "us") }
        if ["恒生", "港股", "HK"].contains(where: { name.localizedCaseInsensitiveContains($0) }) { return ("港股（名称推断）", "HKD", "中国香港", "hk") }
        if ["红利", "股息"].contains(where: { name.contains($0) }) { return ("红利（名称推断）", "CNY", "中国 A 股", "a") }
        if holding.kind == .etf { return ("未分类 ETF", "未知", "未知", "a") }
        return ("未分类证券", "未知", "未知", "a")
    }
}
