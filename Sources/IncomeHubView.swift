import SwiftUI

// MARK: - 收息

/// 「收息」页：把散在三个入口里的分红 / 收益信息收到一处。
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
    @State private var showPool = false

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: AppAppearance.resolved(appearance)).isLight)
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

    /// 收息池里已达目标股息率的只数。
    private var poolReached: Int {
        store.data.dividendPool.filter { entry in
            guard let price = currentPrice(for: entry.code), price > 0, entry.dividendPerUnit > 0 else { return false }
            return entry.dividendPerUnit / price * 100 >= store.data.dividendTargetYield
        }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.gap) {
                    summaryCard
                    poolCard
                    calendarCard
                    annualCard
                    Text("收息页只做统计与记录，不预测分红、不代下单。分红到账体现在现金里时，请在对应日历中登记实际金额。")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                        .padding(.top, 4)
                }
                .padding(.horizontal, palette.pageInset)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .background(.clear)
            .navigationTitle("收息")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showFundCalendar) { FundIncomeCalendarView() .themedSheetBackground() }
            .sheet(isPresented: $showETFCalendar) { ETFIncomeCalendarView() .themedSheetBackground() }
            .sheet(isPresented: $showDividendCalendar) { DividendCalendarView() .themedSheetBackground() }
            .sheet(isPresented: $showPool) { DividendPoolView() .themedSheetBackground() }
        }
    }

    // MARK: 汇总

    private var summaryCard: some View {
        let total = fundMonthProfit + etfMonthDividend
        return VStack(alignment: .leading, spacing: 12) {
            Text("本月已收 · \(monthKey)")
                .scaledFont(palette.fsLabel, weight: .medium)
                .foregroundStyle(palette.ink2)
            Text("¥" + total.cny())
                .scaledFont(palette.fsHero, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 0) {
                statCell("场外基金", "¥" + fundMonthProfit.cny(),
                         tint: CardTone.pnl(fundMonthProfit) ?? palette.ink)
                statCell("场内分红", "¥" + etfMonthDividend.cny(), tint: palette.ink)
                statCell("今年分红", "¥" + etfYearDividend.cny(), tint: palette.ink)
            }
            Text(fundMonthProfit >= 0
                 ? "场外基金含净值波动，不等同于到手现金；场内部分只统计已登记的分红事件。"
                 : "本月场外基金净值回撤大于分红，合计为负属正常，不代表没有收到分红。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.heroRadius, padding: 18)
    }

    private func statCell(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
            Text(value)
                .scaledFont(13, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 收息池

    private var poolCard: some View {
        Button {
            Haptics.tap()
            showPool = true
        } label: {
            HStack(spacing: 12) {
                DsIconTile(symbol: "yensign.circle.fill", tint: accent, size: 38, palette: palette)
                VStack(alignment: .leading, spacing: 3) {
                    Text("收息池")
                        .scaledFont(palette.fsRow, weight: .semibold)
                        .foregroundStyle(palette.ink)
                    Text(store.data.dividendPool.isEmpty
                         ? "加入红利标的，填上每份年分红即可算股息率与买点"
                         : "\(store.data.dividendPool.count) 只 · 已达目标 \(poolReached) 只 · 目标 \(store.data.dividendTargetYield.num(1))%")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink3)
            }
            .dsSurface(palette, radius: 18, padding: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 日历

    private var calendarCard: some View {
        VStack(spacing: 0) {
            entryRow(title: "基金收益日历", subtitle: "按日看场外基金的当日收益与累计",
                     icon: "calendar", tint: palette.accent) {
                showFundCalendar = true
            }
            divider
            entryRow(title: "场内收益日历", subtitle: "ETF 的逐日盈亏与收益归因",
                     icon: "chart.bar.doc.horizontal", tint: Color(hex: 0x35C08A)) {
                showETFCalendar = true
            }
            divider
            entryRow(title: "ETF 分红记录", subtitle: "已登记的分红事件与年度估算",
                     icon: "banknote", tint: Color(hex: 0xE8B33A)) {
                showDividendCalendar = true
            }
        }
        .padding(.horizontal, 14)
        .dsSurface(palette, radius: 18, padding: 0)
    }

    private var divider: some View {
        Rectangle().fill(palette.hairline).frame(height: 1)
    }

    // MARK: 年化

    private var annualCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("年化股息估算")
                    .scaledFont(palette.fsLabel, weight: .medium)
                    .foregroundStyle(palette.ink2)
                Spacer()
                Text(estimatedAnnualIncome > 0 ? "¥" + estimatedAnnualIncome.cny() : "未填写")
                    .scaledFont(palette.fsTitle, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(estimatedAnnualIncome > 0 ? palette.ink : palette.ink3)
            }
            HStack {
                Text("已填写每份年化分红的持仓")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                Spacer()
                Text("\(incomeHoldings) 只")
                    .scaledFont(palette.fsMicro, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink2)
            }
            Text("只累加填过「每份年化分红」的标的，填 0 或留空的不参与，不做行业均值推算。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 18, padding: 16)
    }

    // MARK: 行

    private func entryRow(title: String, subtitle: String, icon: String,
                          tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                DsIconTile(symbol: icon, tint: tint, size: 34, palette: palette)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .scaledFont(14, weight: .medium)
                        .foregroundStyle(palette.ink)
                    Text(subtitle)
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink3)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func currentPrice(for code: String) -> Double? {
        if let quote = store.data.quotes.first(where: { $0.code == code }), quote.price > 0 {
            return quote.price
        }
        if let holding = store.data.holdings.first(where: { $0.code == code }), holding.current > 0 {
            return holding.current
        }
        return nil
    }
}
