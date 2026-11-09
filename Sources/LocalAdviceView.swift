import SwiftUI

/// 离线 AI 账户建议。
///
/// 引擎是 `LocalAdvisorEngine`：只用本机账本（持仓、流水、现金、目标仓位、
/// 基金穿透快照）做诊断，**不联网、不需要 API 密钥、不上传任何数据**。
///
/// 以前它藏在 AI 页第一屏第二个按钮里，找起来像在翻设置。这里给一个独立页面，
/// 也让"不联网"这件事在标题上就说清楚。
struct LocalAdviceView: View {
    @EnvironmentObject var store: PortfolioStore
    @Environment(\.dismiss) private var dismiss
    var embedded: Bool = false

    @State private var text = ""
    @State private var generatedAt: Date?

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: store.resolvedAppearance).isLight)
    }

    /// 引擎用空行分段，第一段是账户总判断，后面是逐条可执行事项。
    private var paragraphs: [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        PageHost(embedded: embedded) {
            ScrollView {
                VStack(alignment: .leading, spacing: palette.sectionGap) {
                    headerCard
                    if paragraphs.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        // 不能用 `ForEach(Array(paragraphs.enumerated()), id: \.offset)`：
                        // Swift 的 key path 不能指向元组元素，那样写编译不过。
                        ForEach(paragraphs.indices, id: \.self) { index in
                            paragraphCard(index: index, content: paragraphs[index])
                        }
                    }
                    disclaimer
                }
                .padding(.horizontal, palette.pageInset)
                .padding(.vertical, 14)
            }
            .background(palette.canvas.ignoresSafeArea())
            .navigationTitle("离线账户建议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !embedded {
                        Button("完成") { dismiss() }.tint(palette.accent)
                    }
                }
            }
            .onAppear(perform: generate)
        }
    }

    // MARK: 头部

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11, weight: .semibold))
                Text("本机规则计算 · 不联网 · 不需要密钥")
                    .scaledFont(palette.fsLabel, weight: .medium)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.ink2)

            Text("读的是你账本里的真实持仓、流水、现金和目标仓位，给的是一段诊断 + 可执行事项。它不预测涨跌，也不代替你自己的判断。")
                .scaledFont(palette.fsMicro)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    Haptics.tap()
                    generate()
                } label: {
                    Label("重新计算", systemImage: "arrow.clockwise")
                        .scaledFont(palette.fsMicro, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)

                if let generatedAt {
                    Text("· \(generatedAt.formatted(date: .omitted, time: .shortened))")
                        .scaledFont(palette.fsMicro)
                        .foregroundStyle(palette.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(palette.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.radius, padding: 0)
    }

    // MARK: 段落

    private func paragraphCard(index: Int, content: String) -> some View {
        // 第 0 段是账户总判断，用正文级字号；后面的都是单条建议，用小字。
        let isHeadline = index == 0
        return HStack(alignment: .top, spacing: 8) {
            if !isHeadline {
                Text("\(index)")
                    .scaledFont(palette.fsMicro, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(palette.accent)
                    .frame(width: 16, alignment: .leading)
                    .padding(.top, 1)
            }
            Text(content)
                .scaledFont(isHeadline ? palette.fsRow : palette.fsMicro, weight: isHeadline ? .medium : .regular)
                .foregroundStyle(isHeadline ? palette.ink : palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(palette.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsSurface(palette, radius: palette.radius, padding: 0)
    }

    private var disclaimer: some View {
        Text("这些结论来自你填的数据：仓位上限、目标配置、现金、流水。数据不准，结论就不准。它不构成投资建议，也不发送到任何服务器。")
            .scaledFont(palette.fsMicro)
            .foregroundStyle(palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func generate() {
        text = LocalAdvisorEngine.review(data: store.data, totalAsset: store.totalAsset)
        generatedAt = .now
    }
}
