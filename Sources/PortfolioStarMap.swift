import SwiftUI

// MARK: - 组合关系星图（从观盘 max 移植并改成「按权重」的真实关系）

/// 组合星图：中心是账户，外围每一颗星是一只真实持仓，星的大小 = 市值占比。
///
/// 和 max 那一版的区别：max 的四个外围节点是「持仓 / 市场 / 跨市场 / AI」的导航入口，
/// 换了页面还是那四颗星，和账户没有关系。这里改成**按权重画**：
/// 谁的星大，谁在账户里说话就响；连线粗细也按权重走。
/// 这样它是一张能读出集中度的图，而不是装饰。
struct PortfolioStarMapCard: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.appAppearance) private var appearance

    /// 最多画几颗星。再多就挤成一团，剩下的用文字交代。
    private let maxNodes = 6

    @State private var chartTarget: Holding?

    private var palette: DsPalette {
        DsPalette(isLight: AppTheme.palette(for: AppAppearance.resolved(appearance)).isLight)
    }

    /// 参与画图的持仓：只取有市值的，按市值降序。
    private var nodes: [Holding] {
        store.data.holdings
            .filter { $0.marketValue > 0 }
            .sorted { $0.marketValue > $1.marketValue }
    }

    private var total: Double {
        nodes.reduce(0) { $0 + $1.marketValue }
    }

    private var shown: [Holding] { Array(nodes.prefix(maxNodes)) }

    private var hiddenCount: Int { max(0, nodes.count - maxNodes) }

    /// 前三大合计占比，集中度就看这个数。
    private var top3Share: Double {
        guard total > 0 else { return 0 }
        let sum = nodes.prefix(3).reduce(0.0) { $0 + $1.marketValue }
        return sum / total * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("组合关系")
                    .scaledFont(DS.fsTitle, weight: .semibold)
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 6)
                Text(top3Share > 0 ? "前三占 \(top3Share.pct(1))" : "")
                    .scaledFont(DS.fsLabel)
                    .monospacedDigit()
                    .foregroundStyle(palette.ink2)
            }

            if total <= 0 {
                Text("先录入持仓，这里会按市值占比画出每只标的的位置与大小。")
                    .scaledFont(DS.fsLabel)
                    .foregroundStyle(palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                starField
                    .frame(height: 268)
                if hiddenCount > 0 {
                    Text("另有 \(hiddenCount) 只未画出（合计 \(((1 - shown.reduce(0) { $0 + $1.marketValue } / total) * 100).pct(1))）")
                        .scaledFont(DS.fsMicro)
                        .foregroundStyle(palette.ink3)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: DS.radius, style: .continuous).fill(palette.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1)
        }
        .sheet(item: $chartTarget) { holding in
            MarketChartView(holding: holding).themedSheetBackground()
        }
    }

    private var starField: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let orbit = min(geo.size.width, geo.size.height) * 0.34
            ZStack {
                Circle()
                    .strokeBorder(palette.hairline, lineWidth: 1)
                    .frame(width: orbit * 2, height: orbit * 2)
                    .position(center)

                ForEach(Array(shown.indices), id: \.self) { index in
                    let holding = shown[index]
                    let weight = total > 0 ? holding.marketValue / total : 0
                    let point = position(index: index, count: shown.count, center: center, orbit: orbit)
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: point)
                    }
                    .stroke(palette.hairline, lineWidth: 1 + 2 * weight)

                    nodeView(holding, weight: weight)
                        .position(point)
                }

                centerView
                    .position(center)
            }
        }
    }

    private func position(index: Int, count: Int, center: CGPoint, orbit: CGFloat) -> CGPoint {
        // 第一颗放在正上方，顺时针排布。
        let slice = 2 * Double.pi / Double(max(count, 1))
        let angle = -Double.pi / 2 + slice * Double(index)
        let x = center.x + orbit * CGFloat(cos(angle))
        let y = center.y + orbit * CGFloat(sin(angle))
        return CGPoint(x: x, y: y)
    }

    private func nodeView(_ holding: Holding, weight: Double) -> some View {
        let diameter = 34 + 26 * CGFloat(min(max(weight, 0), 1).squareRoot())
        let tone = holding.marketValue > 0 && store.holdingPnL(holding) >= 0 ? PnLColor.up : PnLColor.down
        return Button {
            Haptics.tap()
            chartTarget = holding
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(tone.opacity(0.18))
                        .frame(width: diameter, height: diameter)
                    Circle()
                        .strokeBorder(tone.opacity(0.55), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                    Text((weight * 100).num(0))
                        .scaledFont(10.5, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(tone)
                }
                Text(holding.name)
                    .scaledFont(9.5, weight: .medium)
                    .foregroundStyle(palette.ink2)
                    .lineLimit(1)
                    .frame(maxWidth: 74)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(holding.name) 占 \( (weight * 100).pct(0))")
    }

    private var centerView: some View {
        VStack(spacing: 3) {
            Text("组合")
                .scaledFont(9.5, weight: .medium)
                .foregroundStyle(palette.ink3)
            Text("\(nodes.count)")
                .scaledFont(22, weight: .bold)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
            Text("只")
                .scaledFont(9)
                .foregroundStyle(palette.ink3)
        }
        .frame(width: 64, height: 64)
        .background {
            Circle().fill(palette.cardSoft)
        }
        .overlay {
            Circle().strokeBorder(palette.hairline, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
