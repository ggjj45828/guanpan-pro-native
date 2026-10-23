import SwiftUI

struct VisualHoldingsView: View {
    @EnvironmentObject private var store: PortfolioStore
    @Environment(\.visualTheme) private var theme
    private var tokens: DesignTokens { ThemeManager.tokens(theme) }
    private var holdings: [Holding] {
        store.data.holdings.filter { $0.kind == .etf && $0.quantity > 0 }
            .sorted { $0.marketValue > $1.marketValue }
    }
    private var value: Double { holdings.reduce(0) { $0 + $1.marketValue } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: tokens.gap + 3) {
                    title
                    summary
                    HStack {
                        Text("真实持仓").font(.headline)
                        Spacer()
                        Text("\(holdings.count) 只").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 3)
                    if holdings.isEmpty {
                        ThemePanel {
                            Text("还没有真实 ETF 持仓。添加后会按真实份额、成本与行情展示。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else if theme == .bento || theme == .dashboard {
                        let pairs = holdings.chunkedPairs()
                        ForEach(pairs.indices, id: \.self) { index in
                            let pair = pairs[index]
                            HStack(alignment: .top, spacing: tokens.gap) {
                                ForEach(pair) { holding in holdingLink(holding) }
                                if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                            }
                        }
                    } else {
                        ForEach(holdings) { holding in holdingLink(holding) }
                    }
                    HStack(spacing: tokens.gap) {
                        NavigationLink { LabResearchView() } label: {
                            Label("AI 今日指导", systemImage: "sparkles")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).tint(tokens.accent)
                        NavigationLink { TradePlansView() } label: {
                            Label("我的手工计划", systemImage: "list.clipboard")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                    }.font(.caption.weight(.semibold))
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, tokens.pageInset)
                .padding(.top, 16).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .background(tokens.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var title: some View {
        ZStack(alignment: .leading) {
            if theme == .eastern || theme == .magazine {
                LandscapeDecoration(color: tokens.accent).frame(height: 83)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(theme == .magazine ? "我的投资组合" : "持仓")
                    .font(.system(size: theme == .magazine ? 31 : 28,
                                  weight: .bold, design: theme == .magazine ? .serif : .rounded))
                Text("只显示真实账户 · \(Date.now.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
    }

    private var summary: some View {
        ThemePanel(tone: theme == .dashboard ? tokens.surface : tokens.hero) {
            VStack(alignment: .leading, spacing: 10) {
                Label("持仓总览", systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                Text((value + store.data.cash).cny())
                    .font(.system(size: theme == .dashboard ? 30 : 34, weight: .bold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("持仓市值").font(.caption).foregroundStyle(.secondary)
                        Text(value.cny()).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("参考现金").font(.caption).foregroundStyle(.secondary)
                        Text(store.data.cash.cny()).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    private func holdingLink(_ holding: Holding) -> some View {
        NavigationLink { ProHoldingWorkspace(holding: holding) } label: {
            holdingCard(holding)
        }.buttonStyle(.plain)
    }

    private func holdingCard(_ holding: Holding) -> some View {
        let color = cardColor(holding)
        let displayCost = store.displayedCost(for: holding)
        let displayedPnL = (holding.current - displayCost) * holding.quantity
        let rounded = RoundedRectangle(cornerRadius: tokens.corner, style: .continuous)
        return ZStack(alignment: .bottomTrailing) {
            if theme == .eastern || theme == .magazine {
                LandscapeDecoration(color: color).frame(height: 150)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(holding.name).font(.subheadline.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(holding.code).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 1)
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
                }
                Text(holding.current.num(3))
                    .font(.title3.weight(.bold)).monospacedDigit()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("持有 \(holding.quantity.num(0)) 份")
                        Text("成本 \(displayCost.num(3))")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("持有 \(holding.quantity.num(0)) 份")
                        Text("成本 \(displayCost.num(3))")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Text("浮动盈亏 \(displayedPnL.cny())")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CardTone.pnl(displayedPnL) ?? .secondary)
                Text(holding.marketUpdatedAt.map {
                    "行情截至 \($0.formatted(date: .abbreviated, time: .shortened))"
                } ?? "行情时间待核实")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: theme == .bento ? 126 : 113, alignment: .leading)
            .padding(theme == .dashboard ? 13 : 16)
        }
        .background(rounded.fill(color.opacity(theme == .bento ? 0.25 : theme == .dashboard ? 0.17 : 0.10)))
        .overlay(rounded.strokeBorder(color.opacity(0.26), lineWidth: 1))
        .shadow(color: color.opacity(theme == .magazine ? 0.13 : 0.07), radius: 10, x: 0, y: 5)
    }

    private func cardColor(_ holding: Holding) -> Color {
        let palette: [Color] = [.blue, .mint, .purple, .orange, .pink]
        let index = holding.code.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
        return palette[index]
    }
}

private extension Array {
    func chunkedPairs() -> [[Element]] {
        stride(from: 0, to: count, by: 2).map {
            Array(self[$0..<Swift.min($0 + 2, count)])
        }
    }
}
