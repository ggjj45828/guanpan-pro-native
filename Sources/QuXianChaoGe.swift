import Foundation

// MARK: - 曲线超哥交易方法体系（大模型知识库版）
//
// 来源：桌面《曲线超哥交易方法体系_大模型知识库版.docx》（2026-11-09 版，主体 16 章）。
// 本文件只做三件事：结构化知识库、A/B 加仓条件检查、仓位状态机与纪律清单。
//
// 治理约束（逐条对齐文档「明确禁止误归因事项」）：
//   · 只解释方法、检索证据、形成条件计划；不产生买卖信号，不做评分、排名、评级。
//   · 每段内容保留五级归因；缺失写「未知」，不填 0、不按常见技术分析补齐作者规则。
//   · A 与 B 是「或」关系（满足其一才考虑加仓），界面与文案都不得写成「并且」。
//   · 四指数不创新低的计算细则、明显放量阈值，作者没给完整算法 ——
//     全部按软件口径显式标注、参数可调，并明确写「这不是作者原话」。
//   · 120 分钟 MACD 归「用户独立研究」，任何位置都不得归因作者。
//
// 数据依赖：B 条件需要指数归档日 K，走 GuanpanMaxNAS.indexDailyBars（F 版 NAS 契约）。
// 取不到就是「未知」——绝不用别的指数的数据顶替，也不把缺 OHLC 的收盘价说成最低价。

enum QuXianChaoGe {

    // MARK: - 五级归因

    enum Attribution: String, CaseIterable, Identifiable {
        case authorMethod = "作者方法"
        case authorCase = "作者自述案例"
        case softwareRule = "软件量化建议"
        case userResearch = "用户独立研究"
        case unconfirmed = "未确认"

        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .authorMethod: return "字幕中明确表达或跨作品重复的思想；仍须区分单次情境参数与通用思想。"
            case .authorCase: return "只证明作者这样说过，不证明真实成交或账户收益。"
            case .softwareRule: return "为可计算性提出的研究方案，不能倒写为作者原话。"
            case .userResearch: return "用户自己的研究（含 120 分钟 MACD），不归因作者。"
            case .unconfirmed: return "OCR 缺句、图形缺失、统计口径或发布时间未认证。"
            }
        }
    }

    // MARK: - 知识库

    struct Paragraph: Identifiable {
        let id: Int
        /// nil 表示这一句是使用说明/流程模板，本身不承载归因。
        let attribution: Attribution?
        let text: String
    }

    struct Chapter: Identifiable {
        let id: Int
        let title: String
        let paragraphs: [Paragraph]
    }

    static let chapters: [Chapter] = makeChapters()

    private static func makeChapters() -> [Chapter] {
        var chapterIndex = 0
        func chapter(_ title: String, _ rows: [(Attribution?, String)]) -> Chapter {
            chapterIndex += 1
            var paragraphIndex = 0
            let paragraphs = rows.map { row -> Paragraph in
                paragraphIndex += 1
                return Paragraph(id: chapterIndex * 100 + paragraphIndex,
                                 attribution: row.0,
                                 text: row.1)
            }
            return Chapter(id: chapterIndex, title: title, paragraphs: paragraphs)
        }
        return [
            chapter("使用说明与证据等级", [
                (nil, "本知识库用于解释交易方法、检索证据和形成条件计划，不把作者经验自动视为已验证策略。每条输出必须保留归因类别、时间和不确定性。正文是导读，附录是可检索证据层；发生歧义时回查附录，不按常见技术分析知识补齐作者规则。"),
                (nil, "①作者方法：字幕中明确表达或跨作品重复的思想，仍须区分单次情境参数与通用思想。②作者自述案例：只证明作者这样说过，不证明真实成交或账户收益。③软件量化建议：研究者为可计算性提出，不能倒写为原话。④用户独立研究：包括 120 分钟 MACD，不归因作者。⑤未确认：OCR 缺句、图形缺失、统计口径和发布时间未认证等。"),
                (nil, "证据强度另行分层：原视频与平台时间核实最高；现有录屏字幕与内容匹配为中间层；对话摘要、软件截图解读和研究推断为二级材料。当前 90 条作品为内容及序列匹配候选，非逐条平台认证；字幕不是逐字听审口播。附录保留 OCR 待核标签。")
            ]),
            chapter("总交易框架", [
                (.authorMethod, "优先判断市场整体，再看板块和个体；结合量价、市场宽度、结构与风险位置决定参与力度。核心不是固定预测每天涨跌，而是等待条件、试错、确认、调整仓位。"),
                (.softwareRule, "把市场环境、触发条件、买点、仓位状态和退出规则分开记录。条件成立不等于一定上涨，市场级加仓条件不等于任意证券买点。")
            ]),
            chapter("市场环境 成交额 市场宽度与赚钱效应", [
                (.authorMethod, "以主要指数和市场整体量能观察大概率方向，不能只盯持仓。关注普涨、极端下跌、板块持续性及主线；弱势中注意 ETF 与有资金介入的逆势强势品种，但排除脉冲上涨。具体作品证据见附录相关段。"),
                (.authorMethod, "成交额必须区分全天总额、较前日增额和盘中同时间比较。正常上涨偏好温和均匀放量；启动第一天可有不同容忍度。前段突然放量而后段跟不上，与全天较前放量可以同时存在。"),
                (.softwareRule, "记录上涨下跌平盘、±3% 和 ±5% 家数、平均及中位涨跌幅、涨跌停可靠性、有效样本和覆盖率；对上一快照比较变化。上涨家数仍多但持续减少，应描述为宽度偏强但恶化。赚钱效应不能仅由指数红绿推断。")
            ]),
            chapter("A与B加仓条件及共振磨底", [
                (.authorMethod, "A 为单日明显放量；B 为上证、深成指、创业板、科创板四指数同时连续 3 交易日不创新低；A OR B，满足其一才考虑加仓，并非必须同时满足。两者共同成立可增强参与意愿。"),
                (.unconfirmed, "情境参数：目录 12 提到放量 2000 亿元以上，较早作品出现超过 10%；比较基准须核对。目录 11 字幕为超过 2 万亿，不能偷偷改成 2000 亿，也不能混同总额和增额。不是任何向下放巨量都无条件重仓；若同时打破新低，B 已失效。"),
                (.unconfirmed, "科创板指数的作者口语与软件科创 50 代理须分列，代理是否等同原口径未确认。软件必须确定最低价或收盘价、锚点、相等处理、交易日窗口和首次触发去重规则；这些细节不是作者已给完整算法。"),
                (.authorMethod, "共振强调多个代表性指数同步企稳，先止跌的指数可能等待较弱指数。磨底可持续较久，不能因单一指数短暂稳定宣布全市场反转。"),
                (.softwareRule, "盘中 B 只能是候选，收盘后才按指定口径确认。")
            ]),
            chapter("三个买点", [
                (.authorMethod, "目录 61：左侧为连续回调后的加速下杀和恐慌释放；右侧为阳线反包等确认；第三类是行情确认后的回踩，关键分割位置守住并出现短线确认信号。"),
                (.authorMethod, "左侧需要恐慌背景，不是见跌就买；右侧可反包一根中阴线或此前 2 至 3 根小阴线的累计下跌；回踩不能仅靠价格回落判定便宜，还要防止出货与结构失效。"),
                (.softwareRule, "三类独立建模，分别记录背景、触发、失效、证据、试错风险。极端家数和跌幅阈值应按具体作品和当时证券数量保留，不擅自统一成永久规则。")
            ]),
            chapter("MACD 与反弹反转", [
                (.authorMethod, "目录 52：水上金叉偏原趋势延续优势，水下金叉偏成本优势，不能保证反转。观察金叉后红柱增长速度、长度和持续时间，并结合价格结构。绿柱变化等细节应回查字幕，不能自行补成固定柱数算法。"),
                (.authorMethod, "目录 75 讨论月线死叉后的赚钱难度与震荡机会，承认滞后性；不能转写为当日机械清仓。11 月初加仓链不能直接归因 MACD。"),
                (.userResearch, "120 分钟 MACD 必须单独标记，现有证据不能证明是作者规则。没有已确认统一 MACD 参数、固定金叉胜率或红绿柱阈值。")
            ]),
            chapter("均线与适配均线", [
                (.authorMethod, "单选参考均线时偏好 20 日均线，讨论其拐头变化及趋势跟随，同时指出短均线敏感和震荡磨损等问题。此教学示例不是适用于所有标的的固定买卖法。"),
                (.softwareRule, "适配均线可作为研究模块，参数只能用当时以前数据选择，预留样本外检验。不得把全历史挑出的最佳均线回填过去，也不能把软件寻优周期声称为作者固定标准。")
            ]),
            chapter("黄金分割 时空量与洗盘出货", [
                (.authorMethod, "使用 0.382 与 0.618，简化为 40% 与 60%。结合前段回调深度、随后修复幅度、相应时间与成交量判断反弹能否走向反转。字幕表达为回调超过 40% 后反转难度增加；若回调一个月，后续上涨一个月仍未修复前段跌幅 60%，反转概率降低；后段量能最好超过前段。"),
                (.softwareRule, "回调深度和修复比例必须分清分母，保留波段起止点和选点算法。不能把修复 60% 写成价格上涨 60%，也不能把 40% 当成通用止损。"),
                (.authorMethod, "洗盘与出货结合位置、K 线组合和量价。目录 83 提到启动初期或上涨中段的洗盘、较高累计涨幅后的出货嫌疑；重阴吞没、放量冲高回落等需警惕，缩量半吞没和随后小阴小阳可有不同含义。字幕中的一般股约 30%、热门品种 50% 至一倍等只是经验情境，不能据此给任何股票判定主力真实意图。")
            ]),
            chapter("阴线买点 旱地拔葱与仙人指路", [
                (.unconfirmed, "高胜率是作者经验表述，不是本知识库认证胜率。缩量阴线与放量阴线要分别回查对应作品的趋势背景、位置与确认；不得把所有阴线通称买点，尤其不能将放量破位自动解释成吸筹。完整字幕保留于附录。"),
                (.authorMethod, "旱地拔葱：原均线粘合、区间震荡，中阳线从均线下方开盘至上方收盘，放量并突破原区间更具代表性。均线集合和粘合阈值尚需量化定义。"),
                (.authorMethod, "仙人指路：均线向上发散，刚开始发散更佳；冲高回落形成较长上影的小阳线，收盘仍在均线上方及原区间上沿之上。不能只凭长上影认定，需区别高位放量滞涨与出货嫌疑。")
            ]),
            chapter("全市场选股与候选池", [
                (.authorMethod, "每天翻涨幅榜前约 200 名，时间有限可看 100 名，记录强势品种共同特征，再寻找类似机会；结合跌幅榜和板块赚钱效应观察风险及资金方向。避免脉冲式上涨，关注持续介入痕迹，详见附录。"),
                (.softwareRule, "软件候选不等于作者推荐。对话中 Scanner V0 的 73 只仅为软件趋势候选；清源股份五日约 19.78%、三棵树约 19.75%、锐科激光约 17.64% 是截图解读，不是作者选股或最新行情。评分偏近期涨幅会偏向已涨较多品种，必须另评回踩、缩量阴线、右侧确认和风险位置。")
            ]),
            chapter("仓位状态机 回撤控制与退出", [
                (.authorMethod, "轻仓试探、重仓确认；信号不明保留子弹，连续亏损时大幅降低仓位；买入前考虑止损，不在亏损后临时编理由。减仓可为兑现、应对轮动和外围风险，不必等于全面看空。"),
                (.softwareRule, "状态机为观察→轻仓试探→确认→加仓→重仓确认→持有→减仓→退出。允许失败后回到观察、减仓或退出，不强制逐级上行。每次转移记录条件、证据、风险预算与失效线。此完整状态机是整理方案，不是作者逐字制定的八阶段算法。"),
                (.authorMethod, "止损与动态退出：事先记录结构失效、量价恶化和个人可承受损失；随着行情更新，不把浮亏后加仓摊成本自动合理化。"),
                (.unconfirmed, "没有统一固定仓位比例、统一止盈百分比或已核实最大回撤约束。满仓是作者交易资金口语，不证明投入全部家庭资产。")
            ]),
            chapter("规则意识与概率思维", [
                (.authorMethod, "有信号行动，无信号克制；按条件执行并允许修正，看错后调整。交易要在个人可掌控资金与波动范围内，避免因贪婪或不甘把试错变成失控。"),
                (.unconfirmed, "概率不是保证。作者提到 80% 或 90% 等比例应保留为作者主张，必须追问事件定义、样本、期限、收益和失败分布；方法适合作者不证明适合每个人。")
            ]),
            chapter("作者没有明确给出的内容", [
                (.unconfirmed, "没有已确认统一固定仓位比例；没有统一止盈百分比；没有完整固定选股评分公式；没有证据证明 120 分钟 MACD 是作者规则。"),
                (.unconfirmed, "还缺统一的明显放量阈值、四指数不创新低完整计算细则、科创指数代理映射、固定适配均线公式、MACD 柱长和持续时间数字、所有买点统一失效算法、真实账户流水和可复算净值。没有找到与尚未取得证据必须区别表述，不能断言作者从未在任何作品说过。")
            ]),
            chapter("历史验证与反未来函数", [
                (.unconfirmed, "对话记录的当前软件定义下，四指数连续 3 日不创新低 132 次触发；未来 1、3、5、10、20 交易日上涨率约 45.5%、53.0%、52.3%、56.8%、53.0%。这是对话转述的历史统计，不是本次重算；平均收益仅描述为较弱，缺精确值，不补造。"),
                (.unconfirmed, "该统计为全历史首次触发口径，尚非样本外；标的收益映射、区间、费用、重叠样本、置信区间等未齐。不能据此直接否定作者，也不能声称支持 80% 以上；应先对齐原口径并做前向验证。"),
                (.softwareRule, "反未来函数：在决策时刻只用已公开证据和已完成 K 线；盘中数据标 provisional，收盘结果标 close；不得回填事后低点、事后最佳均线、未来成分或后发视频。使用当时证券池与可交易价格，考虑停牌涨跌停、费用和滑点。")
            ]),
            chapter("大模型决策流程与结构化模板", [
                (nil, "流程：识别任务时间→检查来源与数据质量→分离作者方法及研究建议→判断市场环境和宽度趋势→分别检查 A 与 B→检查三类买点及失效条件→评估个体风险位置→提出条件计划→记录风险与缺失证据。没有条件时输出观察，不用叙事强行凑信号。"),
                (nil, "输出字段建议：分析时刻；行情截至时刻；盘中或收盘；证券及指数映射；来源清单；证据类别；作者原意摘要；软件计算定义及版本；A 成立或不成立或未知；B 四指数逐项天数；A OR B 结果；宽度状态及趋势；买点类型；反弹或反转及理由；当前状态；条件动作；失效条件；风险预算；未确认事项；后续核验。"),
                (nil, "案例检索输出另加：作品候选日期、目录编号、录屏时间、链接、事前计划或盘中披露或事后解释、自述动作、行情独立核验状态。缺失写未知，不填 0。")
            ]),
            chapter("明确禁止误归因事项", [
                (nil, "禁止把软件参数、评分、状态机、120 分钟 MACD 归因作者；禁止把自述收益当审计收益；禁止把候选日期当平台认证；禁止把 OCR 待核当可靠逐字引文；禁止把后验解释当事前预测。"),
                (nil, "禁止把 A OR B 写成 A AND B，或把四指数同时满足写成任一满足；禁止混同成交总额和增额；禁止把软件候选当作者推荐；禁止把盘中状态冒称收盘确认；禁止把部分市场宽度冒称完整全市场；禁止凭常见形态定义补齐缺失作者规则。")
            ])
        ]
    }

    /// 只保留已完成交易日的 bar。
    ///
    /// 反未来函数要求：决策时刻只能用已完成 K 线。腾讯日线兜底会把今天那根
    /// 还没收盘的 K 线也返回（科创 50 实测最后一条就是当天），所以统一按
    /// 「交易日严格早于今天（Asia/Shanghai）」过滤 —— 与 NAS 归档侧口径一致，
    /// 四个指数才在同一时间截面上比较。收盘后当天仍然不进，宁可晚一天，不提前确认。
    static func completedSessionsOnly(_ bars: [GuanpanMaxNAS.IndexDailyBar],
                                      now: Date = .now) -> [GuanpanMaxNAS.IndexDailyBar] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let y = parts.year, let m = parts.month, let d = parts.day else { return bars }
        let todayText = String(format: "%04d-%02d-%02d", y, m, d)
        return bars.filter { $0.tradingDate < todayText }
    }

    // MARK: - B 条件（四指数连续 N 日不创新低）

    /// 作者口语里的「科创板」在软件里只能用科创 50（sh000688）代理，且代理关系未确认。
    struct BRequirement: Identifiable {
        let indexCode: String
        let displayName: String
        let roleNote: String
        var id: String { indexCode }
    }

    static let bRequirements: [BRequirement] = [
        BRequirement(indexCode: "sh000001", displayName: "上证指数", roleNote: "作者口径：上证"),
        BRequirement(indexCode: "sz399001", displayName: "深证成指", roleNote: "作者口径：深成指"),
        BRequirement(indexCode: "sz399006", displayName: "创业板指", roleNote: "作者口径：创业板"),
        BRequirement(indexCode: "sh000688", displayName: "科创 50",
                     roleNote: "作者口语是「科创板」；软件用科创 50 代理，是否等同原口径未确认")
    ]

    enum ConditionVerdict: String {
        case satisfied = "成立"
        case unsatisfied = "不成立"
        case unknown = "未知"
    }

    struct BInput {
        let requirement: BRequirement
        /// nil = 这次没取到（失败原因见 failure），不等于「不成立」。
        let bars: [GuanpanMaxNAS.IndexDailyBar]?
        let failure: String?
        /// 数据来源，逐项标注：NAS 归档 / 本机日线兜底。取不到时写失败原因。
        let dataSource: String
    }

    struct BReading: Identifiable {
        let indexCode: String
        let displayName: String
        let roleNote: String
        let tradingDays: Int
        /// 从最近一个已完成交易日向前数，连续未创新低的天数。
        let streak: Int
        /// 这一项实际用到的最新交易日 —— 四个指数可能不同，必须逐项写出来。
        let lastSession: String
        let latestNewLowDate: String?
        /// 「最低价」或「收盘价（该指数归档缺 OHLC）」——口径必须写清。
        let priceBasis: String
        let verdict: ConditionVerdict
        let reason: String
        let dataSource: String
        var id: String { indexCode }
    }

    struct BConditionResult {
        let readings: [BReading]
        let verdict: ConditionVerdict
        let asOfSession: String?
        let window: Int
        let required: Int
        let definitionNote: String
    }

    /// 软件口径（作者未给完整算法，这里全部显式写出并允许改参数）：
    /// · 只用已完成交易日；盘中数据不参与确认。
    /// · 逐日判断「创新低」：当日口径价 **严格小于** 此前 `window` 个交易日的最小值。
    ///   相等不算创新低（这是软件选择，不是作者规则）。
    /// · 「连续 N 日不创新低」= 从最近一日向前数，连续 N 个交易日都未创新低。
    /// · 四指数必须全部成立才算 B 成立；任一指数取不到数据 → B 为未知，不拿别的指数顶替。
    static func evaluateB(_ inputs: [BInput],
                          window: Int = 20,
                          required: Int = 3,
                          now: Date = .now) -> BConditionResult {
        var readings: [BReading] = []
        readings.reserveCapacity(inputs.count)
        let need = max(window, 1) + max(required, 1)

        // 先把每个来源都裁到「已完成交易日」，再取共同截止日。
        // 四个来源的最新交易日经常不同（NAS 归档慢一天、腾讯兜底有当天），
        // 若各算各的，「四指数同时」就变成四天拼在一起的结论 —— 那是假的。
        let prepared: [(BInput, [GuanpanMaxNAS.IndexDailyBar])] = inputs.map { input in
            (input, input.bars.map { completedSessionsOnly($0, now: now) } ?? [])
        }
        let availableLast = prepared.compactMap { $0.1.last?.tradingDate }.min()
        let cutoff = availableLast ?? ""

        for (input, rawBars) in prepared {
            let req = input.requirement
            let bars = cutoff.isEmpty ? rawBars : rawBars.filter { $0.tradingDate <= cutoff }
            guard !bars.isEmpty else {
                readings.append(BReading(indexCode: req.indexCode,
                                         displayName: req.displayName,
                                         roleNote: req.roleNote,
                                         tradingDays: 0,
                                         streak: 0,
                                         lastSession: "—",
                                         latestNewLowDate: nil,
                                         priceBasis: "—",
                                         verdict: .unknown,
                                         reason: input.failure ?? "未取到该指数的归档日 K",
                                         dataSource: input.dataSource))
                continue
            }
            guard bars.count >= need else {
                readings.append(BReading(indexCode: req.indexCode,
                                         displayName: req.displayName,
                                         roleNote: req.roleNote,
                                         tradingDays: bars.count,
                                         streak: 0,
                                         lastSession: bars.last?.tradingDate ?? "—",
                                         latestNewLowDate: nil,
                                         priceBasis: "—",
                                         verdict: .unknown,
                                         reason: "样本不足：只有 \(bars.count) 个交易日，至少需要 \(need) 个",
                                         dataSource: input.dataSource))
                continue
            }

            // 口径只选一次：全部 bar 都有最低价才用最低价，否则整条序列退回收盘价并显式标注。
            let useLow = bars.allSatisfy { $0.low != nil }
            let prices = bars.map { useLow ? ($0.low ?? $0.close) : $0.close }

            var streak = 0
            var latestNewLow: String?
            var index = prices.count - 1
            while index >= window {
                let anchor = prices[(index - window)..<index].min() ?? prices[index]
                if prices[index] < anchor {
                    latestNewLow = bars[index].tradingDate
                    break
                }
                streak += 1
                index -= 1
            }

            let verdict: ConditionVerdict = streak >= required ? .satisfied : .unsatisfied
            let reason: String
            if verdict == .satisfied {
                reason = "最近 \(streak) 个已完成交易日未创 \(window) 日新低"
            } else if let latestNewLow {
                reason = "\(latestNewLow) 创出 \(window) 日新低，连续不创新低中断"
            } else {
                reason = "连续不创新低仅 \(streak) 日，未达 \(required) 日"
            }
            readings.append(BReading(indexCode: req.indexCode,
                                     displayName: req.displayName,
                                     roleNote: req.roleNote,
                                     tradingDays: bars.count,
                                     streak: streak,
                                     lastSession: bars.last?.tradingDate ?? "—",
                                     latestNewLowDate: latestNewLow,
                                     priceBasis: useLow ? "最低价" : "收盘价（该指数归档缺 OHLC）",
                                     verdict: verdict,
                                     reason: reason,
                                     dataSource: input.dataSource))
        }

        let verdict: ConditionVerdict
        if readings.contains(where: { $0.verdict == .unknown }) {
            verdict = .unknown
        } else if readings.allSatisfy({ $0.verdict == .satisfied }) {
            verdict = .satisfied
        } else {
            verdict = .unsatisfied
        }
        // 四个来源的最近交易日可能不同（NAS 归档更新慢、腾讯兜底更新快）。
        // 这里取「共同截面」里最早的那天：宁可显示早一天，也不让人误以为
        // 四个指数是在同一天都比较过 —— 逐项真实日期在 readings.lastSession 里。
        let asOf = readings.compactMap { $0.lastSession == "—" ? nil : $0.lastSession }.min()
        let definitionNote = "软件口径（作者未给完整算法）：逐日比较当日口径价与此前 \(window) 个已完成交易日的最低值，严格小于才算创新低；连续 \(required) 个交易日都不创新低才算成立；盘中不算确认；四指数必须全部成立。"
        return BConditionResult(readings: readings,
                                verdict: verdict,
                                asOfSession: asOf,
                                window: window,
                                required: required,
                                definitionNote: definitionNote)
    }

    // MARK: - A 条件（单日明显放量）

    /// 作者在不同作品里给过三种情境参数，软件不擅自统一，由使用者选口径。
    enum ACaliber: String, CaseIterable, Identifiable {
        case total2000 = "单日成交额 ≥ 2000 亿元"
        case total20000 = "单日成交额 ≥ 2 万亿元"
        case increase10 = "较前一交易日增额 ≥ 10%"

        var id: String { rawValue }

        var sourceNote: String {
            switch self {
            case .total2000: return "目录 12 的情境参数；比较基准须核对，不等于长期阈值。"
            case .total20000: return "目录 11 字幕口径「超过 2 万亿」；不能与 2000 亿混用。"
            case .increase10: return "较早作品出现的「较前放量 10%」；是增额口径，不是总额口径。"
            }
        }

        /// 单位：亿元。
        var thresholdYi: Double? {
            switch self {
            case .total2000: return 2000
            case .total20000: return 20000
            case .increase10: return nil
            }
        }
    }

    struct AConditionResult {
        let verdict: ConditionVerdict
        let detail: String
        let caliberNote: String
    }

    /// 全市场成交额本机没有可信数据源，因此 A 只做「你录入 + 软件比较」，不替用户猜数。
    static func evaluateA(caliber: ACaliber?,
                          todayAmountYi: Double?,
                          previousAmountYi: Double?) -> AConditionResult {
        guard let caliber else {
            return AConditionResult(verdict: .unknown,
                                    detail: "未选择放量口径：作者给过 2000 亿、2 万亿、较前日增额 10% 等情境参数，软件不擅自统一。",
                                    caliberNote: "口径未确定 → A 记为未知（不填 0、不猜成不成立）")
        }
        guard let today = todayAmountYi, today > 0 else {
            return AConditionResult(verdict: .unknown,
                                    detail: "缺少当日全市场成交额，无法判定。",
                                    caliberNote: caliber.sourceNote)
        }
        switch caliber {
        case .total2000, .total20000:
            guard let threshold = caliber.thresholdYi else {
                return AConditionResult(verdict: .unknown, detail: "口径阈值缺失。", caliberNote: caliber.sourceNote)
            }
            let ok = today >= threshold
            let detail = "今日 \(number(today)) 亿元 / 阈值 \(number(threshold)) 亿元"
            return AConditionResult(verdict: ok ? .satisfied : .unsatisfied,
                                    detail: detail,
                                    caliberNote: caliber.sourceNote)
        case .increase10:
            guard let previous = previousAmountYi, previous > 0 else {
                return AConditionResult(verdict: .unknown,
                                        detail: "判定增额需要前一交易日的全市场成交额。",
                                        caliberNote: caliber.sourceNote)
            }
            let ratio = (today - previous) / previous
            let ok = ratio >= 0.10
            let detail = "今日 \(number(today)) 亿元 / 前日 \(number(previous)) 亿元 = \(number(ratio * 100))%"
            return AConditionResult(verdict: ok ? .satisfied : .unsatisfied,
                                    detail: detail,
                                    caliberNote: caliber.sourceNote)
        }
    }

    // MARK: - A OR B 合成

    enum ABVerdict {
        case atLeastOneSatisfied
        case noneSatisfied
        case unknown

        var title: String {
            switch self {
            case .atLeastOneSatisfied: return "A 或 B 至少一项成立"
            case .noneSatisfied: return "A 与 B 都不成立"
            case .unknown: return "存在未知项，不能判定"
            }
        }

        var detail: String {
            switch self {
            case .atLeastOneSatisfied:
                return "按作者方法，此时才进入「考虑加仓」环节。这不等于买入信号：还要过三个买点、失效条件与风险预算。"
            case .noneSatisfied:
                return "按作者方法应继续观察或保持轻仓，不用叙事强行凑信号。"
            case .unknown:
                return "未知按「不成立」处理，不能因为其他项成立就当作已确认；先补齐数据再判。"
            }
        }
    }

    /// 或关系：任一项成立即成立（另一项未知不影响）；两项都不成立才不成立；否则未知。
    static func combine(a: ConditionVerdict, b: ConditionVerdict) -> ABVerdict {
        if a == .satisfied || b == .satisfied { return .atLeastOneSatisfied }
        if a == .unsatisfied && b == .unsatisfied { return .noneSatisfied }
        return .unknown
    }

    // MARK: - 三个买点

    struct BuyPoint: Identifiable {
        let id: Int
        let title: String
        let background: String
        let trigger: String
        let invalidation: String
        let evidence: String
        let risk: String
    }

    static let buyPoints: [BuyPoint] = [
        BuyPoint(id: 1, title: "左侧：恐慌加速下杀",
                 background: "连续回调之后出现加速下杀，情绪集中释放；不是「见跌就买」。",
                 trigger: "需要恐慌背景：跌幅加速、极端家数明显放大；作者未给统一的跌幅与家数阈值。",
                 invalidation: "继续放量破位、结构低点被有效跌破；具体失效算法作者未统一给出。",
                 evidence: "作者方法（目录 61）+ 软件量化建议（三类独立建模）",
                 risk: "左侧试错风险最高，按轻仓试探处理，不在确认前加仓。"),
        BuyPoint(id: 2, title: "右侧：阳线反包",
                 background: "下跌后出现阳线反包等确认信号，属于右侧。",
                 trigger: "可反包一根中阴线，或反包此前 2 至 3 根小阴线的累计跌幅。",
                 invalidation: "反包失败、再度收于反包阳线之下；量能没有跟上。",
                 evidence: "作者方法（目录 61）",
                 risk: "右侧确认度更高但位置更高，需要接受买贵一点的代价。"),
        BuyPoint(id: 3, title: "确认后回踩关键分割",
                 background: "行情已经确认，回踩到关键分割位置守住并出现短线确认。",
                 trigger: "关键分割位置（0.382 / 0.618，简化为 40% / 60%）守住 + 短线确认信号。",
                 invalidation: "回踩跌穿关键分割并放量，或结构失效；防止把出货当洗盘。",
                 evidence: "作者方法（目录 61、黄金分割章）",
                 risk: "不能仅靠价格回落判定便宜；分母（波段起止点）要写清。")
    ]

    // MARK: - 仓位状态机

    enum PositionState: String, CaseIterable, Identifiable, Codable {
        case observe = "观察"
        case probe = "轻仓试探"
        case confirm = "确认"
        case add = "加仓"
        case heavy = "重仓确认"
        case hold = "持有"
        case reduce = "减仓"
        case exit = "退出"

        var id: String { rawValue }

        var guidance: String {
            switch self {
            case .observe: return "没有信号就克制，保留子弹。"
            case .probe: return "轻仓试探，先想好失效线。"
            case .confirm: return "条件被确认后才提高参与力度。"
            case .add: return "加仓需新的条件与风险预算，不为摊成本而加。"
            case .heavy: return "重仓是作者交易资金口径，不等于投入全部家庭资产。"
            case .hold: return "持有期间持续核对失效条件是否被触发。"
            case .reduce: return "减仓可为兑现、应对轮动或外围风险，不必等于全面看空。"
            case .exit: return "退出后回到观察，不因不甘立刻反手。"
            }
        }

        /// 允许的下一跳：允许失败后回退，不强制逐级上行。
        var allowedNext: [PositionState] {
            switch self {
            case .observe: return [.probe, .exit]
            case .probe: return [.confirm, .add, .observe, .reduce, .exit]
            case .confirm: return [.add, .hold, .probe, .reduce, .exit]
            case .add: return [.heavy, .hold, .confirm, .reduce, .exit]
            case .heavy: return [.hold, .reduce, .exit]
            case .hold: return [.add, .reduce, .exit]
            case .reduce: return [.observe, .probe, .exit]
            case .exit: return [.observe]
            }
        }
    }

    struct PositionTransition: Codable, Identifiable {
        var id: UUID = UUID()
        var stamp: Date = .now
        var from: String
        var to: String
        var condition: String = ""
        var evidence: String = ""
        var riskBudget: String = ""
        var invalidation: String = ""
    }

    /// 本机记录，不联网、不上传。只记「为什么转移」，不记盈亏预测。
    enum PositionJournal {
        static let storageKey = "guanpan.pro.quxianchaoge.position.transitions"
        static let maximumRows = 200

        static func load() -> [PositionTransition] {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let rows = try? JSONDecoder().decode([PositionTransition].self, from: data) else {
                return []
            }
            return rows
        }

        static func save(_ rows: [PositionTransition]) {
            guard let data = try? JSONEncoder().encode(rows) else { return }
            UserDefaults.standard.set(data, forKey: storageKey)
        }

        static func append(_ transition: PositionTransition) {
            var rows = load()
            rows.append(transition)
            save(Array(rows.suffix(maximumRows)))
        }

        static func currentState() -> PositionState {
            guard let last = load().last,
                  let state = PositionState(rawValue: last.to) else { return .observe }
            return state
        }

        static func clear() {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }

    // MARK: - 纪律与已知缺口

    static let forbiddenMisattributions: [String] = [
        "不把软件参数、评分、状态机、120 分钟 MACD 归因作者。",
        "不把作者自述收益当审计收益，不把候选日期当平台认证。",
        "不把 OCR 待核字幕当可靠逐字引文，不把后验解释当事前预测。",
        "不把 A OR B 写成 A AND B，也不把「四指数同时」写成「任一满足」。",
        "不混同成交总额与较前日增额；不把软件候选当作者推荐。",
        "不把盘中状态冒称收盘确认，不把部分市场宽度冒称完整全市场。",
        "不凭常见技术分析补齐作者未给出的规则。"
    ]

    static let antiLookAheadRules: [String] = [
        "决策时刻只用已公开证据和已完成 K 线；盘中数据标 provisional，收盘结果标 close。",
        "不回填事后低点、事后最佳均线、未来成分或后发视频。",
        "使用当时证券池与可交易价格，考虑停牌、涨跌停、费用和滑点。",
        "回调深度与修复比例必须分清分母，保留波段起止点与选点算法。"
    ]

    static let unresolvedItems: [String] = [
        "统一固定仓位比例",
        "统一止盈百分比",
        "完整固定选股评分公式",
        "统一的明显放量阈值（2000 亿 / 2 万亿 / 增额 10% 口径未统一）",
        "四指数不创新低的完整计算细则（锚点、相等处理、窗口）",
        "科创指数与科创 50 的代理映射",
        "固定适配均线公式",
        "MACD 柱长与持续时间的具体数字",
        "所有买点的统一失效算法",
        "真实账户流水与可复算净值"
    ]

    struct HistoricalStat: Identifiable {
        let id: Int
        let label: String
        let value: String
    }

    /// 对话转述的历史统计，不是本次重算，也不是样本外结果。
    static let historicalValidation: [HistoricalStat] = [
        HistoricalStat(id: 1, label: "四指数连续 3 日不创新低", value: "132 次触发"),
        HistoricalStat(id: 2, label: "触发后未来 1 日上涨率", value: "约 45.5%"),
        HistoricalStat(id: 3, label: "触发后未来 3 日上涨率", value: "约 53.0%"),
        HistoricalStat(id: 4, label: "触发后未来 5 日上涨率", value: "约 52.3%"),
        HistoricalStat(id: 5, label: "触发后未来 10 日上涨率", value: "约 56.8%"),
        HistoricalStat(id: 6, label: "触发后未来 20 日上涨率", value: "约 53.0%")
    ]

    static let historicalValidationNote = "口径：全历史首次触发，尚非样本外；标的收益映射、区间、费用、重叠样本、置信区间未齐。平均收益仅描述为较弱，缺精确值不补造。不能据此否定作者，也不能声称支持 80% 以上。"

    // MARK: - 小工具

    /// 统一两位小数，避免各页面各写一套格式化。
    static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
