import SwiftUI

/// Decorative accents never replace red-up / green-down financial semantics.
enum WorkspaceTone {
    static let blue = Color(red: 0.20, green: 0.43, blue: 0.90)
    static let teal = Color(red: 0.08, green: 0.62, blue: 0.58)
    static let coral = Color(red: 0.88, green: 0.36, blue: 0.38)
}

struct WorkspacePageIntro: View {
    let title: String
    let subtitle: String
    let icon: String
    let tone: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2.weight(.semibold))
                .foregroundStyle(tone).frame(width: 46, height: 46)
                .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).scaledFont(24, weight: .bold)
                Text(subtitle).scaledFont(13).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8)
    }
}

private struct WorkspaceAction: View {
    let title: String
    let detail: String
    let icon: String
    let tone: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(tone)
                    .frame(width: 40, height: 40)
                    .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).scaledFont(16, weight: .semibold).foregroundStyle(.primary)
                    Text(detail).scaledFont(12).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 58).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct DecisionHomeView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var sheet: WorkspaceFeature?
    private var isLight: Bool { colorScheme == .light }
    var body: some View {
        WorkspaceCanvas(title: "AI决策") {
            WorkspacePageIntro(title: "先看证据，再定计划", subtitle: "你的组合，有依据的决策", icon: "sparkles", tone: CardTone.accent)
            VStack(alignment: .leading, spacing: 16) {
                HStack { Label("决策工作区", systemImage: "sparkles").font(.headline); Spacer(); Text("手动发起").font(.caption).foregroundStyle(CardTone.accent) }
                Text(store.data.savedAccountAIAnalysis == nil ? "从了解你的持仓开始" : "已有一份账户分析可复核")
                    .scaledFont(24, weight: .bold)
                Text("画像与预算 → 核对行情 → 分析建议 → 确认计划")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("打开 AI 账户分析", systemImage: "arrow.up.right") { sheet = .aiAnalysis }
                    .buttonStyle(.borderedProminent).tint(CardTone.accent)
            }.cardSurface(tone: CardTone.accent)
            WorkspaceSectionHeading(title: "执行前，先检查", detail: "保留你的决策权")
            WorkspaceAction(title: "账户决策提示", detail: "仓位上限、现金安排与已有规则", icon: "shield.lefthalf.filled", tone: WorkspaceTone.teal) { sheet = .rules }
                .cardSurface(tone: WorkspaceTone.teal)
            HStack(alignment: .top, spacing: 12) {
                decisionTile("已存计划", "\(store.data.tradePlans.count) 条", "checklist", WorkspaceTone.blue, .tradePlans)
                decisionTile("投资画像", "期限与资金约束", "person.crop.rectangle", WorkspaceTone.coral, .portrait)
            }
            WorkspaceFeatureActions(features: [.tradePreview])
            WorkspaceSectionHeading(title: "资金与调仓安排", detail: "先试算，再定计划")
            WorkspaceFeatureActions(features: [.addCash, .portfolioScenario])
            Text("分析与计划由你确认；本程序不连接券商下单。")
                .font(.footnote).foregroundStyle(.secondary)
        }.sheet(item: $sheet) { WorkspaceFeatureDestination(feature: $0) }
    }
    private func decisionTile(_ title: String, _ detail: String, _ icon: String, _ tone: Color, _ target: WorkspaceFeature) -> some View {
        Button { sheet = target } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(tone)
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).cardSurface(tone: tone)
        }.buttonStyle(.plain)
    }
}

struct QuantLabHomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var sheet: WorkspaceFeature?
    private var isLight: Bool { colorScheme == .light }
    var body: some View {
        WorkspaceCanvas(title: "量化实验室") {
            WorkspacePageIntro(title: "让策略先经受检验", subtitle: "独立模拟 · 网格计划 · 参数复盘", icon: "flask", tone: WorkspaceTone.teal)
            VStack(alignment: .leading, spacing: 16) {
                HStack { Label("模拟工作区", systemImage: "square.stack.3d.up").font(.headline); Spacer(); Label("独立账户", systemImage: "lock").font(.caption).foregroundStyle(CardTone.accent) }
                Text("耐心等待，限价验证").scaledFont(24, weight: .bold)
                Text("资金单独保存，挂单预留资金。用建单后的有效报价检验触价，记录每笔模拟费用。")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack { Label("ETF ¥0.10 / 笔", systemImage: "tag"); Spacer(); Text("额外滑点 0") }
                    .font(.caption).foregroundStyle(CardTone.accent)
                Button("进入模拟账户", systemImage: "arrow.up.right") { sheet = .simulation }
                    .buttonStyle(.borderedProminent).tint(CardTone.accent)
            }.cardSurface(tone: CardTone.accent)
            WorkspaceSectionHeading(title: "网格策略", detail: "计划 → 回放 → 参数复盘")
            WorkspaceAction(title: "日内网格研究", detail: "当日计划、测算与回放", icon: "square.grid.3x3", tone: WorkspaceTone.teal) { sheet = .grid }
                .cardSurface(tone: WorkspaceTone.teal)
            WorkspaceFeatureActions(features: [.longGridPlanner, .gridReview])
            Text("报价触价只作模拟撮合参考，不代表实际盘口可成交。虚拟账户不参与真实资产、现金和收益统计。")
                .font(.footnote).foregroundStyle(.secondary)
        }.sheet(item: $sheet) { WorkspaceFeatureDestination(feature: $0) }
    }
}
