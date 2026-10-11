import Foundation

/// No-key account review. It uses the complete local ledger snapshot and avoids inventing market views.
enum LocalAdvisorEngine {
    static func review(data: PortfolioData, totalAsset: Double) -> String {
        let holdings = data.holdings.filter { $0.quantity > 0 && $0.current > 0 }
        let invested = holdings.reduce(0) { $0 + $1.marketValue }
        let denominator = max(totalAsset, invested + max(0, data.cash))
        guard denominator > 0 else {
            return "账本里还没有可分析的资产或现金。先录入持仓、现金或交易流水，再生成账户建议。"
        }

        let profile = data.investmentProfile
        let cashWeight = data.cash / denominator * 100
        let sorted = holdings.sorted { $0.marketValue > $1.marketValue }
        var lines: [String] = ["账户判断：当前账面资产约 \(denominator.cny())，持仓占 \((invested / denominator * 100).pct(1))，现金占 \(cashWeight.pct(1))。以下是本机账本诊断，不调用大模型。"]
        var actions: [String] = []

        for holding in sorted {
            let weight = holding.marketValue / denominator * 100
            let limit = holding.maxPositionPercent.flatMap { $0 > 0 ? $0 : nil } ?? profile.maxPositionPercent
            if limit > 0 && weight > limit {
                actions.append("优先复核 \(holding.name)(\(holding.code))：约占总资产 \(weight.pct(1))，超过你设定的单标的上限 \(limit.pct(0))。先暂停继续加仓；若你仍认可长期逻辑，可分批把占比降回上限附近，并在下次调仓时复核。")
            }
            if let target = data.allocationTargets.first(where: { $0.code == holding.code && $0.kind == holding.kind }) {
                let drift = weight - target.targetPercent
                if abs(drift) >= Double(max(1, data.rebalanceAlertThreshold)) {
                    let direction = drift > 0 ? "高于" : "低于"
                    actions.append("再平衡复核：\(holding.name)(\(holding.code)) 当前约 \(weight.pct(1))，\(direction)你设定的目标 \(target.targetPercent.pct(1)) 达 \(abs(drift).pct(1))。先确认目标仍适合当前期限，再考虑分批调整。")
                }
            }
        }

        if cashWeight <= 5 {
            let activeDCA = data.fundDCAPlans.filter(\.enabled)
            let dcaText = activeDCA.isEmpty ? "" : "另有 \(activeDCA.count) 项定投在执行，"
            actions.append("现金缓冲约 \(cashWeight.pct(1))，偏低。\(dcaText)新增买入前先核对未来支出和定投扣款；只有在现金计划允许且未突破仓位上限时再分批执行。")
        } else if cashWeight >= 60 {
            actions.append("现金占比约 \(cashWeight.pct(1))，较高。若这不是近期用款安排，可按你设定的长期目标仓位分批投入，不必因单日涨跌一次性进场。")
        }

        let lossNames = sorted.filter { $0.cost > 0 && ($0.current / $0.cost - 1) <= -0.10 }
        if !lossNames.isEmpty {
            let names = lossNames.prefix(2).map { "\($0.name)(\($0.code))" }.joined(separator: "、")
            actions.append("有标的较成本回撤达到约 10%：\(names)。这只是复核信号，不等于卖出指令；检查原买入逻辑是否仍成立、仓位是否超限，再按自己的退出条件处理，避免只因成本价而摊平。")
        }

        if actions.isEmpty {
            if let top = sorted.first {
                let topWeight = top.marketValue / denominator * 100
                actions.append("目前没有触发明显的现金或单仓上限问题。最值得持续盯的是 \(top.name)(\(top.code))，占总资产约 \(topWeight.pct(1))；新增投入前先看它与其他持仓是否重复暴露，并遵守 \(profile.horizon) 的持有周期。")
            } else {
                actions.append("当前以现金为主；根据你的 \(profile.horizon) 期限和 \(profile.risk == "con" ? "保守" : profile.risk == "agg" ? "积极" : "平衡") 风险偏好分批规划，留足近期用款，不追随单日行情做决定。")
            }
        }

        let overlapPairs = overlappingFunds(data: data)
        if !overlapPairs.isEmpty {
            actions.append("基金穿透检查发现可能重复：\(overlapPairs.prefix(2).joined(separator: "；"))。成分报告有日期和覆盖范围限制，先核对报告日期及完整持仓，再决定是否合并。")
        } else if data.holdings.filter({ $0.kind == .fund && $0.quantity > 0 }).count > 1 {
            lines.append("场外基金有多只，但本机没有足够的同日成分数据，暂不能确认是否重复押注同一赛道。")
        }

        lines.append("优先动作：")
        lines.append(contentsOf: actions.prefix(3).enumerated().map { "\($0.offset + 1). \($0.element)" })
        let hasTrades = data.ledger.contains { $0.side == .buy || $0.side == .sell }
            || data.fundTransactions.contains { $0.side == .buy || $0.side == .sell }
        if !hasTrades {
            lines.append("画像依据：目前没有可用买卖流水，因此不推断胜率、交易纪律或真实操作风格；画像只描述当前资产结构。")
        } else {
            let portrait = PortraitEngine.compute(data: data, totalAsset: denominator)
            let tags = portrait.tags.map(\.text).prefix(3).joined(separator: "、")
            lines.append("画像依据：本机根据已记录的交易、持仓和现金推断为\(tags.isEmpty ? "样本有限，暂不贴标签" : tags)。这是历史行为摘要，不是收益预测；流水不完整时结论会偏差。")
        }
        lines.append("失效与复核：价格/净值变化、资金用途改变、成分报告更新或补录流水后重新分析；这份规则建议不读取新闻和实时基本面。")
        lines.append("数据口径：持仓按账本现价/净值计算；本机不保证报价或场外基金净值刚刚更新，执行前需核对最新数据。")
        return lines.joined(separator: "\n\n")
    }

    private static func overlappingFunds(data: PortfolioData) -> [String] {
        let funds = data.holdings.filter { $0.kind == .fund && $0.quantity > 0 }
        guard funds.count > 1 else { return [] }
        let snapshots = Dictionary(data.fundConstituentSnapshots.map { ($0.code, $0) }, uniquingKeysWith: { a, b in
            a.asOf >= b.asOf ? a : b
        })
        var pairs: [String] = []
        for i in 0..<(funds.count - 1) {
            for j in (i + 1)..<funds.count {
                guard let a = snapshots[funds[i].code], let b = snapshots[funds[j].code] else { continue }
                let aw = Dictionary(a.holdings.map { ($0.code, $0.weightPercent) }, uniquingKeysWith: { max($0, $1) })
                let bw = Dictionary(b.holdings.map { ($0.code, $0.weightPercent) }, uniquingKeysWith: { max($0, $1) })
                let overlap = aw.reduce(0.0) { $0 + min($1.value, bw[$1.key] ?? 0) }
                if overlap >= 35 {
                    pairs.append("\(funds[i].name)与\(funds[j].name)前十大重叠约\(overlap.num(1))%（报告 \(a.asOf) / \(b.asOf)）")
                }
            }
        }
        return pairs
    }
}
