import SwiftUI

// MARK: - 收息

/// 「收息」页：把散在三个入口里的分红/收益信息收到一处。
///
/// 原来要看得分开三次：基金收益日历在场外基金页、场内收益日历在资产页、
/// ETF 分红记录在分析工具里。这里先给出「这个月收了多少、今年大概能收多少」，
/// 再给三个明细入口，用户不用先记住东西在哪。
struct IncomeHubView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.appAppearance) private var appearance

    @State private var showFundCalendar = false
    @State private var showETFCalendar = false
    @State private var showDividendCalendar = false

    private var isLight: Bool {
        AppTheme.palette(for: AppAppearance.resolved(appearance)).isLight
    }

    private var accent: Color { store.effectiveAccentColor }

    private var monthKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: .now)
    }

    private var yearKey: String { String(monthKey.prefix(4)) }

    /// 本月场外基金收益合计（含分红与净值波动，口径与基金收益日历一致）。
    private var fundMonthProfit: Double {
        store.fundDailyPerformance(month: monthKey).reduce(0) { $0 + $1.profit }
    }

    /// 本月已登记的场内 ETF 分红合计。
    private var etfMonthDividend: Double {
        store.data.etfDividendEvents
            .filter { $0.date.hasPrefix(monthKey) }
            .reduce(0) { sum, event in
                let quantity = store.data.holdings
                    .first { $0.code == event.code && $0.kind == .etf }?.quantity ?? 0
                return sum + event.amountPerShare * quantity
            }
    }

    private var etfYearDividend: Double {
        store.data.etfDividendEvents
            .filter { $0.date.hasPrefix(yearKey) }
            .reduce(0) { sum, event in
                let quantity = store.data.holdings
                    .first { $0.code == event.code && $0.kind == .etf }?.quantity ?? 0
                return sum + event.amountPerShare * quantity
            }
    }

    /// 年化股息估算：只在持仓里填过年化每份分红时才算，不猜。
    private var estimatedAnnualIncome: Double {
        store.data.holdings.reduce(0) { sum, holding in
            guard let perShare = holding.annualDividendPerShare, perShare > 0 else { return sum }
            return sum + perShare * holding.quantity
        }
    }

    private var incomeHoldings: Int {
        store.data.holdings.filter { ($0.annualDividendPerShare ?? 0) > 0 }.count
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                calendarSection
                recordSection
                explainSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .appListLayout()
            .background(.clear)
            .navigationTitle("收息")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showFundCalendar) { FundIncomeCalendarView() .themedSheetBackground() }
            .sheet(isPresented: $showETFCalendar) { ETFIncomeCalendarView() .themedSheetBackground() }
            .sheet(isPresented: $showDividendCalendar) { DividendCalendarView() .themedSheetBackground() }
        }
    }

    // MARK: 汇总

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("本月已收")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("¥" + (fundMonthProfit + etfMonthDividend).cny())
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(accent)
                }
                HStack(spacing: 0) {
                    statCell("场外基金", "¥" + fundMonthProfit.cny(), tint: CardTone.pnl(fundMonthProfit))
                    Divider().frame(height: 28)
                    statCell("场内分红", "¥" + etfMonthDividend.cny(), tint: nil)
                    Divider().frame(height: 28)
                    statCell("今年分红", "¥" + etfYearDividend.cny(), tint: nil)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("汇总 · \(monthKey)")
        } footer: {
            Text(fundMonthProfit >= 0
                 ? "场外基金含净值波动，不等同于到手现金；场内部分只统计已登记的分红事件。"
                 : "本月场外基金净值回撤大于分红，合计为负属正常，不代表没有收到分红。")
        }
    }

    private func statCell(_ title: String, _ value: String, tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
    }

    // MARK: 日历

    private var calendarSection: some View {
        Section {
            entryRow(title: "基金收益日历", subtitle: "按日看场外基金的当日收益与累计",
                     icon: "calendar", tint: Color(red: 0.36, green: 0.62, blue: 0.96)) {
                showFundCalendar = true
            }
            entryRow(title: "场内收益日历", subtitle: "ETF 的逐日盈亏与收益归因",
                     icon: "chart.bar.doc.horizontal", tint: Color(red: 0.40, green: 0.72, blue: 0.50)) {
                showETFCalendar = true
            }
        } header: {
            Text("收益日历")
        }
    }

    private var recordSection: some View {
        Section {
            entryRow(title: "ETF 分红记录", subtitle: "已登记的分红事件与年度估算",
                     icon: "banknote", tint: Color(red: 0.98, green: 0.66, blue: 0.20)) {
                showDividendCalendar = true
            }
            HStack {
                Text("年化股息估算")
                Spacer()
                Text(estimatedAnnualIncome > 0 ? "¥" + estimatedAnnualIncome.cny() : "未填写")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(estimatedAnnualIncome > 0 ? .primary : .secondary)
            }
            HStack {
                Text("已填写每份年化分红的持仓")
                Spacer()
                Text("\(incomeHoldings) 只")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("分红")
        } footer: {
            Text("年化估算只累加持仓里填过「每份年化分红」的标的，填 0 或留空的不参与，不做行业均值推算。")
        }
    }

    private var explainSection: some View {
        Section {
            Text("收息页只做统计与记录，不预测分红、不代下单。分红到账会体现在现金里时，请在对应日历中登记实际金额。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 行

    private func entryRow(title: String, subtitle: String, icon: String,
                          tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
