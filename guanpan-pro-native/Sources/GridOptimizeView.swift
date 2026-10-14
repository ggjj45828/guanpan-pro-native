import SwiftUI

/// 「复盘并寻找当日最优」—— 移植自网页版 `gridTradeReplayOptimize`。
///
/// 输入只有「标的 + 交易日 + 计划资金（+ 是否 T+0）」，自动搜出当天**事后最优**的锚点与格距。
/// 判定标准不是「赚了多少」，而是 `alpha = 网格盈亏 − 同期躺着不动的盈亏`：
/// 单边上涨的日子随便一组参数都能赚，只有减掉「买了不动」那份，剩下的才是网格真正多挣的。
///
/// 参数与常量全部按网页版逐条对齐（3 个锚点 × 7 个步长倍率 = 21 组回放）。
///
/// ⚠️ 这是**事后拟合**：它用的是当天已经走完的完整分时，不是预测。
struct GridOptimizeView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var day = ""
    @State private var capital = "20000"
    @State private var t0 = true
    @State private var report: GridOptimizeReport?
    @State private var message = ""
    @State private var showAllCandidates = false
    @State private var experience: GridExperienceRecord?

    /// 只有名下有分时档案的代码才排在最前 —— 找最优这件事，输入必须是有分时数据的那几天。
    private var archivedCodes: [String] { store.intradayCodes.sorted() }
    private var days: [String] { code.isEmpty ? [] : store.intradayDays(forCode: code) }
    private var isLight: Bool { AppTheme.palette(for: store.resolvedAppearance).isLight }

    private func displayName(_ target: String) -> String {
        store.data.quotes.first { $0.code == target }?.name
            ?? store.data.holdings.first { $0.code == target }?.name
            ?? target
    }

    var body: some View {
        NavigationStack {
            Form {
                GridOptimizeInputSection(
                    code: $code,
                    day: $day,
                    capital: $capital,
                    t0: $t0,
                    codes: archivedCodes,
                    days: days,
                    displayName: displayName,
                    isLight: isLight,
                    onRun: run
                )
                if !message.isEmpty {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    .plainCard(isLight: isLight)
                }
                if let report {
                    GridOptimizeParamsSection(report: report, isLight: isLight)
                    GridOptimizeCostSection(report: report, isLight: isLight)
                    GridOptimizePnlSection(report: report, isLight: isLight)
                    GridOptimizeCandidatesSection(
                        report: report,
                        expanded: $showAllCandidates,
                        isLight: isLight
                    )
                }
                if let experience {
                    GridOptimizeExperienceSection(
                        name: displayName(code),
                        record: experience,
                        isLight: isLight
                    )
                }
                GridOptimizeDisclaimerSection(isLight: isLight)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .background(.clear)
            .navigationTitle("复盘并寻找当日最优")
            .toolbarBackground(.hidden, for: .navigationBar)
            .keyboardDoneToolbar()
            .navigationBarTitleDisplayMode(.inline)
            .themedSheetBackground()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear(perform: prime)
            .onChange(of: code) { _, newValue in primeCode(newValue) }
        }
    }

    private func prime() {
        if code.isEmpty, let first = archivedCodes.first { code = first }
        if day.isEmpty { day = days.first ?? "" }
        experience = store.gridExperience(forCode: code)
    }

    private func primeCode(_ newValue: String) {
        day = store.intradayDays(forCode: newValue).first ?? ""
        report = nil
        message = ""
        experience = store.gridExperience(forCode: newValue)
    }

    private func run() {
        let text = capital.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let money = Double(text) ?? 0
        switch store.optimizeGridReplay(code: code, day: day, capital: money, t0: t0) {
        case .success(let output):
            report = output
            message = ""
            store.recordGridExperience(output)
            experience = store.gridExperience(forCode: code)
        case .failure(let error):
            report = nil
            message = error.localizedDescription
        }
    }
}

// MARK: - 输入

private struct GridOptimizeInputSection: View {
    @Binding var code: String
    @Binding var day: String
    @Binding var capital: String
    @Binding var t0: Bool
    let codes: [String]
    let days: [String]
    let displayName: (String) -> String
    let isLight: Bool
    let onRun: () -> Void

    var body: some View {
        Section("输入") {
            if codes.isEmpty {
                Text("分时档案里还没有标的。先在自选或 ETF 持仓里留着行情，应用在前台时会自动采集分时。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("标的", selection: $code) {
                    ForEach(codes, id: \.self) { item in
                        Text("\(displayName(item)) · \(item)").tag(item)
                    }
                }
                if days.isEmpty {
                    Text("这个标的还没有分时档案，换一个标的。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker("交易日", selection: $day) {
                        ForEach(days, id: \.self) { item in Text(item).tag(item) }
                    }
                }
                LabeledContent("计划资金（元）") {
                    TextField("20000", text: $capital)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text("常用").scaledFont(10, weight: .medium).foregroundStyle(.secondary)
                    ForEach(["10000", "20000", "50000", "100000"], id: \.self) { value in
                        Button {
                            capital = value
                        } label: {
                            Text(capital == value ? "● \(value)" : value)
                                .scaledFont(11, weight: capital == value ? .semibold : .regular)
                                .monospacedDigit()
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    Color(uiColor: .secondarySystemBackground).opacity(0.6),
                                    in: Capsule(style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                Toggle("支持 T+0（当天买入可当天卖出）", isOn: $t0)
                Text("ETF / 债券 / 跨境品种支持 T+0；A 股股票当天买入的份额当天不能卖，关掉它更贴近真实。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .plainCard(isLight: isLight)

        Section {
            Button(action: onRun) {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("开始搜索当日最优参数").scaledFont(14, weight: .semibold)
                    Spacer()
                }
            }
            .disabled(code.isEmpty || day.isEmpty)
        }
        .plainCard(isLight: isLight)
    }
}

// MARK: - 最优参数

private struct GridOptimizeParamsSection: View {
    let report: GridOptimizeReport
    let isLight: Bool

    private var digits: Int { report.tick < 0.005 ? 3 : 2 }

    var body: some View {
        Section("当日最优参数 · \(report.day)") {
            LabeledContent("起始锚点", value: report.best.anchor.num(digits))
            LabeledContent("每格格距", value: "\(report.best.step.num(digits))（\(report.best.stepPercent.num(2))%）")
            LabeledContent("每格股数 / 份数", value: report.best.quantity.num(0))
            LabeledContent("当日区间", value: "\(report.dayLow.num(digits)) ~ \(report.dayHigh.num(digits))")
            LabeledContent("有效分钟点", value: "\(report.points) 个")
        }
        .plainCard(isLight: isLight)
    }
}

// MARK: - 成交与成本

private struct GridOptimizeCostSection: View {
    let report: GridOptimizeReport
    let isLight: Bool

    var body: some View {
        Section("成交与成本") {
            LabeledContent("买入 / 卖出", value: "\(report.best.buyCount) 笔 / \(report.best.sellCount) 笔")
            LabeledContent("成交合计", value: "\(report.best.fills) 笔")
            LabeledContent("佣金", value: report.best.commissionCost.cny())
            LabeledContent("滑点", value: report.best.slippageCost.cny())
            LabeledContent("成本合计", value: report.best.fees.cny())
        }
        .plainCard(isLight: isLight)
    }
}

// MARK: - 收益归因

private struct GridOptimizePnlSection: View {
    let report: GridOptimizeReport
    let isLight: Bool

    private var alphaColor: Color { report.best.alpha >= 0 ? .red : .green }
    private var profitColor: Color { report.best.profit >= 0 ? .red : .green }

    var body: some View {
        Section("收益归因") {
            LabeledContent("期末权益", value: report.best.endingEquity.cny())
            HStack {
                Text("网格盈亏").scaledFont(13)
                Spacer()
                Text("\(report.best.profit.directionMark()) \(report.best.profit.cny())")
                    .scaledFont(13, weight: .semibold).monospacedDigit().foregroundStyle(profitColor)
            }
            LabeledContent("持有不动盈亏", value: "\(report.best.holdProfit.directionMark()) \(report.best.holdProfit.cny())")
            HStack {
                Text("跑赢持有").scaledFont(13, weight: .semibold)
                Spacer()
                Text("\(report.best.alpha.directionMark()) \(report.best.alpha.cny())")
                    .scaledFont(13, weight: .bold).monospacedDigit().foregroundStyle(alphaColor)
            }
            LabeledContent("最大回撤", value: "\(report.best.maxDrawdown.num(2))%")
            Text("「跑赢持有」= 网格盈亏 − 同一时点买入后什么都不做的盈亏。它才是这套参数的胜负依据："
                + "当天本来就是单边上涨的话，两组参数都能赚，但只有真正的高抛低吸才会把差值做正。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

// MARK: - 全部候选

private struct GridOptimizeCandidatesSection: View {
    let report: GridOptimizeReport
    @Binding var expanded: Bool
    let isLight: Bool

    private var digits: Int { report.tick < 0.005 ? 3 : 2 }
    private var visible: [GridOptimizeCandidate] {
        expanded ? report.candidates : Array(report.candidates.prefix(5))
    }

    var body: some View {
        Section("候选参数（共 \(report.candidates.count) 组）") {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                GridOptimizeCandidateRow(
                    item: item,
                    rank: index + 1,
                    digits: digits,
                    isBest: item.id == report.best.id
                )
            }
            Button(expanded ? "收起，只看前 5 组" : "展开全部 \(report.candidates.count) 组") {
                expanded.toggle()
            }
            Text("3 个锚点（首价 / 前 15 点均价 / 当日中位价）× 7 个步长倍率（1 / 1.25 / 1.5 / 2 / 2.5 / 3 / 4），"
                + "按「跑赢持有」从高到低排。锚点重复或落在当日区间外的组合已被去掉。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

private struct GridOptimizeCandidateRow: View {
    let item: GridOptimizeCandidate
    let rank: Int
    let digits: Int
    let isBest: Bool

    private var alphaColor: Color { item.alpha >= 0 ? .red : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(isBest ? "#\(rank) 最优" : "#\(rank)")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(isBest ? Color.accentColor : .secondary)
                    .monospacedDigit()
                Text("锚 \(item.anchor.num(digits))").scaledFont(11).monospacedDigit()
                Text("格 \(item.step.num(digits))").scaledFont(11).monospacedDigit()
                Spacer()
                Text("\(item.alpha.directionMark()) \(item.alpha.cny())")
                    .scaledFont(12, weight: .semibold).monospacedDigit().foregroundStyle(alphaColor)
            }
            Text("每格 \(item.quantity.num(0)) 份 · 买 \(item.buyCount) 卖 \(item.sellCount) · "
                + "成本 \(item.fees.cny()) · 网格盈亏 \(item.profit.cny()) · 回撤 \(item.maxDrawdown.num(2))%")
                .scaledFont(10).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - 策略经验

private struct GridOptimizeExperienceSection: View {
    let name: String
    let record: GridExperienceRecord
    let isLight: Bool

    var body: some View {
        Section("策略经验 · \(name)") {
            LabeledContent("已复盘次数", value: "\(record.samples) 次")
            LabeledContent("跑赢持有的次数", value: "\(record.wins) 次（\(record.winRate.num(1))%）")
            LabeledContent("平均跑赢金额", value: record.averageAlpha.cny())
            LabeledContent("中位格距", value: "\(record.medianStepPercent.num(2))%")
            Text("只统计这台设备上跑过的复盘，用来回答「这个标的过去几次事后最优的格距大概落在哪一档」。"
                + "它不参与选参，也不代表未来。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}

// MARK: - 免责

private struct GridOptimizeDisclaimerSection: View {
    let isLight: Bool

    var body: some View {
        Section("使用说明") {
            Text("① 用了「当日完整走势」——这是事后拟合，不能当成明天的建议。\n"
                + "② 假设价格穿越档位就成交，不含盘口排队与真实成交量限制，每分钟最多模拟一笔。\n"
                + "③ 只代表这一天，不代表这套参数能持续有效。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("回放数据来自本机分时档案（App 在前台时自动采集 + NAS 归档合并）。"
                + "有效分钟点少于 30 个的日子会被直接拒绝，不会硬算出一个「最优」。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainCard(isLight: isLight)
    }
}
