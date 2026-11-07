import SwiftUI

// MARK: - 观盘max NAS：补采覆盖状态 + 手动补采入口
//
// 这是「数据与同步 → 观盘max NAS」设置段里的一小组行，单独成文件是为了不把
// 已经很长的 SettingsView 再撑大，也避免在同一视图里再挂第 N 个
// confirmationDialog（同视图多个同类型弹层只有最后一个生效）。
//
// 契约（来自 repo/guanpan-f/nas/fminute/http_api.py）：
//   GET  /api/v1/backfill-status          只读覆盖状态，旧部署包 404
//   POST /api/v1/minute-history/backfill  写队列，body 恰好 5 个字符串键，202 返回 receipt
// 写操作必须二次确认；接口不存在时静默降级，不显示成「0% 覆盖」。

private struct BackfillCandidate: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

private struct BackfillPriorityOption: Identifiable {
    let id: String
    let title: String
}

struct MaxNASBackfillSection: View {
    @EnvironmentObject private var store: PortfolioStore
    @AppStorage(GuanpanMaxNAS.urlKey) private var fminuteURL = ""

    @State private var busy = false
    @State private var supports: Bool? = nil
    @State private var statusText = ""
    @State private var resultText = ""
    @State private var showManual = false
    @State private var selectedCode = ""
    @State private var priority = "holding"
    @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var endDate: Date = Date()
    @State private var confirmSubmit = false

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let priorities: [BackfillPriorityOption] = [
        BackfillPriorityOption(id: "holding", title: "持仓（最高）"),
        BackfillPriorityOption(id: "watchlist", title: "自选"),
        BackfillPriorityOption(id: "aiResearch", title: "AI 研究"),
        BackfillPriorityOption(id: "benchmark", title: "基准指数")
    ]

    private var addressReady: Bool {
        GuanpanMaxNAS.validateAddress() != nil
    }

    /// 候选标的只取能归一化为 6 位纯数字的 A 股代码；港股/美股/场外基金
    /// 发过去会被 provider 判 400，不如在录入时就拦掉。
    private var candidates: [BackfillCandidate] {
        var seen = Set<String>()
        var result: [BackfillCandidate] = []
        for holding in store.data.holdings {
            guard let code = GuanpanMaxNAS.normalizedSecurityCode(holding.code),
                  seen.insert(code).inserted else { continue }
            result.append(BackfillCandidate(code: code,
                                            name: holding.name.isEmpty ? code : holding.name))
        }
        for quote in store.data.quotes {
            guard let code = GuanpanMaxNAS.normalizedSecurityCode(quote.code),
                  seen.insert(code).inserted else { continue }
            result.append(BackfillCandidate(code: code,
                                            name: quote.name.isEmpty ? code : quote.name))
        }
        return Array(result.prefix(40))
    }

    private var startText: String { Self.dayFormatter.string(from: startDate) }
    private var endText: String { Self.dayFormatter.string(from: endDate) }

    /// 客户端先挡住明显的滥用：不能倒序、不能补未来、跨度不超过 90 天。
    private var dateRangeValid: Bool {
        let today = Self.dayFormatter.string(from: Date())
        guard startText <= endText, endText <= today else { return false }
        let days = Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 91
        return days >= 0 && days <= 90
    }

    var body: some View {
        Group {
            Button {
                Task { @MainActor in await loadStatus() }
            } label: {
                Label(busy ? "正在读取…" : "读取补采覆盖状态", systemImage: "chart.bar.doc.horizontal")
            }
            .disabled(busy || !addressReady)

            if supports == false {
                Text("当前部署包没有 /api/v1/backfill-status（旧版 f-minute-archive），已静默跳过；不会把「接口不存在」当成 0% 覆盖。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !statusText.isEmpty {
                Text(statusText).font(.footnote).foregroundStyle(.secondary)
            }

            DisclosureGroup("手动补采（会向 NAS 写入任务）", isExpanded: $showManual) {
                Picker("标的", selection: $selectedCode) {
                    if candidates.isEmpty {
                        Text("没有可用的 A 股标的").tag("")
                    } else {
                        ForEach(candidates) { item in
                            Text("\(item.name) · \(item.code)").tag(item.code)
                        }
                    }
                }
                DatePicker("起始日", selection: $startDate,
                           in: ...Date(), displayedComponents: .date)
                DatePicker("结束日", selection: $endDate,
                           in: ...Date(), displayedComponents: .date)
                Picker("优先级", selection: $priority) {
                    ForEach(priorities) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                if !dateRangeValid {
                    Text("日期范围无效：起止日期需按序、不能晚于今天，且跨度不超过 90 天。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("提交补采任务") { confirmSubmit = true }
                    .disabled(busy || !addressReady || selectedCode.isEmpty
                              || candidates.isEmpty || !dateRangeValid)
                Text("\(startText) ~ \(endText) · 市场 CN · 只排入尚未完整的交易日。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if !resultText.isEmpty {
                Text(resultText).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if selectedCode.isEmpty { selectedCode = candidates.first?.code ?? "" }
        }
        .confirmationDialog("这会在 NAS 的补采队列里写入新任务，可能触发跨多个交易日的外部行情抓取。确认继续？",
                            isPresented: $confirmSubmit, titleVisibility: .visible) {
            Button("确认提交", role: .destructive) { submit() }
            Button("取消", role: .cancel) { }
        }
    }

    // MARK: - 网络

    @MainActor
    private func loadStatus() async {
        busy = true
        defer { busy = false }
        guard let snapshot = await GuanpanMaxNAS.backfillStatus() else {
            supports = false
            statusText = ""
            return
        }
        supports = true
        statusText = Self.describe(snapshot)
    }

    private func submit() {
        guard let code = GuanpanMaxNAS.normalizedSecurityCode(selectedCode),
              dateRangeValid, addressReady else { return }
        let start = startText
        let end = endText
        let chosenPriority = priority
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let receipt = try await GuanpanMaxNAS.enqueueBackfill(
                    code: code, startDate: start, endDate: end, priority: chosenPriority)
                resultText = "已提交 \(code)：请求 \(receipt.requestedSessions ?? 0) 个交易日，"
                    + "新排入 \(receipt.queuedOrRequeued ?? 0) 个，"
                    + "已覆盖 \(receipt.alreadyCoveredSessions ?? 0) 个，"
                    + "保留终态 \(receipt.preservedTerminalSessions ?? 0) 个，"
                    + "优先级 \(receipt.priority ?? chosenPriority)。"
                await loadStatus()
            } catch {
                resultText = error.localizedDescription
            }
        }
    }

    private static func describe(_ snapshot: GuanpanMaxNAS.BackfillStatusSnapshot) -> String {
        guard let markets = snapshot.backfillStatus, !markets.isEmpty else {
            return "补采状态：服务端未返回任何市场覆盖（backfill worker 可能未配置）。"
        }
        var lines: [String] = []
        for market in markets.keys.sorted() {
            guard let item = markets[market] else { continue }
            if let reason = item.error {
                lines.append("\(market)：不可用（\(reason)）")
                continue
            }
            let coverage = item.coveragePercent.map { $0.pct(2) } ?? "--"
            var summary = "\(market) 覆盖 \(coverage)"
            if let count = item.securityCount { summary += " · \(count) 只标的" }
            if let sessions = item.plannedSessions { summary += " · 近 \(sessions) 个交易日" }
            lines.append(summary)
            let counters: [(String, Int?)] = [
                ("完整", item.complete), ("部分", item.partial), ("缺失", item.missing),
                ("待重试", item.retryable), ("超出数据源覆盖", item.outOfProviderCoverage),
                ("永久不可用", item.permanentUnavailable)
            ]
            let detail = counters.compactMap { title, value -> String? in
                guard let value, value > 0 else { return nil }
                return "\(title) \(value)"
            }
            if !detail.isEmpty { lines.append(detail.joined(separator: " / ")) }
            if let first = item.earliestRealHistoryDate, let last = item.latestRealHistoryDate {
                lines.append("真实历史 \(first) ~ \(last)")
            } else if let first = item.earliestRealHistoryDate {
                lines.append("真实历史起始 \(first)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
