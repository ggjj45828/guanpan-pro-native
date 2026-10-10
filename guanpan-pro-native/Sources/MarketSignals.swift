import Foundation
import SwiftUI

/// 从日线推导的轻量技术信号，供自选面板 / 量化引擎 / 详情页共用。
///
/// 设计原则：只做「历史描述」，不做预测；缺数据就明确显示缺数据，绝不补造。
/// 标签口径与网页版《观盘 Pro》自选面板保持一致，便于两边对照。
struct MarketSignal {
    var score: Int
    var label: String
    var notes: [String]
    var date: String

    // 单项信号（用于标签展示）
    var macdPositive = false      // MACD 柱为正
    var macdBullish = false       // DIF 在 DEA 上方（多头）
    var rsi: Double?
    var kdjJ: Double?
    var close: Double = 0
    var ma5: Double?
    var ma10: Double?
    var ma20: Double?
    var ma60: Double?
    var volumeRatio: Double?      // 当日量 / 20 日均量
    var isOversold = false        // RSI/KDJ 超卖
    var isOverbought = false      // RSI/KDJ 超买

    /// 是否站上 MA20
    var aboveMA20: Bool? { ma20.map { close >= $0 } }

    /// 趋势描述：震荡 / 多头 / 空头
    var trendText: String {
        guard let ma5, let ma10, let ma20 else { return "数据不足" }
        if ma5 > ma10 && ma10 > ma20 { return "多头排列" }
        if ma5 < ma10 && ma10 < ma20 { return "空头排列" }
        return "均线交织 · 震荡"
    }

    /// 生成徽标标签（与网页版一致的一组）
    var tags: [SignalTag] {
        var out: [SignalTag] = []
        if macdBullish { out.append(.init(text: "MACD多头", tone: .up)) }
        else if !macdPositive { out.append(.init(text: "MACD空头", tone: .down)) }
        if isOversold { out.append(.init(text: "超卖", tone: .up)) }
        else if isOverbought { out.append(.init(text: "超买", tone: .down)) }
        if let volumeRatio, volumeRatio >= 1.8 { out.append(.init(text: "放量", tone: .warn)) }
        if let aboveMA20 { out.append(.init(text: aboveMA20 ? "站上MA20" : "破MA20", tone: aboveMA20 ? .up : .down)) }
        return out
    }
}

/// 标签配色：up=看多(红) / down=看空(绿) / warn=提示(橙)，遵循国内红涨绿跌
struct SignalTag: Identifiable {
    enum Tone { case up, down, warn, neutral }
    var text: String
    var tone: Tone
    var id: String { text }
    var color: Color {
        switch tone {
        case .up: return Color(red: 0.93, green: 0.30, blue: 0.37)
        case .down: return Color(red: 0.07, green: 0.77, blue: 0.55)
        case .warn: return Color(red: 1.0, green: 0.62, blue: 0.11)
        case .neutral: return Color.secondary
        }
    }
}

/// 信号计算器：纯函数，无副作用，可在任意线程调用。
enum MarketSignalCalculator {

    /// 从日线计算信号。不足 20 根返回 nil（数据不足，不做臆测）。
    static func evaluate(_ bars: [DailyBar]) -> MarketSignal? {
        let source = Array(bars.suffix(640))
        guard source.count >= 20, let latest = source.last else { return nil }
        let closes = source.map(\.close)

        func average(_ count: Int) -> Double? {
            guard closes.count >= count else { return nil }
            return closes.suffix(count).reduce(0, +) / Double(count)
        }

        guard let ma5 = average(5), let ma10 = average(10), let ma20 = average(20) else { return nil }
        let ma60 = average(60)

        var raw = 0
        var notes: [String] = []

        // 均线排列
        if ma5 > ma10 && ma10 > ma20 { raw += 2; notes.append("短期均线多头排列") }
        else if ma5 < ma10 && ma10 < ma20 { raw -= 2; notes.append("短期均线空头排列") }
        else { notes.append("均线交织，震荡格局") }

        // 中期趋势
        if let ma60 {
            if ma20 > ma60 { raw += 1; notes.append("MA20 在 MA60 上方") }
            else { raw -= 1; notes.append("MA20 在 MA60 下方") }
        }

        // 收盘位置
        if latest.close >= ma20 { raw += 1; notes.append("收盘高于 MA20") }
        else { raw -= 1; notes.append("收盘低于 MA20") }

        // 5 日动量
        if source.count >= 6 {
            let momentum = latest.close / source[source.count - 6].close - 1
            if momentum >= 0.02 { raw += 1; notes.append("5 日动量为正") }
            else if momentum <= -0.02 { raw -= 1; notes.append("5 日动量为负") }
        }

        // RSI14
        var rsiValue: Double?
        if closes.count >= 15 {
            let base = closes.count - 15
            var delta: [Double] = []
            for offset in 1..<15 { delta.append(closes[base + offset] - closes[base + offset - 1]) }
            let gain = delta.map { max(0, $0) }.reduce(0, +) / 14
            let loss = delta.map { max(0, -$0) }.reduce(0, +) / 14
            let rsi = loss == 0 ? (gain == 0 ? 50 : 100) : 100 - 100 / (1 + gain / loss)
            rsiValue = rsi
            if rsi < 30 { raw += 1; notes.append("RSI14 偏低") }
            else if rsi > 70 { raw -= 1; notes.append("RSI14 偏高") }
            else { notes.append("RSI14 中性") }
        }

        // MACD（12/26/9）
        var macdHistogram = 0.0
        var difValue = 0.0
        var deaValue = 0.0
        if closes.count >= 35 {
            var fast = closes[0], slow = closes[0], dea = 0.0, histogram = 0.0
            var dif = 0.0
            for (index, close) in closes.enumerated() {
                if index > 0 {
                    fast += (2.0 / 13.0) * (close - fast)
                    slow += (2.0 / 27.0) * (close - slow)
                }
                dif = fast - slow
                dea = index == 0 ? dif : dea + 0.2 * (dif - dea)
                histogram = 2 * (dif - dea)
            }
            macdHistogram = histogram; difValue = dif; deaValue = dea
            if histogram > 0 { raw += 1; notes.append("MACD 柱值为正") }
            else if histogram < 0 { raw -= 1; notes.append("MACD 柱值为负") }
        }

        // 量能
        var volumeRatio: Double?
        if source.count >= 21 {
            let baseline = source.suffix(21).dropLast().map(\.volume).reduce(0, +) / 20
            if baseline > 0 {
                let ratio = latest.volume / baseline
                volumeRatio = ratio
                let change = latest.close / source[source.count - 2].close - 1
                if ratio >= 1.5 {
                    if change >= 0 { raw += 1; notes.append("放量上涨") }
                    else { raw -= 1; notes.append("放量下跌") }
                }
            }
        }

        // KDJ 的 J 值（9,3,3）—— 仅用于超买超卖标签
        var kdjJ: Double?
        if closes.count >= 9 {
            var k = 50.0, d = 50.0
            for index in 8..<closes.count {
                let window = source[(index - 8)...index]
                let high = window.map(\.high).max() ?? closes[index]
                let low = window.map(\.low).min() ?? closes[index]
                let rsv = high == low ? 50 : (closes[index] - low) / (high - low) * 100
                k = (2.0 / 3.0) * k + (1.0 / 3.0) * rsv
                d = (2.0 / 3.0) * d + (1.0 / 3.0) * k
            }
            kdjJ = 3 * k - 2 * d
        }

        let score = min(100, max(0, 50 + raw * 6))
        let label = score >= 68 ? "偏强" : score >= 56 ? "偏多" : score <= 32 ? "偏弱" : score <= 44 ? "偏空" : "中性"

        var signal = MarketSignal(score: score, label: label, notes: notes, date: latest.date)
        signal.macdPositive = macdHistogram > 0
        signal.macdBullish = macdHistogram > 0 && difValue > deaValue
        signal.rsi = rsiValue
        signal.kdjJ = kdjJ
        signal.close = latest.close
        signal.ma5 = ma5; signal.ma10 = ma10; signal.ma20 = ma20; signal.ma60 = ma60
        signal.volumeRatio = volumeRatio

        let rsiOversold = (rsiValue ?? 50) < 30
        let rsiOverbought = (rsiValue ?? 50) > 70
        let jOversold = (kdjJ ?? 50) < 20
        let jOverbought = (kdjJ ?? 50) > 80
        signal.isOversold = rsiOversold || jOversold
        signal.isOverbought = rsiOverbought || jOverbought
        return signal
    }
}

/// 自选卡片上的标签行（横向可换行的徽标）
struct SignalTagRow: View {
    let tags: [SignalTag]
    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 5) {
                ForEach(tags) { tag in
                    Text(tag.text)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .foregroundStyle(tag.color)
                        .background(tag.color.opacity(0.14), in: Capsule())
                }
            }
        }
    }
}
