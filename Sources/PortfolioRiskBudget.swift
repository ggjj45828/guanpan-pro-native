import Foundation

// MARK: - 组合风险预算（组合级，独立于单笔 RiskGuard）
//
// 治理对应：策略仲裁第 2 优先级「组合风险 Risk Guard」。
//
// 与既有模块的边界：
//   · `RiskGuard`（RiskDiscipline.swift）判「这一笔该不该下」。
//   · `PositionDisciplinePolicy` 判「单标的仓位上限」。
//   · 本引擎判「整个组合的结构」：总仓、单标的集中度、同类主题集中度、现金下限、
//     持仓数量，并给出「这只标的还能加多少钱」——耐心限价要用它定数量。
//
// 不做的事：不打分、不排名、不预测收益。只做约束检查与否决（veto）。

/// 风险预算政策。默认值取保守口径，可在设置里覆盖。
struct RiskBudgetPolicy: Equatable, Sendable {
    /// 单标的市值占比上限。
    var maxSingleWeight: Double = 0.25
    /// 同类主题合计占比上限。
    var maxThemeWeight: Double = 0.40
    /// 现金占总资产下限（现金也是仓位）。
    var minCashWeight: Double = 0.05
    /// 持仓只数上限（避免过度分散到管不过来）。
    var maxHoldingCount: Int = 12

    static let standard = RiskBudgetPolicy()
}

/// 组合里的一个持仓（只带风险预算需要的字段，与 Holding 解耦，便于离线测试）。
struct RiskBudgetPosition: Identifiable, Equatable, Sendable {
    var id: String { code }
    let code: String
    let name: String
    /// 当前市值。
    let value: Double

    init(code: String, name: String, value: Double) {
        self.code = code
        self.name = name
        self.value = value
    }
}

/// 一条约束发现。
struct RiskBudgetFinding: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case singleConcentration
        case themeConcentration
        case cashFloor
        case holdingCount
    }

    /// note = 提示；warn = 需注意；veto = 可否决新增买入。
    enum Severity: String, Comparable, Sendable {
        case note, warn, veto
        var rank: Int {
            switch self {
            case .note: return 0
            case .warn: return 1
            case .veto: return 2
            }
        }
        var title: String {
            switch self {
            case .note: return "提示"
            case .warn: return "注意"
            case .veto: return "否决"
            }
        }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    let id: String
    let kind: Kind
    let severity: Severity
    let title: String
    let detail: String
}

/// 评估结果。
struct RiskBudgetAssessment: Equatable, Sendable {
    let totalAssets: Double
    let investedValue: Double
    let cash: Double
    let cashWeight: Double
    /// 最大单一标的占比（用于界面一眼看集中度）。
    let topWeight: Double
    let topCode: String?
    let findings: [RiskBudgetFinding]
    /// 每只标的还能加仓的金额（已扣除现金下限与单标的上限），负数归零。
    let headroomByCode: [String: Double]
    /// 组合层面的可新增买入总额度。
    let headroomTotal: Double

    var hasVeto: Bool { findings.contains { $0.severity == .veto } }
    var worstSeverity: RiskBudgetFinding.Severity? {
        findings.map(\.severity).max()
    }
    var summary: String {
        if let veto = findings.first(where: { $0.severity == .veto }) {
            return "风险预算否决：\(veto.title)"
        }
        if let warn = findings.first(where: { $0.severity == .warn }) {
            return "风险预算提醒：\(warn.title)"
        }
        return "组合结构在政策范围内"
    }
}

// MARK: - 引擎

enum RiskBudgetEngine {
    /// 主题粗分：只按交易所代码段归类，非官方分类，够用且可解释。
    ///
    /// 顺序有意义：`1599`（跨境）必须先于 `159`（深市权益）判，否则会被后者吞掉。
    static func theme(for code: String) -> String {
        if code.hasPrefix("511") { return "债券/货币" }
        if code.hasPrefix("518") { return "黄金/商品" }
        if code.hasPrefix("513") || code.hasPrefix("1599") { return "跨境" }
        if code.hasPrefix("51") { return "沪市权益" }
        if code.hasPrefix("159") { return "深市权益" }
        if code.hasPrefix("588") || code.hasPrefix("589") { return "科创板" }
        return "其他"
    }

    static func evaluate(positions: [RiskBudgetPosition],
                         cash: Double,
                         policy: RiskBudgetPolicy = .standard) -> RiskBudgetAssessment {
        let safeCash = (cash.isFinite && cash > 0) ? cash : 0
        let validPositions = positions.filter { $0.value.isFinite && $0.value > 0 }
        let invested = validPositions.reduce(0) { $0 + $1.value }
        let total = invested + safeCash
        let cashWeight = total > 0 ? safeCash / total : 1

        var findings: [RiskBudgetFinding] = []

        // ① 单标的集中度
        var topWeight: Double = 0
        var topCode: String? = nil
        if total > 0 {
            for position in validPositions {
                let weight = position.value / total
                if weight > topWeight {
                    topWeight = weight
                    topCode = position.code
                }
                if weight > policy.maxSingleWeight {
                    findings.append(RiskBudgetFinding(
                        id: "single-\(position.code)",
                        kind: .singleConcentration,
                        severity: .veto,
                        title: "单标的超上限",
                        detail: "\(position.name) 占 \(percent(weight))，超过单标的上限 \(percent(policy.maxSingleWeight))"
                    ))
                }
            }
        }

        // ② 主题集中度
        if total > 0 {
            var themeValue: [String: Double] = [:]
            for position in validPositions {
                themeValue[theme(for: position.code), default: 0] += position.value
            }
            for (theme, value) in themeValue.sorted(by: { $0.value > $1.value }) {
                let weight = value / total
                if weight > policy.maxThemeWeight {
                    findings.append(RiskBudgetFinding(
                        id: "theme-\(theme)",
                        kind: .themeConcentration,
                        severity: .warn,
                        title: "同类集中度偏高",
                        detail: "\(theme) 合计 \(percent(weight))，超过 \(percent(policy.maxThemeWeight))"
                    ))
                }
            }
        }

        // ③ 现金下限（现金也是仓位）
        if total > 0, cashWeight < policy.minCashWeight {
            findings.append(RiskBudgetFinding(
                id: "cash-floor",
                kind: .cashFloor,
                severity: .warn,
                title: "现金低于下限",
                detail: "现金占 \(percent(cashWeight))，低于下限 \(percent(policy.minCashWeight))；满仓时被动卖出风险高"
            ))
        }

        // ④ 持仓只数
        if validPositions.count > policy.maxHoldingCount {
            findings.append(RiskBudgetFinding(
                id: "count-cap",
                kind: .holdingCount,
                severity: .note,
                title: "持仓只数偏多",
                detail: "\(validPositions.count) 只，超过 \(policy.maxHoldingCount) 只，跟踪成本上升"
            ))
        }

        // ⑤ 可加仓额度：受「现金下限」与「单标的上限」双重约束。
        let cashFloor = total * policy.minCashWeight
        let spendable = max(0, safeCash - cashFloor)
        let perSymbolCap = total * policy.maxSingleWeight

        var headroomByCode: [String: Double] = [:]
        for position in validPositions {
            headroomByCode[position.code] = max(0, perSymbolCap - position.value)
        }

        return RiskBudgetAssessment(totalAssets: total,
                                    investedValue: invested,
                                    cash: safeCash,
                                    cashWeight: cashWeight,
                                    topWeight: topWeight,
                                    topCode: topCode,
                                    findings: findings,
                                    headroomByCode: headroomByCode,
                                    headroomTotal: spendable)
    }

    /// 某只标的本次最多可投入金额 = min(组合可动用现金, 该标的剩余额度)。
    static func maxDeployable(code: String, assessment: RiskBudgetAssessment) -> Double {
        let perSymbol = assessment.headroomByCode[code] ?? assessment.totalAssets * 0.25
        return max(0, min(assessment.headroomTotal, perSymbol))
    }

    private static func percent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }
}
