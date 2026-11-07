import SwiftUI

/// 修复手续费录入错误。
///
/// 场景很具体：下单时估了个费用（券商当晚才清算），第二天看到的实际费用对不上。
/// 之前唯一的办法是「删除这笔重录」—— 而那会连带改现金、改份额、多写一条审计，
/// 代价远大于「把费用改对」。
///
/// 这里只改费用本身，然后按键把此后所有成本与已实现重算一遍。
/// 重算不会碰份额、价格、日期 —— 那些是你确认过的成交事实。
struct FeeCorrectionView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: LedgerEntry?
    @State private var draftFee = ""
    @State private var reason = ""
    @State private var message: String?
    @State private var isError = false

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: store.resolvedAppearance).isLight)
    }

    /// 只列能改的：导入的历史流水没有真实成交含义，不该在这里改。
    private var candidates: [LedgerEntry] {
        store.data.ledger
            .filter { $0.affectsHoldings != false }
            .sorted { $0.date > $1.date }
            .prefix(30)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.sectionGap) {
                    if let selected {
                        editor(for: selected)
                    } else {
                        picker
                    }
                    if let message {
                        Text(message)
                            .scaledFont(palette.fsMicro)
                            .foregroundStyle(isError ? PnLColor.down : palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    noteCard
                }
                .padding(.horizontal, palette.pageInset)
                .padding(.vertical, 14)
            }
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle(selected == nil ? "选择成交" : "更正手续费")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selected != nil {
                        Button("返回") {
                            selected = nil
                            draftFee = ""
                            reason = ""
                            message = nil
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: 选一笔

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            DsSectionHeader(palette: palette, title: "最近成交")
            if candidates.isEmpty {
                Text("账本里还没有可更正的成交。")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates) { fill in
                        Button {
                            Haptics.tap()
                            selected = fill
                            draftFee = String(format: "%.2f", fill.fee)
                            reason = ""
                            message = nil
                        } label: {
                            HStack(spacing: 8) {
                                Text(fill.side == .buy ? "买" : "卖")
                                    .scaledFont(9.5, weight: .bold)
                                    .foregroundStyle(fill.side == .buy ? PnLColor.up : PnLColor.down)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background {
                                        Capsule().fill((fill.side == .buy ? PnLColor.up : PnLColor.down)
                                            .opacity(palette.isLight ? 0.12 : 0.18))
                                    }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(fill.name)
                                        .scaledFont(palette.fsRow, weight: .medium)
                                        .foregroundStyle(palette.ink)
                                        .lineLimit(1)
                                    Text("\(MarketCalendar.isoDay(fill.date)) · \(fill.quantity.num(0)) 份 · \(fill.price.num(3))")
                                        .scaledFont(9.5)
                                        .foregroundStyle(palette.ink3)
                                }
                                Spacer(minLength: 4)
                                Text("费 \(fill.fee.cny())")
                                    .scaledFont(palette.fsMicro)
                                    .monospacedDigit()
                                    .foregroundStyle(palette.ink2)
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .dsSurface(palette, radius: 18, padding: 0)
            }
        }
    }

    // MARK: 改费用

    private func editor(for fill: LedgerEntry) -> some View {
        let preview = store.feeCorrectionPreview(fillID: fill.id, newFee: Double(draftFee) ?? fill.fee)
        return VStack(alignment: .leading, spacing: palette.sectionGap) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(fill.name)（\(fill.code)）")
                    .scaledFont(palette.fsTitle, weight: .semibold)
                    .foregroundStyle(palette.ink)
                Text("\(MarketCalendar.isoDay(fill.date)) · \(fill.side == .buy ? "买入" : "卖出") \(fill.quantity.num(0)) 份 · 成交额 \(fill.gross.cny())")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink3)
                Text("当前记录费用 \(fill.fee.cny())")
                    .scaledFont(palette.fsMicro)
                    .foregroundStyle(palette.ink2)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("实际费用")
                    .scaledFont(palette.fsLabel, weight: .medium)
                    .foregroundStyle(palette.ink2)
                TextField("0.00", text: $draftFee)
                    .keyboardType(.decimalPad)
                    .scaledFont(palette.fsStat, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.cardSoft) }
                    .keyboardDoneToolbar()

                Text("更正原因（必填）")
                    .scaledFont(palette.fsLabel, weight: .medium)
                    .foregroundStyle(palette.ink2)
                TextField("例如：券商清算后实际收取 5.32 元", text: $reason, axis: .vertical)
                    .lineLimit(2...4)
                    .scaledFont(palette.fsRow)
                    .foregroundStyle(palette.ink)
                    .padding(10)
                    .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.cardSoft) }
            }
            .padding(14)
            .dsSurface(palette, radius: 20, padding: 0)

            if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("影响")
                        .scaledFont(palette.fsLabel, weight: .semibold)
                        .foregroundStyle(palette.ink2)
                    HStack(spacing: 14) {
                        impact("参考现金", preview.cashDelta)
                        impact("已实现", preview.realizedDelta)
                    }
                    Text("这一笔之后同标的还有 \(preview.affectedFollowingFills) 笔成交，会按新费用一起重算成本。份额、价格、日期不变。")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsSurface(palette, radius: 20, padding: 0)
            }

            Button {
                apply(fill)
            } label: {
                Text("按新费用重算")
                    .scaledFont(palette.fsLabel, weight: .semibold)
                    // 显式写 Color：三元里 `.white` 会被推断成 palette 另一侧的样式类型，
                    // 编译报「LinearGradient 与 Color 不等价」。
                    .foregroundStyle(palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.accent) }
            }
            .buttonStyle(.plain)
            .disabled((Double(draftFee) == nil) || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity((Double(draftFee) == nil) || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
    }

    private func impact(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .scaledFont(9.5)
                .foregroundStyle(palette.ink3)
            Text((value > 0 ? "+" : "") + value.cny())
                .scaledFont(palette.fsLabel, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(PnLColor.of(value))
        }
    }

    private func apply(_ fill: LedgerEntry) {
        guard let fee = Double(draftFee) else {
            message = "费用必须是数字。"
            isError = true
            return
        }
        do {
            try store.correctTradeFee(fillID: fill.id, actualFee: fee, reason: reason)
            Haptics.success()
            isError = false
            message = "已更正，并按新费用重算了此后全部成本与已实现。"
            selected = nil
            draftFee = ""
            reason = ""
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private var noteCard: some View {
        Text("只改费用，不改成交。参考现金会按费用差额同步调整（仅限记录了现金联动的成交）。若重算后发现份额与持仓对不上，说明账本本身缺起点，先把起点补上再来改费用。")
            .scaledFont(palette.fsMicro)
            .foregroundStyle(palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}
