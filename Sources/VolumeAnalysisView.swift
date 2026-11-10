import SwiftUI

// MARK: - 量能结构（只读观察页）
//
// 数据只用本机日线缓存 / `PortfolioStore.fetchDailyBars`，不连模型、不下单。
// 页面明确标出 evidenceLevel = experimental：量能结构只是观察材料，不是结论。

struct VolumeAnalysisView: View {
    /// 推入已有导航栈时 true：不再自建 NavigationStack，隐藏完成/关闭按钮。
    var embedded: Bool = false
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    @State private var code: String = ""
    @State private var isLoading = false
    @State private var message: String?

    private var s: ThemeSemantics { .of(appearance) }
    private var palette: DsPalette { .of(appearance) }

    private var candidates: [String] {
        var seen = Set<String>()
        var list: [String] = []
        for h in store.data.holdings where seen.insert(h.code).inserted { list.append(h.code) }
        for q in store.data.quotes where seen.insert(q.code).inserted { list.append(q.code) }
        return list
    }

    private var bars: [DailyBar] { store.dailyBars[code] ?? [] }
    private var result: VolumeAnalysisResult { VolumeAnalysisEngine.daily(bars) }

    var body: some View {
        PageHost(embedded: embedded) {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.sectionGap) {
                    pickerCard
                    evidenceCard
                    if let latest = result.latest {
                        latestCard(latest)
                        historyCard
                    } else {
                        emptyCard
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(s.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, palette.pageInset)
                .padding(.vertical, palette.pad)
            }
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .navigationTitle("量能结构")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { if !embedded { Button("完成") { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading || code.isEmpty)
                }
            }
            .task {
                if code.isEmpty { code = candidates.first ?? "" }
                await load(force: false)
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 卡片

    private var pickerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("观察标的")
                .font(.caption)
                .foregroundStyle(s.ink2)
            if candidates.isEmpty {
                Text("自选与持仓都为空，先添加一只标的。")
                    .font(.footnote)
                    .foregroundStyle(s.ink2)
            } else {
                Picker("标的", selection: $code) {
                    ForEach(candidates, id: \.self) { item in
                        Text(displayName(item)).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .foregroundStyle(s.ink)
                .onChange(of: code) { _, _ in
                    Task { await load(force: false) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette: palette, s: s)
    }

    private var evidenceCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(s.warn)
            VStack(alignment: .leading, spacing: 4) {
                Text("实验性观察 · 不构成买卖建议")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(s.ink)
                Text("均线窗口 5/10/20/60；已收盘 K 线以前 20 根均量为基准，形成中 K 线只用历史量。成交量来自本机日线缓存，qfq 前复权不改变成交量。")
                    .font(.caption2)
                    .foregroundStyle(s.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette: palette, s: s)
    }

    private func latestCard(_ point: VolumeAnalysisPoint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最新一根")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(s.ink)
                Spacer()
                Text(bars.last?.date ?? "--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(s.ink2)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                     count: palette.statColumns), spacing: 8) {
                cell("成交量", point.volume?.num(0) ?? "--")
                cell("MA5", point.volumeMA5?.num(0) ?? "--")
                cell("MA20", point.volumeMA20?.num(0) ?? "--")
                cell("MA60", point.volumeMA60?.num(0) ?? "--")
                cell("量比", point.volumeToComparisonBaseline.map { $0.num(2) + "×" } ?? "--")
                cell("较前一根", point.volumeChangeRate.map { $0.pct(2) } ?? "--")
            }
            HStack(spacing: 8) {
                badge(stateLabel(point.state), tint: stateTint(point.state))
                badge(relationLabel(point.priceVolumeRelation), tint: palette.accent)
            }
            Text("连续放量 \(point.consecutiveExpansionCount) 根 · 连续缩量 \(point.consecutiveContractionCount) 根")
                .font(.caption)
                .foregroundStyle(s.ink2)
            if !point.reasonCodes.isEmpty {
                Text("原因码：" + point.reasonCodes.joined(separator: "、"))
                    .font(.caption2)
                    .foregroundStyle(s.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette: palette, s: s)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近 \(min(20, result.points.count)) 根")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(s.ink)
            ForEach(Array(result.points.suffix(20).reversed().enumerated()), id: \.offset) { _, point in
                HStack(spacing: 6) {
                    Text(dayText(point.timestamp))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(s.ink2)
                        .frame(width: 62, alignment: .leading)
                    Text(point.volume?.num(0) ?? "--")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(s.ink)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(point.volumeToComparisonBaseline.map { $0.num(2) + "×" } ?? "--")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(stateTint(point.state))
                        .frame(width: 52, alignment: .trailing)
                    Text(stateLabel(point.state))
                        .font(.caption2)
                        .foregroundStyle(s.ink2)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette: palette, s: s)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有可用的日线")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(s.ink)
            Text(result.reasonCodes.isEmpty ? "点右上角刷新拉取日线。" : result.reasonCodes.joined(separator: "、"))
                .font(.caption2)
                .foregroundStyle(s.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(palette: palette, s: s)
    }

    // MARK: 小部件

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(s.ink2)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(s.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(s.cardSoft) }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func displayName(_ raw: String) -> String {
        store.data.quotes.first(where: { $0.code == raw })?.name
            ?? store.data.holdings.first(where: { $0.code == raw })?.name
            ?? raw
    }

    private func dayText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "MM-dd"
        return f.string(from: date)
    }

    private func stateLabel(_ state: VolumeState) -> String {
        switch state {
        case .unavailable: return "无数据"
        case .formingProvisional: return "形成中"
        case .aboveSameTimeBaseline: return "放量"
        case .belowSameTimeBaseline: return "缩量"
        case .atSameTimeBaseline: return "持平"
        }
    }

    private func stateTint(_ state: VolumeState) -> Color {
        switch state {
        case .aboveSameTimeBaseline: return s.danger   // A 股放量用暖色提示，不表示涨跌
        case .belowSameTimeBaseline: return s.ok
        default: return s.ink2
        }
    }

    private func relationLabel(_ relation: PriceVolumeRelation) -> String {
        switch relation {
        case .unavailable: return "价量关系不可用"
        case .provisional: return "价量关系待收盘"
        case .priceUpVolumeAboveBaseline: return "价涨量增"
        case .priceUpVolumeAtOrBelowBaseline: return "价涨量平/缩"
        case .priceDownVolumeAboveBaseline: return "价跌量增"
        case .priceDownVolumeAtOrBelowBaseline: return "价跌量平/缩"
        case .unchangedPriceVolumeAboveBaseline: return "价平量增"
        case .unchangedPriceVolumeAtOrBelowBaseline: return "价平量平/缩"
        }
    }

    // MARK: 数据

    private func load(force: Bool) async {
        guard !code.isEmpty else { return }
        if !force && !bars.isEmpty { return }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await store.fetchDailyBars(code: code, count: 120, force: force)
            message = nil
        } catch {
            message = "日线拉取失败：\(error.localizedDescription)。下方仍展示本机已有缓存。"
        }
    }
}

private extension View {
    func card(palette: DsPalette, s: ThemeSemantics) -> some View {
        let shape = RoundedRectangle(cornerRadius: palette.radius, style: .continuous)
        return self
            .padding(palette.pad)
            .background { shape.fill(s.card) }
            .overlay { shape.strokeBorder(s.hairline, lineWidth: 1) }
            .clipShape(shape)
    }
}
