import SwiftUI

private struct PlannedCashEvent: Identifiable {
    var date: String
    var name: String
    var source: String
    var amount: Double // Positive is an inflow, negative is an outflow.
    var id: String { "\(date)|\(source)|\(name)" }
}

struct CashForecastView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    private var events: [PlannedCashEvent] { makeEvents() }
    private var netChange: Double { events.reduce(0) { $0 + $1.amount } }

    var body: some View {
        NavigationStack {
            List {
                Section("未来 30 天") {
                    LabeledContent("当前参考现金", value: (store.data.cash).cny())
                    LabeledContent("计划现金变化", value: (netChange).cny())
                    LabeledContent("假设计划全部执行后", value: (store.data.cash + netChange).cny())
                    if store.data.cash + netChange < 0 {
                        Text("按全部买入计划使用参考现金的情景会出现资金缺口。实际资金来源和成交结果可能不同。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section("计划明细") {
                    if events.isEmpty {
                        ContentUnavailableView("未来 30 天没有已排期的现金计划", systemImage: "calendar")
                    } else {
                        ForEach(events) { event in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.name)
                                    Text("\(event.date) · \(event.source)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text((event.amount).cny())
                                    .foregroundStyle(event.amount < 0 ? .orange : .green)
                            }
                        }
                    }
                }
                Section {
                    Text("定投按计划周期估算并顺延到下一个已知开放日；交易计划使用计划复核日期，仅统计仍处于‘计划中’状态的记录。假设买入从参考现金支出、卖出回到参考现金。它不检查银行或销售平台余额、不下单、不扣款、不修改现金账；未记录的外部资金和 2027 年及以后的交易所休市安排不在估算内。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("未来现金流预测")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func makeEvents() -> [PlannedCashEvent] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let today = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 30, to: today) else { return [] }
        let startDay = day(today)
        let endDay = day(end)
        let closures = MarketCalendar.mainlandClosures2026.union(store.data.customMarketHolidays)
        var result: [PlannedCashEvent] = []

        for plan in store.data.fundDCAPlans where plan.enabled {
            guard let planStart = parseDay(plan.startDate), planStart <= end else { continue }
            var scheduledDays = Set<String>()
            var offset = 0
            while let candidate = calendar.date(byAdding: .day, value: offset, to: today), candidate <= end {
                let candidateDay = day(candidate)
                guard candidate >= calendar.startOfDay(for: planStart) else { offset += 1; continue }
                let weekday = calendar.component(.weekday, from: candidate)
                let due: Bool
                switch plan.frequency {
                case .daily:
                    due = (2...6).contains(weekday)
                case .weekly:
                    due = weekday == plan.weekday
                case .biweekly:
                    let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: planStart), to: candidate).day ?? -1
                    due = elapsed >= 0 && elapsed % 14 == 0
                case .monthly:
                    due = calendar.component(.day, from: candidate) == plan.monthDay
                }
                if due, let openDate = nextOpenDay(from: candidate, through: end, calendar: calendar, closures: closures) {
                    let scheduled = day(openDate)
                    if !plan.processedDates.contains(scheduled), scheduledDays.insert(scheduled).inserted {
                        result.append(PlannedCashEvent(date: scheduled, name: plan.name, source: "定投", amount: -plan.amount))
                    }
                }
                offset += 1
                if offset > 31 { break }
            }
        }

        for plan in store.data.tradePlans where plan.status == .planned && !plan.reviewDate.isEmpty {
            let planDay = String(plan.reviewDate.prefix(10))
            guard planDay >= startDay, planDay <= endDay, plan.amount.isFinite, plan.amount > 0 else { continue }
            result.append(PlannedCashEvent(date: planDay, name: plan.name, source: "交易计划",
                                           amount: plan.side == .buy ? -plan.amount : plan.amount))
        }
        return result.sorted { $0.date == $1.date ? $0.name < $1.name : $0.date < $1.date }
    }

    private func nextOpenDay(from date: Date, through end: Date, calendar: Calendar,
                             closures: Set<String>) -> Date? {
        var candidate = calendar.startOfDay(for: date)
        for _ in 0..<8 {
            guard candidate <= end else { return nil }
            let weekday = calendar.component(.weekday, from: candidate)
            if weekday != 1 && weekday != 7 && !closures.contains(day(candidate)) { return candidate }
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
            candidate = next
        }
        return nil
    }

    private func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }

    private func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
