import SwiftUI

/// 「值不值得买」的六维雷达图。
///
/// 做成文件级 struct：GuanpanAdvisorApp.swift / LocalRuleViews.swift 里的页面已经足够深，
/// 再嵌一层闭包会触发 SwiftUI 类型检查超时，甚至让运行期的视图类型嵌套过深而闪退。
///
/// 画法：`Canvas` 画同心网格 + 轴线 + 数据多边形，六个轴的标题/分值用 `position`
/// 贴在每个轴的外侧。固定 300×300 的方框，半径和标签偏移都按这个尺寸算死，
/// 避免不同屏宽下标签被裁掉。

struct ScoreRadarChart: View {
    let dimensions: [NextScoreDimension]
    @Environment(\.gp) private var p

    private let side: CGFloat = 300
    /// 半径比边长一半再收 42，给外侧标签留出空间。
    private var radius: CGFloat { side / 2 - 42 }
    private let labelOffset: CGFloat = 20

    var body: some View {
        ZStack {
            if dimensions.count >= 3 {
                Canvas { context, _ in
                    draw(context: &context)
                }
                .frame(width: side, height: side)

                ForEach(dimensions.indices, id: \.self) { index in
                    let dim = dimensions[index]
                    let a = angle(index)
                    VStack(spacing: 0) {
                        Text(dim.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(p.ink)
                        Text("\(Int(dim.value.rounded()))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(dim.isEstimated ? p.muted : p.terracotta)
                    }
                    .fixedSize()
                    .position(x: side / 2 + cos(a) * (radius + labelOffset),
                              y: side / 2 + sin(a) * (radius + labelOffset))
                }
            }
        }
        .frame(width: side, height: side)
    }

    /// 第 index 个轴的角度（弧度）。index 0 在正上方，顺时针递增。
    ///
    /// 全程用 CGFloat：`cos`/`sin` 的 Double 重载会返回 Double，和 CGFloat 的
    /// `side`/`radius` 混在一起算，编译器要为这几种重载组合做指数级推断，
    /// 直接抛 "unable to type-check this expression in reasonable time"，
    /// 还会连锁报出一堆别的文件的假错误。
    private func angle(_ index: Int) -> CGFloat {
        let step = 360.0 / Double(dimensions.count)
        return CGFloat(-90.0 + step * Double(index)) * .pi / 180.0
    }

    /// 第 index 个轴在 fraction（0–1）处的坐标。
    private func vertex(_ index: Int, _ fraction: Double) -> CGPoint {
        let a = angle(index)
        return CGPoint(x: side / 2 + cos(a) * radius * CGFloat(fraction),
                       y: side / 2 + sin(a) * radius * CGFloat(fraction))
    }

    private func draw(context: inout GraphicsContext) {
        let count = dimensions.count
        for ring in [0.25, 0.5, 0.75, 1.0] {
            let ringWidth: CGFloat = ring == 1.0 ? 1.0 : 0.5
            var ringPath = Path()
            for index in 0..<count {
                let point = vertex(index, ring)
                if index == 0 { ringPath.move(to: point) } else { ringPath.addLine(to: point) }
            }
            ringPath.closeSubpath()
            context.stroke(ringPath, with: .color(p.line), lineWidth: ringWidth)
        }
        for index in 0..<count {
            var axis = Path()
            axis.move(to: CGPoint(x: side / 2, y: side / 2))
            axis.addLine(to: vertex(index, 1.0))
            context.stroke(axis, with: .color(p.line.opacity(0.55)), lineWidth: 0.5)
        }
        var shape = Path()
        for index in 0..<count {
            let point = vertex(index, max(0.05, min(1.0, dimensions[index].value / 100)))
            if index == 0 { shape.move(to: point) } else { shape.addLine(to: point) }
        }
        shape.closeSubpath()
        context.fill(shape, with: .color(p.terracotta.opacity(0.18)))
        context.stroke(shape, with: .color(p.terracotta), lineWidth: 1.6)
        for index in 0..<count {
            let point = vertex(index, max(0.05, min(1.0, dimensions[index].value / 100)))
            let dot = Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
            context.fill(dot, with: .color(p.terracotta))
        }
    }
}

/// 雷达六维的逐条明细：每条给出分值、横向比例条和人话依据。
/// 灰字 = 数据不足按中性处理，用户能看出哪一维是「估的」而不是「算的」。
struct ScoreRadarBreakdown: View {
    let dimensions: [NextScoreDimension]
    @Environment(\.gp) private var p

    var body: some View {
        VStack(spacing: 8) {
            ForEach(dimensions) { dim in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(dim.title).font(.caption.weight(.semibold)).foregroundStyle(p.ink)
                        Text("\(Int(dim.value.rounded()))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(dim.isEstimated ? p.muted : p.terracotta)
                        if dim.isEstimated {
                            Text("估算").font(.system(size: 9)).foregroundStyle(p.muted)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(p.muted.opacity(0.14), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(p.line.opacity(0.6)).frame(height: 4)
                            Capsule().fill(dim.isEstimated ? p.muted.opacity(0.5) : p.terracotta)
                                .frame(width: max(4, geo.size.width * CGFloat(min(1, dim.value / 100))), height: 4)
                        }
                    }
                    .frame(height: 4)
                    Text(dim.detail)
                        .font(.caption2).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 组合级雷达：把多只标的的同一维度取均值，看整体偏向（例如「股息普遍低、估值普遍贵」）。
/// 只对实际有分的标的求平均，缺维度的按各自 estimated 标记保留。
struct ScoreRadarPortfolioChart: View {
    let assessments: [NextWorthBuyAssessment]
    @Environment(\.gp) private var p

    private var averaged: [NextScoreDimension] {
        guard let first = assessments.first else { return [] }
        var result: [NextScoreDimension] = []
        for dim in first.dimensions {
            let values = assessments.compactMap { item in
                item.dimensions.first { $0.key == dim.key }?.value
            }
            guard !values.isEmpty else { continue }
            let mean = values.reduce(0, +) / Double(values.count)
            let estimated = assessments.contains { item in
                item.dimensions.first { $0.key == dim.key }?.isEstimated ?? true
            }
            result.append(NextScoreDimension(
                key: dim.key, title: dim.title, value: mean,
                detail: "\(assessments.count) 只标的的「\(dim.title)」均值",
                isEstimated: estimated))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 10) {
            if averaged.isEmpty {
                GPStatus(title: "还没有可汇总的评分", detail: "至少一只有分的标的才能算组合均值。", symbol: "chart.bar.doc.horizontal")
            } else {
                ScoreRadarChart(dimensions: averaged)
                Text("组合平均 · 按 \(assessments.count) 只有分标的的各维均值；灰色标签表示该维度在部分标的上数据不足。")
                    .font(.caption2).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
