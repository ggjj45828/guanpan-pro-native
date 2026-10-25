# B版当前状态

更新时间：2026-10-25（Asia/Shanghai）

## 版本标识
- 路线：B（Master Acceptance Matrix独立路线）；未合并、未cherry-pick A版。
- 当前工作分支：`validation/acceptance-20261024`。
- B源码快照对应commit：65819d2800c64734681dfcf44756adfc66e3364f；B-LATEST.zip按该源码树生成。
- 快照生成时间：2026-10-25 18:53:19 +08:00。
- 三层保存规则：[B-DEVELOPMENT-RULES.md](B-DEVELOPMENT-RULES.md)。本工作树当前HEAD对应commit尚未在本轮远端确认；NAS灾备本轮未同步，因此不能据此判定满足安全关机条件。
- 远程核验：远程名为 `origin`，指向B独立仓库 `ggjj45828/guanpan-pro-native`；远端当前分支commit尚未在本轮核验。
- NAS快照commit：本轮未同步 / 未核验。

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

## 当前可确认的测试和外部验证
- NAS研究：本轮用 bundled Python 执行 `nas-advisor-compat/tests/test_research_only.py`，65/65通过。
- NAS同步：本轮可在无localhost的隔离子集执行 `tests/test_market_data.py` 25/25、`tests/test_research_inputs.py` 10/10，合计35/35通过；完整同步58/58为历史记录，本轮未重跑。
- HTTP集成：7项 localhost HTTP 测试受当前沙箱 WinError 10013 阻断；External Verification Pending，非通过、非业务失败。
- Swift/XCTest：历史 B Validate #120 的 Portable Swift Core 140/140、模拟器UI 11/11、账本集成9/9曾通过；早于当前代码，不能作为当前代码测试结果。本机没有Swift/Xcode执行器，本轮新增测试未运行。
- GitHub Actions：最近矩阵记录的 #123 等运行尚未取得可核验终态；External Verification Pending。
- Simulator/截图：旧树有历史截图产物；本轮五主题和详情变化尚无可核验截图，External Verification Pending。
- iPhone/NAS实机联调、真实API Key端到端、真实长期分钟档案：External Verification Pending。
- 跨电脑灾备：Project Files本地checkpoint已生成；远程commit与NAS快照未核实。当前工作尚未满足“可安全关机”确认条件。

## 当前真实产品缺口
- 145项矩阵仍有大量Partial；本次只完成本地可做的代码/测试源更新，不能称整体验收完成。
- 新增Swift代码和XCTest尚未由Apple工具链编译运行。
- 真实券商ETF费率、逐证券结算规则、NAS长期分钟档案及在线AI密钥仍需各自环境验证。

## 下一开发断点
1. 继续从B-MASTER-ACCEPTANCE-MATRIX的P0/本地可推进Partial中审计业务缺口，不重复探测Actions、Xcode、Simulator或localhost权限。
2. 本轮发现并修复手续费事务失败前的内存提前发布；检查对应集成测试、静态路径与其他真实账本多文件写入边界。
3. 远端push及commit核验、NAS灾备同步当前均未确认；仅在确有可用通道时执行并记录，不能把本机checkpoint说成脱机备份。

## 产品红线
- 只使用唯一真实账户；无模拟资金/持仓/成交；不自动下单。
- NAS负责长期研究，手机生成唯一最终指导；没有可信数据时不生成伪精确建议。
- 真实成交只在用户确认后修改账本；LLM不得重算交易数字。
- 历史相关性不是因果关系或交易授权；不允许未来数据进入当时决策。
- A/B完全隔离；B的状态只由B源码与B测试证据决定。
