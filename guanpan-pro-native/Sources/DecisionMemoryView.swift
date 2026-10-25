import SwiftUI

// MARK: - AI 决策记忆与复盘
//
// 这一页回答三个问题：
//   1. 当时 AI 到底基于什么给了这个建议？（快照，不事后重算）
//   2. 我有没有真的成交？（只有用户确认才写）
//   3. 后来什么变了、为什么改判？（逐条可追的变化说明）
//
// 页面只读账本，不写持仓、不改现金。

struct DecisionMemoryView: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var selected: NextDecisionRecord?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", open = "待处理", filled = "已成交", closed = "已结束"
        var id: String { rawValue }
    }

    private var records: [NextDecisionRecord] {
        switch filter {
        case .all: return model.decisionMemory
        case .open: return model.decisionMemory.filter { $0.isOpen }
        case .filled: return model.decisionMemory.filter { $0.outcome.isFilled }
        case .closed: return model.decisionMemory.filter { !$0.isOpen && !$0.outcome.isFilled }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    filterRow
                    if records.isEmpty {
                        GPCard {
                            GPInlineEmpty(symbol: "clock.arrow.circlepath",
                                          text: "还没有决策记忆。生成今日指导后，每条「有具体计划」的建议都会连同当时的行情、持仓、NAS 统计、新闻与画像一起记下来。")
                        }
                    } else {
                        ForEach(records) { record in
                            Button { selected = record } label: { row(record) }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
            }
            .background(p.canvas.ignoresSafeArea())
            .navigationTitle("AI 决策记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $selected) { record in
                DecisionRecordDetail(recordID: record.id)
                    .environmentObject(model)
            }
        }
    }

    private var header: some View {
        let filled = model.decisionMemory.filter { $0.outcome.isFilled }.count
        let open = model.decisionMemory.filter { $0.isOpen }.count
        let revised = model.decisionMemory.filter { !$0.revisions.isEmpty }.count
        return DataPanel(title: "记忆概览", accent: p.forest, caption: "共 \(model.decisionMemory.count) 条") {
            HStack(spacing: 10) {
                stat("待处理", "\(open)", p.chartGold)
                stat("已真实成交", "\(filled)", p.jade)
                stat("发生过改判", "\(revised)", p.terracotta)
            }
            Text("记忆里保存的是「当时的判断依据」；改判必须写明什么变了，复盘只做事后核对，不计入任何收益。")
                .font(.caption2).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ title: String, _ value: String, _ tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tone)
            Text(title).font(.system(size: 9)).foregroundStyle(p.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { item in
                    Button { filter = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(filter == item ? p.forest.opacity(0.14) : p.paper, in: Capsule())
                            .overlay(Capsule().stroke(filter == item ? p.forest.opacity(0.4) : p.line, lineWidth: 0.8))
                            .foregroundStyle(filter == item ? p.forest : p.muted)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ record: NextDecisionRecord) -> some View {
        let current = record.currentSnapshot
        return GPCard(accent: tone(record)) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(record.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1)
                        Text(current.state).font(.system(size: 9)).foregroundStyle(p.muted)
                        if !record.revisions.isEmpty {
                            Text("\(record.revisions.count) 次改判")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(p.terracotta.opacity(0.12), in: Capsule())
                                .foregroundStyle(p.terracotta)
                        }
                    }
                    Text(current.headline).font(.system(size: 12, weight: .medium)).foregroundStyle(p.ink).lineLimit(2)
                    HStack(spacing: 6) {
                        if let limit = current.limitPrice {
                            Text("限价 ¥\(limit)").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                        }
                        if let units = current.limitUnits {
                            Text("\(units) 份").font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
                        }
                    }
                    Text(NextDecisionMemory.freshness(record, at: Date()))
                        .font(.system(size: 9)).foregroundStyle(tone(record))
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(record.outcome.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(tone(record).opacity(0.12), in: Capsule())
                        .foregroundStyle(tone(record))
                    Text(NextDecisionDiff.dateText(record.createdAt)).font(.system(size: 9)).foregroundStyle(p.muted)
                }
            }
        }
    }

    private func tone(_ record: NextDecisionRecord) -> Color {
        switch record.outcome {
        case .filled: return p.jade
        case .pending: return p.chartGold
        case .invalidated: return p.risk
        case .expired, .skipped: return p.muted
        }
    }
}

// MARK: - 单条记忆详情

struct DecisionRecordDetail: View {
    @EnvironmentObject private var model: NextAppModel
    @Environment(\.gp) private var p
    @Environment(\.dismiss) private var dismiss
    let recordID: UUID

    private var record: NextDecisionRecord? { model.decisionMemory.first { $0.id == recordID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let record {
                        summary(record)
                        snapshotCard(record)
                        planCard(record)
                        handlingCard(record)
                        if !record.revisions.isEmpty { revisionsCard(record) }
                        reviewCard(record)
                    } else {
                        GPCard { GPInlineEmpty(symbol: "questionmark", text: "这条记忆已不存在") }
                    }
                }
                .padding(14)
            }
            .background(p.canvas.ignoresSafeArea())
            .navigationTitle("当时到底怎么判断的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
        }
    }

    private func summary(_ record: NextDecisionRecord) -> some View {
        let current = record.currentSnapshot
        let title = record.latestSnapshot == nil ? "最初判断" : "最近一次判断"
        let changedAt = record.revisions.last?.at ?? record.createdAt
        return DataPanel(title: "\(record.name) · \(title)", accent: p.forest,
                  caption: NextDecisionDiff.dateText(changedAt)) {
            HStack(spacing: 8) {
                pill(current.state, p.chartBlue)
                pill(current.strategy, p.forest)
                pill("置信度 \(current.confidenceLevel)", p.chartGold)
                Spacer(minLength: 0)
            }
            Text(current.headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(NextDecisionMemory.freshness(record, at: Date())).font(.caption2).foregroundStyle(p.muted)
        }
    }

    private func snapshotCard(_ record: NextDecisionRecord) -> some View {
        let s = record.snapshot
        return DataPanel(title: "当时的数据", accent: p.chartBlue) {
            VStack(alignment: .leading, spacing: 5) {
                line("行情", s.price.map { "¥\($0)" } ?? "无报价", note: s.quoteSource)
                line("持仓", "\(s.units) 份", note: s.averageCost.map { "成本 $\($0)" })
                if let days = s.nasDays {
                    line("NAS 长期分时", "\(days) 天归档", note: s.nasStale == true ? "已过期" : "新鲜")
                } else {
                    line("NAS 长期分时", "不可用", note: "本次结论只用本地数据")
                }
                if let vwap = s.nasVwap20 {
                    line("20 日 VWAP", "¥\(vwap)",
                         note: s.nasCloseVsVwap20.map { String(format: "当时偏离 %+.2f%%", $0) })
                }
                if let amplitude = s.nasAmplitude60 {
                    line("60 日振幅中位数", String(format: "%.2f%%", amplitude),
                         note: s.nasRoundTrips60.map { String(format: "日均往返 %.1f 次", $0) })
                }
                if let low = s.nasSupportP10, let high = s.nasResistanceP90 {
                    line("长期价格带", "¥\(low)–¥\(high)", note: "p10–p90")
                }
                if let crossMarket = s.crossMarketEvidence, !crossMarket.isEmpty {
                    Text("跨市场研究快照").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted).padding(.top, 3)
                    ForEach(crossMarket.prefix(8), id: \.self) { item in
                        Text("· \(item)").font(.system(size: 9)).foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if crossMarket.count > 8 {
                        line("其余证据", "\(crossMarket.count - 8) 条", note: "已保存在当时快照")
                    }
                } else {
                    line("跨市场研究", "当时未提供", note: "不推断领先关系")
                }
                if !s.profileTags.isEmpty {
                    line("画像", s.profileTags.joined(separator: " · "), note: "只影响排序，不改价格")
                }
                if let role = s.instrumentRole {
                    let source = s.instrumentRoleSource.map { " · \($0)" } ?? ""
                    line("证券角色", role + source, note: s.instrumentRoleReason)
                }
                if !s.newsTitles.isEmpty {
                    line("相关新闻", "\(s.newsTitles.count) 条", note: s.newsTitles.first)
                }
            }
        }
    }

    private func planCard(_ record: NextDecisionRecord) -> some View {
        let s = record.snapshot
        return DataPanel(title: "当时的建议", accent: p.forest) {
            VStack(alignment: .leading, spacing: 5) {
                if let price = s.limitPrice {
                    line("限价", "¥\(price)", note: s.limitUnits.map { "\($0) 份" })
                } else {
                    line("限价", "没有给出具体价格", note: "数据不足时宁可不给")
                }
                if let gain = s.expectedNetGain { line("预计净收益", "¥\(gain)", note: "已扣两笔手续费") }
                if let reduce = s.expectedCostReduction { line("等效降本", "¥\(reduce)/份", note: nil) }
                line("有效期", NextDecisionDiff.dateText(s.validUntil), note: nil)
                if !s.invalidConditions.isEmpty {
                    Text("失效条件").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted).padding(.top, 2)
                    ForEach(s.invalidConditions, id: \.self) { item in
                        Text("· \(item)").font(.system(size: 10)).foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func handlingCard(_ record: NextDecisionRecord) -> some View {
        DataPanel(title: "我的处置", accent: p.chartGold, caption: record.outcome.rawValue) {
            Text("真实成交必须从 AI 候选计划的成交入口登记，才能同时更新真实流水、现金、持仓和本条决策记忆。此页不单独记成交。")
                .font(.caption2).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            if record.outcome == .pending {
                HStack(spacing: 8) {
                    GPActionButton(title: "我放弃了", secondary: true) {
                        model.markDecisionSkipped(id: record.id)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if let price = record.review.filledPrice {
                        Text("成交 ¥\(price)").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.ink)
                    }
                    if let units = record.review.filledUnits {
                        Text("\(units) 份").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.muted)
                    }
                    Spacer(minLength: 0)
                    if let at = record.outcomeAt {
                        Text(NextDecisionDiff.dateText(at)).font(.system(size: 9)).foregroundStyle(p.muted)
                    }
                }
            }
        }
    }

    private func revisionsCard(_ record: NextDecisionRecord) -> some View {
        DataPanel(title: "改判痕迹", accent: p.terracotta, caption: "\(record.revisions.count) 次") {
            ForEach(record.revisions) { revision in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(NextDecisionDiff.dateText(revision.at)).font(.system(size: 9)).foregroundStyle(p.muted)
                        Text("\(revision.fromHeadline) → \(revision.toHeadline)")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(p.ink).lineLimit(2)
                    }
                    ForEach(revision.changes, id: \.self) { change in
                        Text("· \(change)").font(.system(size: 10)).foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func reviewCard(_ record: NextDecisionRecord) -> some View {
        DataPanel(title: "事后复盘", accent: p.jade,
                  caption: record.review.reviewedAt.map { NextDecisionDiff.dateText($0) }) {
            Text(record.review.note.isEmpty ? "还没有复盘结论：等下一次扫描后会按当时价格与真实成交价核对。" : record.review.note)
                .font(.caption).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let percent = record.review.laterChangePercent {
                Text(String(format: "事后变化 %+.2f%%（仅复盘记录，不计入收益）", percent))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(p.muted)
            }
            if !record.snapshot.evidence.isEmpty {
                Divider().opacity(0.3)
                Text("当时的依据").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted)
                ForEach(record.snapshot.evidence, id: \.self) { item in
                    Text("· \(item)").font(.system(size: 10)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !record.snapshot.risks.isEmpty {
                Text("当时的风险").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.muted).padding(.top, 2)
                ForEach(record.snapshot.risks, id: \.self) { item in
                    Text("· \(item)").font(.system(size: 10)).foregroundStyle(p.terracotta)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func line(_ title: String, _ value: String, note: String?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 11)).foregroundStyle(p.muted)
                    .frame(width: 88, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(p.ink)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 2)
                if let note {
                    Text(note).font(.system(size: 9)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: true, vertical: false).multilineTextAlignment(.trailing)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 10)).foregroundStyle(p.muted)
                    Spacer(minLength: 4)
                }
                Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(p.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.system(size: 9)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(_ text: String, _ tone: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(tone.opacity(0.12), in: Capsule())
            .foregroundStyle(tone).lineLimit(1)
    }
}
