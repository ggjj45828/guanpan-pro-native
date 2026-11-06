import SwiftUI

/// 市场快讯（新闻证据）。
///
/// 这一页的职责不是「给你一个结论」，而是把**外部标题**如实摆出来，并且明确
/// 它只是标题：谁说的、什么时候、是否点名了你的持仓。判断留在用户和 AI 那里，
/// 这里不写「利好/利空」这种替人下结论的词。
struct NewsHubView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var news = NewsCenter.shared

    /// true = 只看与持仓直接关联的条目。
    @State private var onlyRelated = true

    private var palette: DsPalette {
        DsPalette.of(store.resolvedAppearance)
    }

    private var holdingCodes: [String] {
        store.data.holdings.map(\.code)
    }

    private var displayed: [NewsArticle] {
        let all = news.displayArticles
        // 没有持仓时「只看关联」必然是空列表，那种空是假空 —— 直接给全部。
        guard onlyRelated, !holdingCodes.isEmpty else { return all }
        return news.articles(forCodes: holdingCodes, in: all)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    statusCard
                    filterBar
                    if displayed.isEmpty {
                        emptyCard
                    } else {
                        ForEach(displayed) { article in
                            articleCard(article)
                        }
                    }
                    disclaimerCard
                }
                .padding(.horizontal, DS.pageInset)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("市场快讯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .refreshable {
                await news.refresh(force: true)
            }
            .task {
                await news.refresh()
            }
        }
        .themedSheetBackground()
    }

    // MARK: 状态卡

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("快讯来源")
                        .scaledFont(DS.fsMicro)
                        .foregroundStyle(palette.ink3)
                    Text(news.provider)
                        .scaledFont(DS.fsLabel, weight: .semibold)
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Button {
                    Haptics.tap()
                    news.refresh(force: true)
                } label: {
                    HStack(spacing: 4) {
                        if news.isFetching {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                        }
                        Text(news.isFetching ? "获取中" : "刷新")
                            .scaledFont(DS.fsMicro, weight: .semibold)
                    }
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background { Capsule().fill(palette.accentDim) }
                }
                .buttonStyle(.plain)
                .disabled(news.isFetching)
            }

            HStack(spacing: 18) {
                miniStat("条目", "\(news.displayArticles.count)")
                miniStat("关联持仓", "\(news.associatedCount(forCodes: holdingCodes))/\(store.data.holdings.count)")
                miniStat("时效", news.isStale ? "已过期" : "24h 内")
            }

            Text(news.freshnessText)
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)

            if let error = news.lastError {
                Text(error)
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(CardTone.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsSurface(palette, radius: DS.radius, padding: DS.pad)
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(9.5)
                .foregroundStyle(palette.ink3)
            Text(value)
                .scaledFont(DS.fsRow, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
        }
    }

    // MARK: 过滤

    private var filterBar: some View {
        HStack(spacing: 8) {
            filterChip("只看持仓关联", on: onlyRelated) { onlyRelated = true }
            filterChip("全部快讯", on: !onlyRelated) { onlyRelated = false }
            Spacer(minLength: 0)
        }
    }

    private func filterChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .scaledFont(DS.fsLabel, weight: .medium)
                .foregroundStyle(on ? palette.ink : palette.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    Capsule().fill(on ? palette.cardSoft : Color.clear)
                }
                .overlay {
                    Capsule().strokeBorder(on ? palette.hairline : palette.hairline.opacity(0.5), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: 条目

    private func articleCard(_ article: NewsArticle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Self.timeText(article.publishedAt))
                    .scaledFont(DS.fsMicro, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink3)
                Text("·").scaledFont(DS.fsMicro).foregroundStyle(palette.ink3)
                Text(article.publisher)
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !article.relatedSecurities.isEmpty {
                    Text("关联")
                        .scaledFont(9.5, weight: .bold)
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background { Capsule().fill(palette.accentDim) }
                }
            }

            Text(article.title)
                .scaledFont(DS.fsRow, weight: .semibold)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = article.summary, !summary.isEmpty {
                Text(summary)
                    .scaledFont(DS.fsLabel)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !article.relatedSecurities.isEmpty {
                Text(article.relatedSecurities.prefix(4)
                        .map { "\($0.name) \($0.code)" }
                        .joined(separator: " · "))
                    .scaledFont(DS.fsMicro)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
            }

            if let url = URL(string: article.url) {
                Link(destination: url) {
                    HStack(spacing: 3) {
                        Text("查看原文").scaledFont(DS.fsMicro, weight: .semibold)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(palette.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: 18, padding: 14)
    }

    // MARK: 空态与口径

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(onlyRelated ? "这段时间没有点名你持仓的快讯" : "还没有取到可用快讯")
                .scaledFont(DS.fsRow, weight: .semibold)
                .foregroundStyle(palette.ink)
            Text(onlyRelated
                 ? "切换成「全部快讯」可以看市场背景标题；没有点名代码的条目不往个股上归因。"
                 : "下拉刷新试试；接口不可用时这里会明确报错，不会拿旧标题假装是今天的。")
                .scaledFont(DS.fsLabel)
                .foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: DS.radius, padding: DS.pad)
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("口径")
                .scaledFont(DS.fsMicro, weight: .semibold)
                .foregroundStyle(palette.ink3)
            Text("来源是同花顺财经 7×24 的公开网页接口，不是签约数据源；这里只有标题与摘要，没有正文核实。只有条目自己列出证券代码时，才算与该标的直接关联。快讯不参与任何买卖指令生成，也不会改动账本。")
                .scaledFont(DS.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
