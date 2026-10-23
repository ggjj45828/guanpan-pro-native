import Foundation

/// 「复盘」页的提示词构造器 —— 只负责**把本机算好的回放结果写成问句**。
///
/// 设计原则：
/// · **不把原始分时塞给模型**。几万条分钟线既超预算，也没必要 —— 模型要做的是
///   在已经算好的候选表里做取舍与解释，不是重算一遍回放（那是我这边的活，可复现）。
/// · **数字一律用本机口径的中文单位**，避免模型把「百分比」当成「元」。
/// · **明确禁止保证收益 / 无条件买卖指令**，并要求它在样本不足时直接说样本不足 ——
///   这里的样本量本来就小（区间常常只有十几二十天），不说清楚很容易被当成承诺。
enum GridReviewAdvisor {

    /// 区间（长期参数）模式的提示词。
    static func rangePrompt(report: GridRangeReport, history: [GridRangeReport],
                            profile: InvestmentProfile, dividendYield: Double? = nil) -> String {
        let digits = report.tick < 0.005 ? 3 : 2
        let top = report.candidates.prefix(6).map { item -> String in
            "格距 \(item.stepPercent.num(2))%：日均跑赢持有 \(item.averageAlpha.directionMark())\(item.averageAlpha.cny())，"
                + "跑赢 \(item.winDays)/\(item.samples) 天（\(item.winRate.num(1))%），"
                + "最差一天 \(item.worstAlpha.directionMark())\(item.worstAlpha.cny())，"
                + "最差单日回撤 \(item.worstDrawdown.num(2))%，日均成交 \(item.averageFills.num(1)) 笔，"
                + "区间费用合计 \(item.totalFees.cny())"
        }.joined(separator: "\n")

        let historyText: String
        if history.isEmpty {
            historyText = "（本机还没有其他区间记录）"
        } else {
            historyText = history.prefix(5).map { item in
                "\(item.from)→\(item.to)：\(item.days.count) 天，胜出格距 \(item.best.stepPercent.num(2))%，"
                    + "日均跑赢 \(item.best.averageAlpha.directionMark())\(item.best.averageAlpha.cny())，"
                    + "日均振幅 \(item.averageAmplitudePercent.num(2))%"
            }.joined(separator: "\n")
        }

        let skipped = report.skippedDays.isEmpty ? "无" : "\(report.skippedDays.count) 天（分时点不足或资金不够）"

        return """
        用户查看 \(report.name)（\(report.code)）的历史网格复盘。你只解释本机已经计算出的事后统计，不提供当前或未来的挂单参数。
        计划资金 \(report.capital.cny())，\(report.t0 ? "支持 T+0（当天买可当天卖）" : "T+1（当天买入的份额当天不能卖）")。
        用户投资画像：风格 \(profile.style)，风险偏好 \(profile.risk)，持有周期 \(profile.horizon)，单标的仓位上限 \(profile.maxPositionPercent.num(1))%，投资目标 \(profile.goal.isEmpty ? "未填写" : profile.goal)，回避项 \(profile.avoid.isEmpty ? "未填写" : profile.avoid)。
        \(dividendYield.map { yield in "该标的是红利/高股息品种（股息率约 \(yield.pct(2))%）。做网格赚的是价差波动，但价格下跌会抬高实际股息率、对攒股息更有利；若用户以收息为主，网格低吸也能顺带降低持仓成本、提高股息率。请结合这个视角；若高股息率来自股价跌出来的（股息陷阱），请提示风险。" } ?? "")

        复盘区间：\(report.from) → \(report.to)
        参与统计 \(report.days.count) 个交易日，被跳过 \(skipped)，有效分钟点合计 \(report.totalPoints) 个。
        区间价格：最低 \(report.rangeLow.num(digits))，最高 \(report.rangeHigh.num(digits))，
        首日首价 → 末日末价 \(report.rangeChangePercent.directionMark())\(report.rangeChangePercent.num(2))%，
        日均振幅 \(report.averageAmplitudePercent.num(2))%。

        候选格距（按「平均每天跑赢持有不动」排序，取前 6 组）：
        \(top)

        自动选出的胜出档位：格距 \(report.best.stepPercent.num(2))%，
        按最近一个交易日（\(report.days.last ?? "")）换算成绝对格距 \(report.best.lastStep.num(digits))、
        每格 \(report.best.lastQuantity.num(0)) 份。

        本机历史上跑过的其他区间：
        \(historyText)

        判定口径说明：所有数字来自本机分时档案的事后回放，「跑赢持有」= 网格盈亏 − 同一时点买入后什么都不做的盈亏；每天按当日首价重新铺一次网格；费用含佣金与一跳滑点。

        请只输出三段，用中文，每段 2–4 句：
        1. 解释候选表和历史样本中能观察到的差异。
        2. 指出事后拟合的局限及哪些行情变化会使历史统计失去参考价值。
        3. 说明还需要哪些真实数据才能由统一的 AI 今日指导评估当前计划。

        硬性要求：不得给当前/未来的具体挂单价格、份额或无条件买卖指令，不得保证收益；如果样本天数太少（比如少于 10 天）或区间涨跌几乎等于零，必须直接说样本不足，不要编造本机没有的数据。
        """
    }

    /// 单日（当日最优）模式的提示词。
    static func dayPrompt(report: GridOptimizeReport, name: String,
                          experience: GridExperienceRecord?, profile: InvestmentProfile, dividendYield: Double? = nil) -> String {
        let digits = report.tick < 0.005 ? 3 : 2
        let top = report.candidates.prefix(5).map { item -> String in
            "锚 \(item.anchor.num(digits)) / 格距 \(item.step.num(digits))（\(item.stepPercent.num(2))%）："
                + "买 \(item.buyCount) 卖 \(item.sellCount)，网格盈亏 \(item.profit.directionMark())\(item.profit.cny())，"
                + "持有不动 \(item.holdProfit.directionMark())\(item.holdProfit.cny())，"
                + "跑赢 \(item.alpha.directionMark())\(item.alpha.cny())，回撤 \(item.maxDrawdown.num(2))%"
        }.joined(separator: "\n")

        let experienceText: String
        if let experience, experience.samples > 0 {
            experienceText = "本机已对这个标的做过 \(experience.samples) 次单日复盘，"
                + "跑赢持有 \(experience.wins) 次（\(experience.winRate.num(1))%），"
                + "平均跑赢 \(experience.averageAlpha.cny())，中位格距 \(experience.medianStepPercent.num(2))%。"
        } else {
            experienceText = "（本机还没有对这个标的的单日复盘记录）"
        }

        let amplitude = report.firstPrice > 0
            ? (report.dayHigh - report.dayLow) / report.firstPrice * 100
            : 0

        return """
        用户查看 \(name)（\(report.code)）\(report.day) 的历史网格复盘。

        计划资金 \(report.capital.cny())，\(report.t0 ? "支持 T+0" : "T+1（当天买入的份额当天不能卖）")。
        当日走势：首价 \(report.firstPrice.num(digits))，末价 \(report.lastPrice.num(digits))，
        最低 \(report.dayLow.num(digits))，最高 \(report.dayHigh.num(digits))，振幅 \(amplitude.num(2))%，
        有效分钟点 \(report.points) 个。

        事后最优参数：锚点 \(report.best.anchor.num(digits))，格距 \(report.best.step.num(digits))（\(report.best.stepPercent.num(2))%），
        每格 \(report.best.quantity.num(0)) 份，买 \(report.best.buyCount) 笔 / 卖 \(report.best.sellCount) 笔，
        费用合计 \(report.best.fees.cny())，网格盈亏 \(report.best.profit.directionMark())\(report.best.profit.cny())，
        持有不动 \(report.best.holdProfit.directionMark())\(report.best.holdProfit.cny())，
        跑赢 \(report.best.alpha.directionMark())\(report.best.alpha.cny())，最大回撤 \(report.best.maxDrawdown.num(2))%。

        候选（前 5 组，按「跑赢持有」排序）：
        \(top)

        \(experienceText)
        用户投资画像：风格 \(profile.style)，风险偏好 \(profile.risk)，持有周期 \(profile.horizon)，单标的仓位上限 \(profile.maxPositionPercent.num(1))%。
        \(dividendYield.map { yield in "该标的是红利/高股息品种（股息率约 \(yield.pct(2))%）。做网格赚的是价差波动，但价格下跌会抬高实际股息率、对攒股息更有利；若用户以收息为主，网格低吸也能顺带降低持仓成本、提高股息率。请结合这个视角；若高股息率来自股价跌出来的（股息陷阱），请提示风险。" } ?? "")

        判定口径：「跑赢持有」= 网格盈亏 − 同一时点买入后什么都不做的盈亏；这是事后拟合，用的是当天已经走完的完整分时。

        请只输出三段，中文，每段 2–4 句：
        1. 解释这一天候选参数表现不同的历史原因。
        2. 明确指出单日样本不足，不能据此推导当前或未来的挂单价格。
        3. 说明要扩大历史样本，应继续核对哪些数据和区间。

        硬性要求：不得给当前/未来的具体挂单价格、份额或无条件买卖指令，不得保证收益；不得编造本机没有的数据（比如盘口、新闻、成交量）。
        """
    }
}
