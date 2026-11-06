import Foundation

// MARK: - 账户级杂费
//
// 交易费用（`ledger.fee` / 基金赎回费）只覆盖「买卖时券商收的那一点点」。
// 真实账户还有一类成本从来不进任何统计：平台使用费、融资利息、托管费、
// 数据订阅费。它们不出现在成交流水里，但确实从账户里拿走了钱 ——
// 于是「赚了多少」这个数永远偏高，而且没人知道偏高多少。
//
// 这里单独记一份，并且：
// · 记了 `linkedCash` 就从参考现金里扣，同时补一条 `external = false` 的现金流，
//   这样「净外部投入」不会被这笔支出污染（它不是用户转出，而是成本）；
// · 记进账本审计链 —— 它改了现金，就该在链上留下一笔；
// · 不参与状态指纹重算的历史可比性（老账本没有这个字段），所以不做口径升级。

struct AccountExpense: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date = .now
    /// 正数表示从账户里支出。退款请用「其他」并写清说明，金额仍记正数。
    var amount: Double
    var category: Category
    var memo: String
    /// 是否同步扣减参考现金。关掉表示这笔费用在账外支付，只做统计。
    var linkedCash: Bool = true
    /// 关联的现金流记录 id，删除时按它精确回补，不去猜「哪条 memo 像这笔费用」。
    var cashFlowID: UUID? = nil

    enum Category: String, Codable, CaseIterable, Identifiable {
        case platform, margin, custody, data, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .platform: return "平台/软件费"
            case .margin: return "融资利息"
            case .custody: return "托管/账户管理费"
            case .data: return "行情数据费"
            case .other: return "其他"
            }
        }

        var symbol: String {
            switch self {
            case .platform: return "desktopcomputer"
            case .margin: return "percent"
            case .custody: return "building.columns"
            case .data: return "chart.bar.doc.horizontal"
            case .other: return "ellipsis.circle"
            }
        }
    }
}

/// 单个类别的合计。
///
/// 用结构体而不是 `(category:amount:)` 元组：`ForEach` 的 `id` 要写成 key path，
/// 而 Swift 的 key path 不能指向元组元素（这个坑在决策成绩单上已经踩过一次）。
struct AccountExpenseCategoryTotal: Identifiable {
    var id: AccountExpense.Category { category }
    let category: AccountExpense.Category
    let amount: Double
}

/// 按月分组，给列表用。
struct AccountExpenseMonthGroup: Identifiable {
    var id: String { month }
    let month: String
    let items: [AccountExpense]
}

/// 一段区间内的费用汇总。全部由本机账本计算，不做年化以外任何推断。
struct AccountExpenseSummary {
    var total: Double = 0
    var count: Int = 0
    var byCategory: [AccountExpenseCategoryTotal] = []
    /// 年化费率（费用 ÷ 平均总资产）。快照不足时用当前总资产，并在文案里说明。
    var annualizedRate: Double? = nil
    /// 平均总资产的来源：快照或当前值。
    var averageAssetBasis: Double = 0
    var usedCurrentAssetFallback = false

    var isEmpty: Bool { count == 0 }
}
