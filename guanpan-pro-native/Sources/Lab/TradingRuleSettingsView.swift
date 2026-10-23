import SwiftUI

struct TradingRuleSettingsView: View {
    @EnvironmentObject private var lab: InvestmentLabStore
    private var positions: [[String: Any]] { lab.accounts["A"]?["positions"] as? [[String: Any]] ?? [] }
    var body: some View {
        ProPage(title: "每只证券，各自规则", subtitle: "只更正模拟规则，不改变真实持仓或实验起点") {
            Text("跨境美股 ETF 的二级市场回转交易可设为 T+0；境内股票 ETF 与股票需按具体规则确认。先核对证券，再修改。")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(Array(positions.enumerated()), id: \.offset) { _, p in
                let symbol = p["symbol"] as? String ?? ""
                VStack(alignment: .leading, spacing: 12) {
                    Text(symbol).font(.headline.monospaced())
                    Picker("回转交易", selection: Binding(get: { p["tPlusOne"] as? Bool ?? true }, set: { value in
                        lab.action(["type": "tradingRule", "id": UUID().uuidString, "symbol": symbol, "tPlusOne": value, "at": Int64(Date().timeIntervalSince1970 * 1000)])
                    })) {
                        Text("T+0 · 当日可卖").tag(false)
                        Text("T+1 · 后续交易日可卖").tag(true)
                    }.pickerStyle(.segmented)
                }
                Divider()
            }
            Text("修改前须撤销该证券所有未完成虚拟挂单；已发生成交不重写。ETF 买卖每笔成交手续费仍为 0.10 元。")
                .font(.caption).foregroundStyle(.secondary)
            Text(lab.message).font(.caption)
            Link("上交所 ETF 回转交易说明", destination: URL(string: "https://www.sse.com.cn/assortment/fund/etf/question/c/c_20240118_5734755.shtml")!)
        }
    }
}
