import SwiftUI

/// 账户级杂费：平台费、融资利息、托管费、数据费。
///
/// 为什么值得单独一页：这些钱不在任何一笔成交流水里，所以「已实现盈亏」
/// 永远不会减去它们。记在这里之后，收益归因才有一个能对上的成本项。
struct ExpenseView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var showEditor = false
    @State private var pendingDelete: AccountExpense?
    @State private var errorMessage: String?

    private var palette: DsPalette { DsPalette.of(store.resolvedAppearance) }

    private var yearSummary: AccountExpenseSummary { store.expenseSummaryThisYear() }
    private var monthSummary: AccountExpenseSummary { store.expenseSummaryThisMonth() }
    private var yearTotal: Double { yearSummary.total }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.gap) {
                    heroCard
                    if !yearSummary.byCategory.isEmpty {
                        categoryCard
                    }
                    recordsCard
                    disclaimerCard
                }
                .padding(.horizontal, palette.pageInset)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("账户杂费")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.tap()
                        showEditor = true
                    } label: {
                        Label("记一笔", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                ExpenseEditorSheet { message in
                    errorMessage = message
                }
                .environmentObject(store)
                .themedSheetBackground()
            }
            .confirmationDialog("删除这笔杂费？",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                presenting: pendingDelete) { expense in
                Button(expense.linkedCash ? "删除并补回 \(expense.amount.cny())" : "删除",
                       role: .destructive) {
                    delete(expense)
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { expense in
                Text("删除会同时删掉配套的那条现金流记录，并在账本审计里留一条「删除账户杂费」。这笔费用不再参与任何统计。")
            }
            .alert("没记上", isPresented: Binding(get: { errorMessage != nil },
                                              set: { if !$0 { errorMessage = nil } })) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .themedSheetBackground()
    }

    private func delete(_ expense: AccountExpense) {
        do {
            try store.removeAccountExpense(id: expense.id, note: "在费用列表中删除")
        } catch {
            errorMessage = error.localizedDescription
        }
        pendingDelete = nil
    }

    // MARK: 总览

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今年已记录杂费")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
            Text(yearTotal.cny())
                .scaledFont(palette.fsHero, weight: .bold, design: .rounded)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 16) {
                stat("本月", monthSummary.total.cny())
                stat("笔数", "\(yearSummary.count)")
                stat("年化占资产", yearSummary.annualizedRate.map { $0.pct(2) } ?? "--")
            }

            if let rate = yearSummary.annualizedRate {
                Text("按最近一年的杂费折算，约占平均总资产的 \(rate.pct(2))\(yearSummary.usedCurrentAssetFallback ? "（快照不足，分母用的是当前总资产）" : "")。这笔钱和买卖手续费一样，是从收益里扣掉的。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("还没有可用的资产快照，算不出占资产的比例；金额与分类统计仍然有效。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.heroRadius, padding: 18, glow: palette.accent)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).scaledFont(9.5).foregroundStyle(palette.ink3)
            Text(value)
                .scaledFont(palette.fsRow, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: 分类

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今年分类")
                .scaledFont(palette.fsTitle, weight: .semibold)
                .foregroundStyle(palette.ink)
            ForEach(yearSummary.byCategory) { item in
                let share = yearTotal > 0 ? item.amount / yearTotal : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: item.category.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.ink2)
                        Text(item.category.title)
                            .scaledFont(palette.fsLabel)
                            .foregroundStyle(palette.ink)
                        Spacer(minLength: 4)
                        Text(item.amount.cny())
                            .scaledFont(palette.fsLabel, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(palette.ink)
                        Text(share.pct(0))
                            .scaledFont(palette.fsMicro)
                            .monospacedDigit()
                            .foregroundStyle(palette.ink3)
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.cardSoft)
                            Capsule()
                                .fill(palette.accent)
                                .frame(width: max(2, geometry.size.width * CGFloat(min(1, max(0, share)))))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.radius, padding: palette.pad)
    }

    // MARK: 记录

    private var recordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("记录")
                    .scaledFont(palette.fsTitle, weight: .semibold)
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 4)
                Text("\(store.data.accountExpenses.count) 笔")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
            }

            if store.data.accountExpenses.isEmpty {
                Text("还没有记录。券商 App 里能查到的「其他扣费」「融资利息」都可以记在这里；记一笔只要填金额、类别和一句话说明。")
                    .scaledFont(palette.fsLabel)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.expensesByMonth()) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.month)
                            .scaledFont(palette.fsMicro, weight: .semibold)
                            .foregroundStyle(palette.ink3)
                        ForEach(group.items) { expense in
                            expenseRow(expense)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.radius, padding: palette.pad)
    }

    private func expenseRow(_ expense: AccountExpense) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: expense.category.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 26, height: 26)
                .background { Circle().fill(palette.accentDim) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(expense.category.title)
                        .scaledFont(palette.fsLabel, weight: .semibold)
                        .foregroundStyle(palette.ink)
                    Text(Self.dayText(expense.date))
                        .scaledFont(palette.fsMicro)
                        .monospacedDigit()
                        .foregroundStyle(palette.ink3)
                    if !expense.linkedCash {
                        Text("账外")
                            .scaledFont(9.5)
                            .foregroundStyle(palette.ink2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background { Capsule().fill(palette.cardSoft) }
                    }
                }
                Text(expense.memo)
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                Text(expense.amount.cny())
                    .scaledFont(palette.fsLabel, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
                Button {
                    Haptics.tap()
                    pendingDelete = expense
                } label: {
                    Text("删除")
                        .scaledFont(9.5)
                        .foregroundStyle(palette.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.cardSoft)
        }
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("口径")
                .scaledFont(palette.fsMicro, weight: .semibold)
                .foregroundStyle(palette.ink3)
            Text("杂费只做记录与统计：勾了「同步扣现金」会从参考现金里减掉，并补一条 external = false 的现金流，因此不会被算成你转出去的钱；没勾就是账外支付，只进统计。它不会改动持仓、成本或已实现盈亏 —— 想把这些费用摊进持仓成本，请用「记一笔交易」里的费用字段。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - 录入表单

private struct ExpenseEditorSheet: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    /// 保存失败时回传给外层列表显示（本页自己也可能直接弹）。
    let onError: (String) -> Void

    @State private var amountText = ""
    @State private var category: AccountExpense.Category = .platform
    @State private var date = Date.now
    @State private var memo = ""
    @State private var linkedCash = true
    @State private var errorMessage: String?

    private var palette: DsPalette { DsPalette.of(store.resolvedAppearance) }

    private var amount: Double? {
        let cleaned = amountText
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "，", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0, value.isFinite else { return nil }
        return value
    }

    private var canSave: Bool {
        amount != nil && !memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.gap) {
                    amountCard
                    categoryCard
                    detailCard
                    if let errorMessage {
                        Text(errorMessage)
                            .scaledFont(palette.fsLabel)
                            .foregroundStyle(CardTone.warn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dsSurface(palette, radius: 14, padding: 12)
                    }
                }
                .padding(.horizontal, palette.pageInset)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("记一笔杂费")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("金额")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("¥")
                    .scaledFont(22, weight: .semibold)
                    .foregroundStyle(palette.ink3)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .scaledFont(30, weight: .bold, design: .rounded)
                    .foregroundStyle(palette.ink)
            }
            Text("正数表示从账户支出。退款请在说明里写清，金额仍记正数。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.heroRadius, padding: 18)
    }

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("类别")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(AccountExpense.Category.allCases) { item in
                    Button {
                        Haptics.tap()
                        category = item
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 10, weight: .semibold))
                            Text(item.title)
                                .scaledFont(palette.fsMicro, weight: .medium)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(category == item ? palette.ink : palette.ink2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(category == item ? palette.accentDim : palette.cardSoft)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.radius, padding: palette.pad)
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("发生日期", selection: $date, displayedComponents: .date)
                .scaledFont(palette.fsLabel)
                .foregroundStyle(palette.ink)

            VStack(alignment: .leading, spacing: 4) {
                Text("说明（必填）")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                TextField("例如：券商 App 月度平台费", text: $memo, axis: .vertical)
                    .lineLimit(2...4)
                    .scaledFont(palette.fsLabel)
                    .foregroundStyle(palette.ink)
            }

            Toggle("同时从参考现金里扣减", isOn: $linkedCash)
                .scaledFont(palette.fsLabel)
                .tint(palette.accent)

            Text(linkedCash
                 ? "当前参考现金 \(store.data.cash.cny())。保存后会扣掉这笔金额，并补一条不外转的现金流。"
                 : "只做统计，不动参考现金。适合这笔费用在别的账户里扣的情况。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.radius, padding: palette.pad)
    }

    private func save() {
        guard let amount else {
            errorMessage = "金额格式不对。"
            return
        }
        do {
            try store.addAccountExpense(amount: amount, category: category, date: date,
                                        memo: memo, linkedCash: linkedCash)
            Haptics.push()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            onError(error.localizedDescription)
        }
    }
}
