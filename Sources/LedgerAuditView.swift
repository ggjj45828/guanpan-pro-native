import SwiftUI

// MARK: - 账本与审计

/// 账本的自证页面。
///
/// 一个账本要能被信任，必须能回答三个问题：起点是什么、后来发生了什么、
/// 现在这份状态有没有被人悄悄改过。三个问题对应三块内容：起点快照、
/// 审计链、状态指纹。现金对账和起点重录也从这里发起。
///
/// 2026-11 改版：把「场内」和「场外基金」当两个域分开陈述。
/// 之前的页面只说「账本里有成交」就锁住起点，用户看着自己一堆基金申赎
/// 却不知道锁的是哪一边；指纹也只算场内成交，删掉一笔基金流水指纹一动不动。
struct LedgerAuditView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    @State private var showCashReconcile = false
    @State private var showOpeningRewrite = false
    @State private var showLateAdopt = false
    @State private var showLiquidate = false
    @State private var toast: String?

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: AppAppearance.resolved(appearance)).isLight)
    }

    private var health: LedgerAuditHealth { store.ledgerAuditHealth() }
    private var breaks: [Int] { health.breaks }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.sectionGap) {
                    healthCard
                    openingCard
                    replayCard
                    domainCard
                    cashCard
                    auditCard
                    actionsCard
                    methodNote
                }
                .padding(.horizontal, DS.pageInset)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("账本与审计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showCashReconcile) {
                LedgerConfirmationSheet(
                    title: "现金对账",
                    prompt: "实际现金（券商 App 里的可用 + 冻结）",
                    initialAmount: store.data.cash,
                    confirmTitle: "按实际金额校准",
                    explain: "差额会记成一条现金流，说明来由，不会凭空产生收益。",
                    onResult: { toast = $0 }
                ) { amount, note in
                    let delta = try store.reconcileCashToActual(amount, note: note)
                    return delta == 0 ? "账面现金与实际一致，未做改动。"
                        : String(format: "已按实际现金校准，差额 %+.2f 已记入现金流。", delta)
                }
            }
            .sheet(isPresented: $showOpeningRewrite) {
                LedgerConfirmationSheet(
                    title: "重写账本起点",
                    prompt: "起点现金",
                    initialAmount: store.data.openingSnapshot?.cash ?? store.data.cash,
                    confirmTitle: "改写起点",
                    explain: "当前持仓会原样写成新的起点快照。账本已有成交时不允许这样做。",
                    onResult: { toast = $0 }
                ) { amount, note in
                    let prior = store.data.cash
                    store.data.cash = amount
                    let confirmation = LedgerConfirmation(reason: "重写起点", note: note)
                    do {
                        try store.rewriteOpeningSnapshot(confirmation)
                        return "起点已重写。"
                    } catch {
                        store.data.cash = prior
                        throw error
                    }
                }
            }
            .sheet(isPresented: $showLateAdopt) {
                LedgerConfirmationSheet(
                    title: "补记账本起点",
                    prompt: "补记原因（例如：先导入了基金申赎流水）",
                    initialAmount: nil,
                    confirmTitle: "以当前持仓补记起点",
                    explain: "补记的起点描述的是「从现在开始跟踪时账户的样子」，不是历史起点。只能补一次，之后不会随持仓变化而改写。",
                    onResult: { toast = $0 }
                ) { _, note in
                    let confirmation = LedgerConfirmation(reason: "补记起点", note: note)
                    let snapshot = try store.adoptOpeningSnapshotLate(confirmation)
                    return "已补记起点：现金 ¥\(snapshot.cash.cny())，持仓 \(snapshot.positionCount) 只。"
                }
            }
            .sheet(isPresented: $showLiquidate) {
                LedgerConfirmationSheet(
                    title: "全部清仓",
                    prompt: "确认句（例如：换仓到宽基）",
                    initialAmount: nil,
                    confirmTitle: "按最新价全部卖出",
                    explain: "所有份额大于 0 的持仓会按最新价记成卖出成交，现金同步回款。没有行情的标的会跳过并告知。",
                    onResult: { toast = $0 }
                ) { _, note in
                    let result = try store.liquidateAllHoldings(kind: nil, note: note)
                    return result.skipped.isEmpty
                        ? "已清仓 \(result.sold) 只。"
                        : "已清仓 \(result.sold) 只；\(result.skipped.joined(separator: "、")) 没有可用行情，未处理。"
                }
            }
            .alert("完成", isPresented: Binding(get: { toast != nil }, set: { if !$0 { toast = nil } })) {
                Button("好", role: .cancel) { toast = nil }
            } message: { Text(toast ?? "") }
        }
    }

    // MARK: 状态

    private var healthTint: Color {
        if !breaks.isEmpty { return PnLColor.down }
        return CardTone.ok
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("账本状态指纹")
                .scaledFont(DS.fsLabel, weight: .medium)
                .foregroundStyle(palette.ink2)
            Text(store.ledgerDigest)
                .scaledFont(20, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 14) {
                miniStat("场内成交", "\(store.data.ledger.count) 笔")
                miniStat("基金流水", "\(store.data.fundTransactions.count) 笔")
                miniStat("审计事件", "\(store.data.ledgerAudits.count) 条")
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: breaks.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(healthTint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(breaks.isEmpty ? "审计链自洽" : "审计链有 \(breaks.count) 处断点")
                        .scaledFont(DS.fsLabel, weight: .semibold)
                        .foregroundStyle(healthTint)
                    Text(breaks.isEmpty
                         ? "每一次账本改动都记录了前后状态指纹，链上没有缺口。"
                         : "第 \(breaks.map { String($0 + 1) }.joined(separator: "、")) 条起前后指纹对不上，说明有改动绕过了审计入口。")
                        .scaledFont(DS.fsMicro)
                        .foregroundStyle(palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !health.migrations.isEmpty {
                        Text("第 \(health.migrations.map { String($0 + 1) }.joined(separator: "、")) 条是指纹口径升级点：从那之后基金流水也进指纹，前后算法不同，不算断链。")
                            .scaledFont(DS.fsMicro)
                            .foregroundStyle(palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: DS.heroRadius, padding: 18, glow: healthTint)
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
            Text(value)
                .scaledFont(DS.fsLabel, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 起点

    private var openingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            DsSectionHeader(palette: palette, title: "起点快照")
            if let opening = store.data.openingSnapshot {
                openingFacts(opening)
                if !opening.positions.isEmpty {
                    DisclosureGroup {
                        VStack(spacing: 6) {
                            ForEach(opening.positions) { position in
                                HStack(spacing: 6) {
                                    Text(position.name)
                                        .scaledFont(DS.fsMicro, weight: .medium)
                                        .foregroundStyle(palette.ink)
                                        .lineLimit(1)
                                    Text(position.code)
                                        .scaledFont(9.5)
                                        .monospacedDigit()
                                        .foregroundStyle(palette.ink3)
                                    Spacer(minLength: 4)
                                    Text("\(position.quantity.num(0)) 份 @ \(position.cost.num(3))")
                                        .scaledFont(9.5)
                                        .monospacedDigit()
                                        .foregroundStyle(palette.ink2)
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("起点明细（\(opening.positionCount) 只）")
                            .scaledFont(DS.fsMicro, weight: .semibold)
                            .foregroundStyle(palette.ink2)
                    }
                    .tint(palette.ink2)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(CardTone.warn)
                        .padding(.top, 1)
                    Text(store.hasRecordedFills
                         ? "账本里已经有流水，但起点是空的。这种情况常见于先导入基金申赎、后补持仓的账户 —— 起点这一章需要单独补记一次。"
                         : "还没有记录账本起点。录入第一只持仓或第一笔现金时会自动记下。")
                        .scaledFont(DS.fsMicro)
                        .foregroundStyle(palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            if store.data.openingSnapshot == nil && store.hasRecordedFills {
                Button {
                    showLateAdopt = true
                } label: {
                    actionLabel("补记起点", symbol: "clock.badge.checkmark", tone: palette.accent)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showOpeningRewrite = true
                } label: {
                    actionLabel("重写起点", symbol: "clock.arrow.circlepath",
                                tone: store.canRewriteOpening ? palette.ink : palette.ink3)
                }
                .buttonStyle(.plain)
                .disabled(!store.canRewriteOpening)
                .opacity(store.canRewriteOpening ? 1 : 0.45)
            }

            Text(store.canRewriteOpening
                 ? "账本里还没有任何成交，此时持仓就等于起点，可以直接改写。"
                 : "起点已锁定：\(store.openingLockReason ?? "账本已有流水")。要减仓请记真实卖出，不要改起点。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 20, padding: 14)
    }

    private func openingFacts(_ opening: LedgerOpeningSnapshot) -> some View {
        VStack(spacing: 7) {
            factRow("记录时间", Self.dayTime.string(from: opening.capturedAt))
            factRow("来源", sourceLabel(opening.source))
            factRow("起点现金", "¥" + opening.cash.cny())
            factRow("场内持仓", "\(opening.etfPositions.count) 只 · 成本 ¥" + opening.etfCostValue.cny())
            if opening.hasFundPositions {
                factRow("场外基金", "\(opening.fundPositions.count) 只 · 成本 ¥" + opening.fundCostValue.cny())
            }
        }
    }

    private func sourceLabel(_ source: LedgerOpeningSnapshot.Source) -> String {
        switch source {
        case .recorded: return "录入持仓时记录"
        case .adopted: return "首次保存时采纳"
        case .lateAdopt: return "已有流水后补记"
        }
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .scaledFont(DS.fsLabel)
                .foregroundStyle(palette.ink2)
            Spacer(minLength: 6)
            Text(value)
                .scaledFont(DS.fsLabel, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: 重放自检

    /// 按「起点 + 逐笔」重算一遍持仓，与存储值比对。
    ///
    /// 正常情况下应该完全一致。不一致只有两种可能：
    /// ① 有代码绕过了 `recordTrade` 直接改持仓；
    /// ② 导入了历史流水但没有对应起点，份额本来就不该对上。
    /// 两种都要让人看见，而不是让人以为账本一直是自洽的。
    private var replayCard: some View {
        let rows = store.ledgerReplayDiscrepancies()
        return VStack(alignment: .leading, spacing: 10) {
            DsSectionHeader(palette: palette, title: "重放自检",
                            trailing: rows.isEmpty ? "一致" : "\(rows.count) 处不一致")
            if rows.isEmpty {
                Text("按起点快照 + 逐笔成交重算，持仓份额与单位成本都和账本一致。")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows.prefix(4)) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(row.name)
                                    .scaledFont(DS.fsRow, weight: .medium)
                                    .foregroundStyle(palette.ink)
                                    .lineLimit(1)
                                Text(row.key.code)
                                    .scaledFont(DS.fsMicro)
                                    .foregroundStyle(palette.ink3)
                                Spacer(minLength: 4)
                                Text(row.isQuantityMismatch ? "份额不符" : "成本不符")
                                    .scaledFont(9.5, weight: .semibold)
                                    .foregroundStyle(PnLColor.down)
                            }
                            Text(row.isQuantityMismatch
                                 ? "账面 \(row.storedUnits.num(2)) 份，重放 \(row.replayedUnits.num(2)) 份"
                                 : "账面成本 \(row.storedCost.num(4))，重放 \(row.replayedCost.num(4))")
                                .scaledFont(DS.fsMicro)
                                .foregroundStyle(palette.ink2)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
                .dsSurface(palette, radius: 16, padding: 0)
                Text("多数情况是导入了历史流水但没记起点 —— 重放只能看到「从某天开始的买卖」，看不到之前的持仓，所以份额对不上。这种情况补记一次起点即可，不要手改持仓。")
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 两个域

    private var domainCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            DsSectionHeader(palette: palette, title: "账本的两个域")
            domainRow(symbol: "chart.candlestick",
                      title: "场内（交易所成交）",
                      detail: store.data.ledger.isEmpty ? "还没有成交记录" : "\(store.data.ledger.count) 笔成交",
                      tint: store.data.ledger.isEmpty ? palette.ink3 : CardTone.ok)
            domainRow(symbol: "building.columns",
                      title: "场外（基金申赎 / 分红）",
                      detail: fundDomainDetail,
                      tint: store.data.fundTransactions.isEmpty ? palette.ink3 : CardTone.ok)
            Text("两个域共用一份现金，但各有各的成本口径：场内按成交加权，场外按份额与净值逐笔确认。指纹同时覆盖两边，任何一边被改动都会让指纹变化。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 20, padding: 14)
    }

    private var fundDomainDetail: String {
        let trades = store.data.fundTransactions
        guard !trades.isEmpty else { return "还没有申赎记录" }
        let pending = trades.filter { $0.status == .pending }.count
        let confirmed = trades.count - pending
        return pending > 0 ? "\(confirmed) 笔已确认 · \(pending) 笔待确认" : "\(confirmed) 笔已确认"
    }

    private func domainRow(symbol: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            DsIconTile(symbol: symbol, tint: tint, size: 32, palette: palette)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .scaledFont(DS.fsMicro, weight: .semibold)
                    .foregroundStyle(palette.ink)
                Text(detail)
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 现金

    private var cashCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            DsSectionHeader(palette: palette, title: "现金")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("¥" + store.data.cash.cny())
                    .scaledFont(24, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text("占总资产 " + store.cashPercent.pct(1))
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
            }
            Button {
                showCashReconcile = true
            } label: {
                actionLabel("按券商实际金额校准", symbol: "equal.circle", tone: palette.accent)
            }
            .buttonStyle(.plain)
            Text("差额会以「现金对账差额」记成一条现金流，收益归因里能查到来源。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 20, padding: 14)
    }

    // MARK: 审计链

    private var auditCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            DsSectionHeader(palette: palette, title: "审计链",
                            trailing: "\(store.data.ledgerAudits.count) 条")
            if store.data.ledgerAudits.isEmpty {
                Text("还没有账本改动记录。删除持仓、清仓、现金对账、重写起点都会在这里留痕。")
                    .scaledFont(DS.fsLabel)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let events = Array(store.data.ledgerAudits.reversed())
                VStack(spacing: 0) {
                    // 不用 `enumerated()`：`ForEach` 的 id 要写成 key path，
                    // 而 Swift 的 key path 指不到元组元素上，那样写会编译不过。
                    ForEach(events) { event in
                        auditRow(event, isLast: event.id == events.last?.id)
                    }
                }
            }
            Text("尾部的「前 → 后」是状态指纹片段。相邻两条必须首尾相接。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 20, padding: 14)
    }

    private func auditRow(_ event: LedgerAuditEvent, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            // 左侧时间线：圆点 + 竖线，让「只追加」这件事看得见。
            VStack(spacing: 0) {
                Circle()
                    .fill(palette.accent.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                if !isLast {
                    Rectangle()
                        .fill(palette.hairline)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.action)
                        .scaledFont(DS.fsMicro, weight: .semibold)
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.dayTime.string(from: event.occurredAt))
                        .scaledFont(9.5)
                        .monospacedDigit()
                        .foregroundStyle(palette.ink3)
                }
                Text(event.reason)
                    .scaledFont(9.5)
                    .foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.digestPair)
                    .scaledFont(9)
                    .monospacedDigit()
                    .foregroundStyle(palette.accent.opacity(0.75))
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
    }

    // MARK: 操作

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            DsSectionHeader(palette: palette, title: "操作")
            Button(role: .destructive) {
                showLiquidate = true
            } label: {
                actionLabel("全部清仓", symbol: "arrow.down.to.line", tone: PnLColor.down)
            }
            .buttonStyle(.plain)

            Button {
                if let label = store.undoLatestOperation() {
                    toast = "已撤回「\(label)」。"
                } else {
                    toast = "没有可撤回的操作。"
                }
            } label: {
                actionLabel("撤回最近一次账本改动", symbol: "arrow.uturn.backward",
                            tone: store.canUndoLatestOperation ? palette.ink : palette.ink3)
            }
            .buttonStyle(.plain)
            .disabled(!store.canUndoLatestOperation)
            .opacity(store.canUndoLatestOperation ? 1 : 0.45)

            Text("撤回是整份账本回到改动之前，会同时撤销那一次的所有连带影响。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 20, padding: 14)
    }

    private func actionLabel(_ title: String, symbol: String, tone: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .scaledFont(DS.fsLabel, weight: .semibold)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.cardSoft) }
        .contentShape(Rectangle())
    }

    // MARK: 口径

    private var methodNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("指纹口径")
                .scaledFont(DS.fsLabel, weight: .semibold)
                .foregroundStyle(palette.ink2)
            Text("指纹由起点快照 + 现金 + 场内成交 + 场外基金流水算得。基金那边连分红模式与确认状态都算在内 —— 把「现金分红」改成「红利再投」会改变份额，属于账本事实，不是显示偏好。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Text("起点快照只描述「开始跟踪时的样子」，它不是一笔成交。删除标的时如果账本还干净，改的是起点；一旦有了流水，诚实的做法是记一笔真实卖出。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    private static let dayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - 通用「填个数字 + 写句原因」确认表单

/// 账本改写都需要同一种输入：一个可选金额、一句必填说明。
/// 四个入口共用一张表单，省得每处各写一遍校验和文案。
struct LedgerConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    let title: String
    let prompt: String
    let initialAmount: Double?
    let confirmTitle: String
    let explain: String
    /// 成功后把结论回传给上一页（用来弹提示）。
    /// 必须声明在 `perform` 之前：成员初始化器的参数顺序跟着属性声明走，
    /// 而尾部闭包只会绑定最后一个闭包参数，也就是 `perform`。
    var onResult: (String) -> Void = { _ in }
    /// 返回给用户看的结论。抛错则留在表单里显示原因。
    let perform: (Double, String) throws -> String

    @State private var amountText = ""
    @State private var note = ""
    @State private var errorText: String?
    @FocusState private var focus: Field?

    private enum Field { case amount, note }

    private var isLight: Bool {
        AppTheme.palette(for: AppAppearance.resolved(appearance)).isLight
    }

    private var parsedAmount: Double? {
        let cleaned = amountText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                if initialAmount != nil {
                    Section {
                        HStack {
                            Text("¥").foregroundStyle(.secondary)
                            TextField("0.00", text: $amountText)
                                .keyboardType(.decimalPad)
                                .focused($focus, equals: .amount)
                                .monospacedDigit()
                        }
                    } header: {
                        Text(prompt)
                    }
                }

                Section {
                    TextField(initialAmount == nil ? prompt : "说明（必填）", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focus, equals: .note)
                } header: {
                    Text("原因")
                } footer: {
                    Text(explain)
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(CardTone.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        Text(confirmTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: AppLayout.minimumTapHeight)
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if let initialAmount { amountText = String(format: "%.2f", initialAmount) }
                focus = initialAmount != nil ? .amount : .note
            }
        }
    }

    private func submit() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "请填写原因，审计链需要它。"
            return
        }
        let amount: Double
        if initialAmount != nil {
            guard let parsed = parsedAmount else {
                errorText = "金额必须是有效的非负数。"
                return
            }
            amount = parsed
        } else {
            amount = 0
        }
        do {
            let message = try perform(amount, trimmed)
            Haptics.success()
            onResult(message)
            dismiss()
        } catch {
            Haptics.heavy()
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
