import Foundation

// MARK: - 账本起点

/// 账本的真实起点：用户「录入现有持仓」时账本里发生的第一件事。
///
/// 它不是一笔成交 —— 没有对手方、没有成交价、没有手续费。把它当成成交去反推，
/// 会得到一条永远算不平的流水。所以单独存一份快照，删除标的时才有可能诚实地
/// 「改写起点」，而不是伪造一笔卖出。
struct LedgerOpeningSnapshot: Codable, Equatable {
    enum Source: String, Codable {
        /// 录入持仓时当场记下。
        case recorded
        /// 老备份没有起点，第一次保存时按当时状态采纳。
        case adopted
        /// 账本里已经先有了流水，事后补记的起点。
        /// 与 `adopted` 一样是「当时状态」，区别在于它明确不是跟踪的始点。
        case lateAdopt
    }

    var capturedAt: Date = .now
    var source: Source = .recorded
    var cash: Double = 0
    var positions: [LedgerOpeningPosition] = []
    /// 录入那一刻处在哪个交易时段（盘中 / 午休 / 收盘后 / 休市）。
    ///
    /// 这件事直接决定「今天算不算本轮」：14:30 盘中录入，当天剩下的涨跌确实属于
    /// 这批持仓；收盘后 20:00 录入，当天的涨跌已经发生完了，不该再记到「起点之后」。
    /// 之前只有一个精确到毫秒的 `capturedAt`，两种情形在数据层毫无区别。
    var session: MarketSessionStatus?
    /// 起点归属的交易日（"yyyy-MM-dd"，上海时区）。老快照没有，用 `capturedAt` 推。
    var tradingDayKey: String?

    var positionCount: Int { positions.count }
    var marketCostValue: Double { positions.reduce(0) { $0 + $1.quantity * $1.cost } }

    /// 起点归属交易日。为 nil 时由调用方自己按 `capturedAt` 推。
    var resolvedTradingDay: String? {
        if let tradingDayKey, !tradingDayKey.isEmpty { return tradingDayKey }
        return MarketCalendar.isoDay(capturedAt)
    }

    // MARK: 起点口径
    var etfPositions: [LedgerOpeningPosition] { positions.filter { $0.kind == .etf } }

    var etfCostValue: Double { etfPositions.reduce(0) { $0 + $1.costValue } }

}

struct LedgerOpeningPosition: Codable, Equatable, Identifiable {
    var id: String { "\(kind.rawValue)-\(code)" }
    var code: String
    var name: String
    var kind: Holding.Kind
    var quantity: Double
    var cost: Double

    var costValue: Double { quantity * cost }
}

// MARK: - 用户确认

/// 一次账本改写的用户授权。没有它不允许动账本 —— 事后追查时这里是唯一凭据。
struct LedgerConfirmation: Codable, Equatable {
    var reason: String
    var note: String
    var confirmedAt: Date = .now

    var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedReason.isEmpty && !trimmedNote.isEmpty }
}

// MARK: - 审计链

/// 只追加、不改写的账本操作记录。
/// 前后两份状态指纹串成链：任何一次静默改账都会让链断开，肉眼即可发现。
struct LedgerAuditEvent: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var occurredAt: Date = .now
    /// 做了什么，例如「记一笔清仓卖出」。
    var action: String
    /// 为什么，含用户填写的说明。
    var reason: String
    var priorDigest: String
    var resultingDigest: String
    /// 算指纹时的口径版本。口径升级后前后两条的指纹算法不同，
    /// 链上会出现一处「对不上但合法」的接缝，用它标记出来，不要误报断链。
    var caliber: Int? = nil

    var digestPair: String { "\(priorDigest.prefix(8)) → \(resultingDigest.prefix(8))" }
}

// MARK: - 链检查结果

/// 审计链体检结论。断链和口径升级要分开 —— 前者是事故，后者是升级痕迹。
struct LedgerAuditHealth: Equatable {
    /// 真正的断点（0 起算）。非空说明有代码绕过了审计入口改了账本。
    var breaks: [Int] = []
    /// 口径迁移接缝（0 起算）。合法，只是提醒这里前后算法不同。
    var migrations: [Int] = []

    var isClean: Bool { breaks.isEmpty }
}

// MARK: - 状态指纹

/// 账本状态指纹。
///
/// 用 FNV-1a 64 位而不是 SHA：这里要的是「内容变了指纹就变」的确定性指纹，
/// 用于审计链自洽检查，不承担密码学职责。好处是不引入任何框架依赖，
/// 也不会因为浮点格式化差异而在不同 iOS 版本上算出不同结果。
enum LedgerDigest {
    /// 口径版本。
    static let caliber = 2

    static func make(opening: LedgerOpeningSnapshot?,
                     cash: Double,
                     fills: [LedgerEntry]) -> String {
        var text = "v1|"
        if let opening {
            text += "open:\(opening.capturedAt.timeIntervalSince1970):\(opening.source.rawValue)"
            text += ":\(money(opening.cash))"
            for position in opening.positions.sorted(by: { $0.id < $1.id }) {
                text += "|p:\(position.code):\(position.kind.rawValue):\(units(position.quantity)):\(money(position.cost))"
            }
        } else {
            text += "open:none"
        }
        text += "|cash:\(money(cash))"
        for fill in fills.sorted(by: { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.date < rhs.date
        }) {
            text += "|f:\(fill.id.uuidString):\(fill.code):\(fill.kind?.rawValue ?? "etf")"
            text += ":\(fill.side.rawValue):\(units(fill.quantity)):\(money(fill.price)):\(money(fill.fee))"
        }
        return fnv1a64(text)
    }

    /// 金额一律按 6 位小数定点化，避免 1e-13 级别的浮点尾数抖动让指纹无故变化。
    private static func money(_ value: Double) -> String {
        guard value.isFinite else { return "nan" }
        return String(format: "%.6f", value)
    }

    private static func units(_ value: Double) -> String {
        guard value.isFinite else { return "nan" }
        return String(format: "%.6f", value)
    }

    private static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - 删除方式

/// 删除一只持仓的三种真实含义。UI 必须让用户选，不能替他猜。
enum HoldingRemovalMode: String, CaseIterable, Identifiable {
    /// 记一笔清仓卖出：账本里多了成交，现金增加，历史可追溯。
    case recordSale
    /// 重写起点快照：只有在账本一笔成交都没有时才成立。
    case rewriteOpening
    /// 只删持仓行，保留流水：账本会出现无持仓的孤儿流水，仅用于处理脏数据。
    case removeOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordSale: return "记一笔清仓卖出"
        case .rewriteOpening: return "改写账本起点"
        case .removeOnly: return "只删持仓，保留流水"
        }
    }

    var subtitle: String {
        switch self {
        case .recordSale:
            return "按最新价记一笔卖出成交，现金同步回款，盈亏进入已实现收益。"
        case .rewriteOpening:
            return "账本里还没有任何成交时，删除标的等于修改起点快照，不产生假成交。"
        case .removeOnly:
            return "保留历史流水但不再持有该标的，之后对账会提示流水找不到持仓。"
        }
    }

    var icon: String {
        switch self {
        case .recordSale: return "arrow.left.arrow.right"
        case .rewriteOpening: return "clock.arrow.circlepath"
        case .removeOnly: return "scissors"
        }
    }

    var isDestructive: Bool { self != .recordSale }
}

// MARK: - 错误

enum LedgerError: LocalizedError, Equatable {
    case openingSnapshotLocked
    case openingSnapshotAlreadyExists
    case invalidConfirmation
    case invalidAmount
    case missingHolding
    case noQuotedPrice(String)
    case nothingToLiquidate
    case emptyAccount

    var errorDescription: String? {
        switch self {
        case .openingSnapshotLocked:
            return "账本里已经有成交记录了，起点不再是唯一事实来源，不能再直接改写。请改用「记一笔清仓卖出」。"
        case .openingSnapshotAlreadyExists:
            return "账本里已经有起点了。补记只用于「起点为空、但已经有历史流水」的账户，且只能做一次。"
        case .invalidConfirmation:
            return "请填写改动原因和确认说明。"
        case .invalidAmount:
            return "金额必须是不小于 0 的有效数字。"
        case .missingHolding:
            return "找不到这只持仓，可能已在其他设备上删除。"
        case .noQuotedPrice(let name):
            return "「\(name)」没有可用行情，无法按市价记卖出。请先刷新行情，或改用手工交易录入。"
        case .nothingToLiquidate:
            return "没有可清仓的持仓。"
        case .emptyAccount:
            return "账户里还没有任何持仓或现金，补记出来的起点是空的，没有意义。"
        }
    }
}
