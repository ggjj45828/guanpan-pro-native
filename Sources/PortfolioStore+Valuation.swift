import Foundation

/// 估值口径挂在 store 上，界面只认这里，不再自己拼 `holdings.reduce`。
extension PortfolioStore {

    /// 当前时段。所有需要「现在是不是交易时间」的地方都应该读它，
    /// 而不是各自 `Calendar` 一遍 —— 各自实现必然出现两处不一致。
    var sessionStatus: MarketSessionStatus {
        TradingSession.status(at: .now, custom: data.customMarketHolidays)
    }

    /// 严格估值。失败时**不要**退回去把缓存价加起来当成总资产，
    /// 那样等于把「不知道」显示成「知道」。
    func valuation(at now: Date = .now) -> Result<PortfolioValuation, PortfolioValuationFailure> {
        PortfolioValuationEngine.evaluate(data: data, session: sessionStatus, now: now)
    }

    /// 严格估值成功时的总资产。失败为 nil。
    var verifiedTotalAsset: Double? {
        if case .success(let value) = valuation() { return value.total }
        return nil
    }

    /// 界面上的总资产：优先严格值，否则回落到缓存值。
    ///
    /// 回落值**必须**配合 `valuationCaption` 一起显示，单独用这个数字是错的。
    var displayedTotalAsset: Double {
        verifiedTotalAsset ?? totalAsset
    }

    /// 一次算完、一次交给视图。
    ///
    /// 首页总资产卡要同时知道「数字」「可不可信」「那行小字」。分成三个属性各调一次，
    /// 就是每次 body 重绘跑三遍全量估值 —— 持仓几十只时这已经在丢帧了。
    struct ValuationDisplay {
        let total: Double
        let verified: Bool
        let caption: String
    }

    var valuationDisplay: ValuationDisplay {
        switch valuation() {
        case .success(let value):
            return ValuationDisplay(total: value.total, verified: true, caption: caption(for: value))
        case .failure(let failure):
            return ValuationDisplay(total: totalAsset, verified: false, caption: caption(for: failure))
        }
    }

    private func caption(for value: PortfolioValuation) -> String {
        var text: String
        if let asOf = value.quotesAsOf {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            switch sessionStatus {
            case .continuous, .callAuction:
                formatter.dateFormat = "HH:mm:ss"
                text = "估值截至 \(formatter.string(from: asOf))"
            default:
                formatter.dateFormat = "M月d日 HH:mm"
                text = "按 \(formatter.string(from: asOf)) 报价估值"
            }
        } else {
            text = "仅现金，无持仓"
        }
        if !value.degradedReasons.isEmpty {
            text += " · " + value.degradedReasons.joined(separator: "、")
        }
        return text
    }

    private func caption(for failure: PortfolioValuationFailure) -> String {
        let codes = failure.codes.prefix(3).joined(separator: "、")
        let suffix = failure.codes.count > 3 ? " 等 \(failure.codes.count) 只" : ""
        return "\(failure.title)：\(codes)\(suffix) · 下方数字为缓存价估算"
    }

    /// 总资产下面那行小字。要么说「估值截至什么时候」，要么说清为什么不可信。
    var valuationCaption: String {
        valuationDisplay.caption
    }

    /// 估值是否可信。界面据此决定数字要不要灰化。
    var isValuationVerified: Bool {
        if case .success = valuation() { return true }
        return false
    }

    /// 今日是否已经收盘（15:00 之后且今天是交易日）。
    /// 起点快照、当日盈亏结算都该按这个边界走，而不是「现在是几点」。
    var isAfterMarketClose: Bool {
        TradingSession.isAfterClose(.now, custom: data.customMarketHolidays)
    }

    /// 报价可信度概览，给「数据可信度」页用。
    struct QuoteTrustRow: Identifiable {
        var id: String { code }
        let code: String
        let name: String
        let label: String
        let freshness: QuoteFreshness
        let source: String?
    }

    func quoteTrustRows(at now: Date = .now) -> [QuoteTrustRow] {
        let session = sessionStatus
        let custom = data.customMarketHolidays
        return data.quotes.map { quote in
            let temporal = quote.temporal(in: session)
            return QuoteTrustRow(code: quote.code,
                                 name: quote.name,
                                 label: temporal.displayLabel(),
                                 freshness: temporal.freshness(at: now, custom: custom),
                                 source: quote.source)
        }
    }
}
