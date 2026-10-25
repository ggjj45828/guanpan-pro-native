# B版当前状态

更新时间：2026-10-25 19:08（Asia/Shanghai）

## 版本标识
- 路线：B（Master Acceptance Matrix独立路线）；未合并、未cherry-pick A版。
- 当前工作分支：`validation/acceptance-20261024`。
- B源码快照对应commit：待本轮修复提交后更新；当前有未提交的候选计划行情异常保护修改。
- 快照生成时间：本轮代码提交后生成。
- 三层保存规则：[B-DEVELOPMENT-RULES.md](B-DEVELOPMENT-RULES.md)。
- 按用户指定顺序核验：GitHub连接再次测试时DNS仍无法解析`github.com`，`git ls-remote`失败；远端HEAD是否包含本地最新commit未知。NAS快照commit未同步/未核验（当前环境没有可用NAS盘符或挂载点）。
- 本地/远程：远程本轮不可达，不能称已备份。NAS：未同步。最新工作尚未同时具备GitHub与NAS外部副本，不满足安全关机条件。

## Master Acceptance Matrix
- 唯一最新矩阵：[B-MASTER-ACCEPTANCE-MATRIX.md](B-MASTER-ACCEPTANCE-MATRIX.md)
- 统计：✅ 1，🟡 18，🟠 126，❌ 0，⚠️ 0；合计145项。
- 旧文件 `Master Acceptance Matrix.md` 已标注 Historical / Superseded，不作为最新状态来源。

## 本轮新增与修复
- ETF手续费设置改为可配置（默认¥0.10/笔）；修改费率时，候选计划、交易规则和偏好设置使用可回滚多文件写入，持久化成功后才更新内存。
- 场景主题自动模式实际接入主Tab与详情路由；固定主题继续覆盖全App。设置说明已更新。
- 手机API Key轮换改为先更新现有Key，仅不存在时新增，避免先删旧Key后写入失败造成凭证丢失。
- Risk Guard对显式非法目标权重（NaN/越界）及超过100%的持仓权重改为拒绝新增买入。
- 新增事务失败回滚、费率修改重启恢复、失败不改内存、五场景主题映射及异常组合比例测试代码；Swift/XCTest未运行。
- 继续审计发现手续费批量保存函数在事务开始前仍提前赋值 `@Published preferences` 和 `rules`，使已存在的失败测试预期无法保证；本轮已移除提前赋值，现仅在 `saveTransaction` 成功后发布费率、规则和撤回计划。本修复尚未运行Swift/XCTest。
- 真实账户极端份额路径新增溢出保护：部分成交合并、T+1锁定份额、完整流水成本判断、网格卖出档合计、补仓后份额及回本次数转换；不可信总量不生成摊薄成本/计划，可能溢出的成交写入明确拒绝。新增纯逻辑与账本集成测试源码，尚未执行Swift/XCTest。
- 组合风险守卫增加正T买入腿和网格全部买档成交/卖档未成交时的最坏情形投影，扣除估算手续费后的组合净值，并同时检查集中度上限及用户目标权重；数据不完整时拒绝新增计划。新增边界XCTest源码，尚未执行。
- 候选计划真实成交原来会在`recordTrade`后立即学习一次，又在计划/建议/决策记忆更新后再次学习；现改为候选成交路径只在所有状态完成后学习一次，普通人工成交入口仍只学习一次。
- 组合风险估值曾只看行情时间与来源，未将“时间新鲜但相对昨收/账本成本异常”的报价排除；现复用组合估值的价格异常规则，任一持仓出现此类报价便不能建立可用组合权重。已补测试源码，未执行Swift/XCTest。
- 候选计划原先允许时间新鲜但相对昨收异常的报价通过保存/计划复核；现对候选计划保存、持续触价复核和状态刷新统一调用同一异常报价门槛，异常时拒绝保存或作废旧计划。新增回归测试源码，尚未运行Swift/XCTest。
- GitHub连接复测：DNS解析失败，`git ls-remote`无法确认远端HEAD；未重复尝试网络探测。

## 当前可确认的测试和外部验证
- NAS研究：本轮用 bundled Python 执行 `nas-advisor-compat/tests/test_research_only.py`，65/65通过。
- NAS同步：本轮可在无localhost的隔离子集执行 `tests/test_market_data.py` 25/25、`tests/test_research_inputs.py` 10/10，合计35/35通过；完整同步58/58为历史记录，本轮未重跑。
- HTTP集成：7项 localhost HTTP 测试受当前沙箱 WinError 10013 阻断；External Verification Pending，非通过、非业务失败。
- Swift/XCTest：历史 B Validate #120 的 Portable Swift Core 140/140、模拟器UI 11/11、账本集成9/9曾通过；早于当前代码，不能作为当前代码测试结果。本机没有Swift/Xcode执行器，本轮新增测试未运行。
- GitHub Actions：最近矩阵记录的 #123 等运行尚未取得可核验终态；External Verification Pending。
- Simulator/截图：旧树有历史截图产物；本轮五主题和详情变化尚无可核验截图，External Verification Pending。
- iPhone/NAS实机联调、真实API Key端到端、真实长期分钟档案：External Verification Pending。
- 跨电脑灾备：Project Files本地checkpoint已生成；远程因DNS失败无法核验，NAS无挂载且未同步。**B版最新工作仍仅存在当前电脑，不满足安全关机条件。**

## 当前真实产品缺口
- 145项矩阵仍有大量Partial；本次只完成本地可做的代码/测试源更新，不能称整体验收完成。
- 新增Swift代码和XCTest尚未由Apple工具链编译运行。
- 真实券商ETF费率、逐证券结算规则、NAS长期分钟档案及在线AI密钥仍需各自环境验证。

## 下一开发断点
1. 继续从B-MASTER-ACCEPTANCE-MATRIX的P0/本地可推进Partial中审计业务缺口，不重复探测Actions、Xcode、Simulator或localhost权限。
2. 继续审计真实账本/成交恢复的异常边界及DecisionContext一致性；新整数溢出保护、买入后组合风险守卫、异常报价隔离、手续费事务与画像单次学习修复等待Swift完整测试。
3. GitHub DNS恢复后推送并核对远端commit；NAS可访问时同步三份B快照并记录NAS快照commit。未满足之前不声称具备安全关机备份。

## 产品红线
- 只使用唯一真实账户；无模拟资金/持仓/成交；不自动下单。
- NAS负责长期研究，手机生成唯一最终指导；没有可信数据时不生成伪精确建议。
- 真实成交只在用户确认后修改账本；LLM不得重算交易数字。
- 历史相关性不是因果关系或交易授权；不允许未来数据进入当时决策。
- A/B完全隔离；B的状态只由B源码与B测试证据决定。
