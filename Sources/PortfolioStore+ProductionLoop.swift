import Foundation

// MARK: - 生产闭环接线：行为门槛 / 盯盘评估 / 成交关联
//
// 这一层只负责把纯计算模块接到 PortfolioStore 的真实数据上：
//   · 行情刷新成功后评估盯盘计划（状态与事件持久化，但用高频缓存落盘，
//     不占用「撤销上一次账本修改」的位置）。
//   · 成交导入 / 手工录账后重算候选关联，只生成复核建议，不写 Ledger。
//   · 全程不下单、不自动把计划改成已成交、不发网络请求。

extension PortfolioStore {
    /// 当前真实账本推导出的 Anti-Overtrading 评估，供风控链消费。
    func tradingBehaviorAssessment(now: Date = Date()) -> OvertradingAssessment {
        AntiOvertrading.assess(fills: data.ledger, now: now)
    }

    func todayTComparison(now: Date = Date()) -> TodayTComparison {
        TodayReviewBuilder.build(data: data, now: now)
    }

    // MARK: 盯盘计划

    func saveTriggerPlan(_ candidate: TradeCandidate, note: String = "") {
        var updated = data
        updated.triggerPlans.insert(TriggerPlan(candidate: candidate, note: note), at: 0)
        data = updated
        save(label: "保存盯盘计划")
    }

    func setTriggerPlanActive(_ id: UUID, active: Bool) {
        guard let idx = data.triggerPlans.firstIndex(where: { $0.id == id }) else { return }
        var updated = data
        updated.triggerPlans[idx].isActive = active
        updated.triggerPlans[idx].lastReasons = [active ? "manually_resumed" : "manually_paused"]
        data = updated
        save(label: "调整盯盘计划")
    }

    func removeTriggerPlan(_ id: UUID) {
        var updated = data
        updated.triggerPlans.removeAll { $0.id == id }
        updated.candidateLinks.removeAll { $0.planID == id }
        data = updated
        save(label: "删除盯盘计划")
    }

    /// 由 `performQuoteRefresh` 在 `data.quotes` 更新之后调用。
    /// 非连续竞价 / 无报价 / 重复时间戳都会被引擎跳过，不产生状态推进。
    func evaluateTriggerPlansOnRefresh(now: Date = Date()) {
        guard data.triggerPlans.contains(where: { $0.isActive }) else { return }
        let session = TradingSession.status(at: now, custom: data.customMarketHolidays)
        let regime = marketRegime(benchmarkCode: "sh000001")
        let outcome = TriggerMonitorEngine.evaluate(plans: data.triggerPlans,
                                                    quotes: data.quotes,
                                                    session: session,
                                                    regime: regime,
                                                    now: now)
        let stateChanged = outcome.plans != data.triggerPlans
        guard stateChanged || !outcome.events.isEmpty else { return }
        var updated = data
        updated.triggerPlans = outcome.plans
        if !outcome.events.isEmpty {
            updated.triggerEvents = Array((outcome.events + data.triggerEvents).prefix(200))
        }
        data = updated
        // 盯盘状态属于行情级缓存：不覆盖账本撤销点、不触发整账本 NAS 上传。
        flushAutomaticMarketState()
    }

    // MARK: 成交 ↔ 候选

    /// 成交流水变化后重算关联建议。已确认 / 已排除的记录保持不变。
    func relinkTradeCandidates(now: Date = Date()) {
        let fresh = CandidateFillMatcher.match(plans: data.triggerPlans,
                                               fills: data.ledger,
                                               existing: data.candidateLinks,
                                               now: now)
        guard !fresh.isEmpty else { return }
        var updated = data
        updated.candidateLinks = Array((fresh + data.candidateLinks).prefix(300))
        data = updated
    }

    /// 人工确认 / 排除一条关联。确认只标记计划与成交的对应关系，
    /// 不把计划写成已成交、不写 Ledger、不改现金和持仓。
    func decideCandidateLink(_ id: UUID, accept: Bool) {
        guard let idx = data.candidateLinks.firstIndex(where: { $0.id == id }) else { return }
        var updated = data
        let link = updated.candidateLinks[idx]
        updated.candidateLinks[idx].status = accept ? .confirmed : .rejected
        if accept, let planIdx = updated.triggerPlans.firstIndex(where: { $0.id == link.planID }) {
            updated.triggerPlans[planIdx].linkedFillID = link.fillID
            updated.triggerPlans[planIdx].linkConfirmedByUser = true
            updated.triggerPlans[planIdx].isActive = false
            updated.triggerPlans[planIdx].lastReasons = ["user_confirmed_fill_association"]
        }
        data = updated
        save(label: "确认候选与成交关联")
    }
}
