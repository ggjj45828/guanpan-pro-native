import SwiftUI

// MARK: - 候选 / 风控 / 触发 只读验证页
//
// 这里只把规则跑给用户看：不写账本、不发单、不连模型。
// 所有结论都带「证据等级」与降级项，避免把降级数据包装成确定结论。

struct DisciplineLabView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearance) private var appearance

    @State private var code = ""
    @State private var direction: CandidateDirection = .buy
    @State private var lowerText = ""
    @State private var upperText = ""
    @State private var targetText = ""
    @State private var quantityText = ""
    @State private var minutesText = "60"
    @State private var stopText = ""
    @State private var assessment: RiskAssessment?
    @State private var trigger: TriggerAssessment?
    @State private var shadow: ShadowEvaluation?
    @State private var errorText: String?

    private var s: ThemeSemantics { .of(appearance) }
    private var palette: DsPalette { .of(appearance) }

    private var candidates: [String] {
        var seen = Set<String>()
        var list: [String] = []
        for q in store.data.quotes where seen.insert(q.code).inserted { list.append(q.code) }
        for h in store.data.holdings where seen.insert(h.code).inserted { list.append(h.code) }
        return list
    }

    private var normalizedCode: String {
        let raw = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sh", "sz", "bj"] where raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("候选计划（只描述意图）") {
                    Picker("标的", selection: $code) {
                        ForEach(candidates, id: \.self) { item in
                            Text(name(item)).tag(item)
                        }
                    }
                    Picker("方向", selection: $direction) {
                        Text("买入").tag(CandidateDirection.buy)
                        Text("卖出").tag(CandidateDirection.sell)
                    }
                    .pickerStyle(.segmented)
                    field("区间下沿", $lowerText)
                    field("区间上沿", $upperText)
                    field("目标价", $targetText)
                    field("数量（份）", $quantityText)
                    field("有效期（分钟）", $minutesText)
                    field("失效价（可选）", $stopText)
                }
                .foregroundStyle(s.ink)

                Section {
                    Button {
                        run()
                    } label: {
                        Text("跑一次规则评估")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: AppLayout.minimumTapHeight)
                            .foregroundStyle(s.onAccent)
                    }
                    .listRowBackground(s.accent)
                    Text("不写入账本、不发出任何订单；结果只表示「是否进入人工复核」。")
                        .font(.footnote)
                        .foregroundStyle(s.ink2)
                }

                if let errorText {
                    Section("输入问题") {
                        Text(errorText).foregroundStyle(s.danger)
                    }
                }
                if let assessment {
                    riskSection(assessment)
                }
                if let trigger {
                    triggerSection(trigger)
                }
                if let shadow {
                    shadowSection(shadow)
                }
            }
            .scrollContentBackground(.hidden)
            .themedSheetBackground()
            .navigationTitle("规则验证台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
            .keyboardDoneToolbar()
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                if code.isEmpty { code = candidates.first ?? "" }
                prefill()
            }
            .onChange(of: code) { _, _ in prefill() }
        }
        .presentationDetents([.large])
    }

    // MARK: 输入

    private func field(_ title: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(s.ink2)
            Spacer(minLength: 8)
            TextField("0", text: value)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(s.ink)
                .frame(maxWidth: 130)
        }
    }

    private func prefill() {
        let quote = store.data.quotes.first { $0.code == code }
        let price = quote?.price ?? store.data.holdings.first { $0.code == code }?.current ?? 0
        guard price > 0 else { return }
        lowerText = (price * 0.985).num(3)
        upperText = (price * 0.995).num(3)
        targetText = (price * 0.99).num(3)
        quantityText = "100"
        stopText = ""
    }

    // MARK: 计算

    private func run() {
        errorText = nil
        guard let lower = Double(lowerText), let upper = Double(upperText),
              let target = Double(targetText), let quantity = Double(quantityText),
              let minutes = Double(minutesText) else {
            errorText = "价格、数量和有效期都要填有效数字。"
            assessment = nil; trigger = nil; shadow = nil
            return
        }
        let stop = Double(stopText)
        let now = Date()
        do {
            let plan = try TradeCandidate(
                code: normalizedCode, direction: direction,
                lowerPrice: lower, upperPrice: upper, targetPrice: target,
                quantity: quantity, validFrom: now,
                validUntil: now.addingTimeInterval(max(60, minutes * 60)),
                invalidationPrice: stop, note: "规则验证台（未保存）", createdAt: now)
            let quote = store.data.quotes.first { $0.code == plan.code }
                ?? store.data.quotes.first { $0.code == code }
            // 会话状态由 TradingSession 计算，不是 MarketSessionStatus 的静态成员；
            // custom 必须带上用户自定义休市日，否则「今天休假」仍会被当成交易日。
            let session = TradingSession.status(at: now, custom: store.data.customMarketHolidays)
            let regime = store.marketRegime(benchmarkCode: "sh000001")
            let snap = disciplineSnapshot(for: plan.code, price: target)
            assessment = RiskGuard.evaluate(candidate: plan, quote: quote,
                                            session: session, regime: regime,
                                            snapshot: snap, score: 70, now: now)
            trigger = RealtimeTrigger.evaluate(plan: plan, quote: quote,
                                               session: session, regime: regime, now: now)
            let observations = store.intradayBars
                .filter { $0.code == plan.code || $0.code == code }
                .map { ShadowObservation(timestamp: $0.timestamp, price: $0.price) }
            shadow = CandidateShadow.evaluate(plan: plan, triggerAt: now,
                                              triggerPrice: quote?.price ?? target,
                                              observations: observations, now: now)
        } catch {
            errorText = error.localizedDescription
            assessment = nil; trigger = nil; shadow = nil
        }
    }

    private func disciplineSnapshot(for rawCode: String, price: Double) -> DisciplineSnapshot {
        let cash = store.data.cash
        let securities = store.data.holdings.filter { $0.kind == .etf }
        let totalSecurityValue = securities.reduce(0) { $0 + $1.marketValue }
        let totalAssets = totalSecurityValue + cash
        let held = securities.first { $0.code == rawCode || $0.code == code }
        return DisciplineSnapshot(
            cash: cash,
            totalAssets: totalAssets,
            totalSecurityValue: totalSecurityValue,
            currentSecurityValue: held?.marketValue ?? 0,
            currentUnits: held?.quantity ?? 0,
            protectedCoreUnits: 0,
            unmatchedTSoldUnits: 0,
            dailyBuyAmount: 0,
            consecutiveBuyCount: nil,
            secondsSinceLastFill: nil)
    }

    // MARK: 结果

    private func riskSection(_ a: RiskAssessment) -> some View {
        Section("风控与仓位纪律") {
            HStack {
                Text(a.allowedForReview ? "可进入人工复核" : "已否决")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(a.allowedForReview ? s.ok : s.danger)
                Spacer()
                Text("置信度 \(a.confidence)%").font(.caption).foregroundStyle(s.ink2)
            }
            Text("买入后暴露 \(a.discipline.projectedExposure.pct(1)) · 所需评分 ≥ \(a.discipline.requiredScore)")
                .font(.caption).foregroundStyle(s.ink2)
            ForEach(a.findings) { finding in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: finding.blocking ? "xmark.circle.fill" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(finding.blocking ? s.danger : s.warn)
                    Text(finding.message)
                        .font(.caption)
                        .foregroundStyle(finding.blocking ? s.ink : s.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func triggerSection(_ t: TriggerAssessment) -> some View {
        Section("实时触发") {
            HStack {
                Text(t.state.title).font(.subheadline.weight(.semibold)).foregroundStyle(s.ink)
                Spacer()
                Text("信号 \(t.signalScore) · 置信 \(t.confidence)%").font(.caption).foregroundStyle(s.ink2)
            }
            ForEach(t.reasons, id: \.self) { reason in
                Text(reason).font(.caption).foregroundStyle(s.ink2)
            }
        }
    }

    private func shadowSection(_ e: ShadowEvaluation) -> some View {
        Section("影子成绩单（只读）") {
            HStack {
                Text(e.coverageComplete ? "覆盖完整" : "覆盖不完整，不给收益结论")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(e.coverageComplete ? s.ok : s.warn)
                Spacer()
                Text("最大缺口 \(Int(e.maxGapSeconds))s").font(.caption).foregroundStyle(s.ink2)
            }
            ForEach(e.horizons) { horizon in
                HStack {
                    Text("\(horizon.seconds / 60) 分钟").font(.caption).foregroundStyle(s.ink2)
                    Spacer()
                    Text(horizon.relativeChange.map { $0.pct(2) } ?? "无观测")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(horizon.relativeChange == nil ? s.ink3 : s.ink)
                }
            }
            if !e.reasonCodes.isEmpty {
                Text("原因码：" + e.reasonCodes.joined(separator: "、"))
                    .font(.caption2).foregroundStyle(s.ink3)
            }
        }
    }

    private func name(_ raw: String) -> String {
        store.data.quotes.first { $0.code == raw }?.name
            ?? store.data.holdings.first { $0.code == raw }?.name
            ?? raw
    }
}
