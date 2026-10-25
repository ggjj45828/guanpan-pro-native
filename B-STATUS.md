# B版当前状态

更新时间：2026-10-25（Asia/Shanghai）

## 版本标识
- 路线：B（Master Acceptance Matrix独立路线）；未合并、未cherry-pick A版。
- 当前工作分支：`validation/acceptance-20261024`。
- B源码快照对应commit：将在本轮代码checkpoint提交后填写；`B-LATEST.zip`会按该源码commit生成。
- 快照生成时间：待本轮打包后填写。

## Master Acceptance Matrix
- 唯一最新矩阵：[B-MASTER-ACCEPTANCE-MATRIX.md](B-MASTER-ACCEPTANCE-MATRIX.md)
- 统计：✅ 1，🟡 18，🟠 126，❌ 0，⚠️ 0；合计145项。
- 旧文件 `Master Acceptance Matrix.md` 已标注 Historical / Superseded，不作为最新状态来源。

## 本轮新增与修复
- ETF手续费设置改为可配置（默认¥0.10/笔）；修改费率时，候选计划、交易规则和偏好设置使用可回滚多文件写入，持久化成功后才更新内存。
- 场景主题自动模式实际接入主Tab与详情路由；固定主题继续覆盖全App。设置说明已更新。
- 手机API Key轮换改为先更新现有Key，仅不存在时新增，避免先删旧Key后写入失败造成凭证丢失。
- 新增事务失败回滚、费率修改重启恢复、失败不改内存及五场景主题映射测试代码；未运行Swift/XCTest。

## 当前可确认的测试和外部验证
- NAS研究：历史本地运行记录包含 65/65 与随后矩阵记录的 59/59（测试集合/时点不同；本轮代码变更后未重跑，不把它们记为本轮验证）。
- NAS同步：最近记录 58/58；本轮未重跑。
- HTTP集成：7项 localhost HTTP 测试受当前沙箱 WinError 10013 阻断；External Verification Pending，非通过、非业务失败。
- Swift/XCTest：历史 B Validate #120 的 Portable Swift Core 140/140、模拟器UI 11/11、账本集成9/9曾通过；早于当前代码，不能作为当前代码测试结果。本机没有Swift/Xcode执行器，本轮新增测试未运行。
- GitHub Actions：最近矩阵记录的 #123 等运行尚未取得可核验终态；External Verification Pending。
- Simulator/截图：旧树有历史截图产物；本轮五主题和详情变化尚无可核验截图，External Verification Pending。
- iPhone/NAS实机联调、真实API Key端到端、真实长期分钟档案：External Verification Pending。

## 当前真实产品缺口
- 145项矩阵仍有大量Partial；本次只完成本地可做的代码/测试源更新，不能称整体验收完成。
- 新增Swift代码和XCTest尚未由Apple工具链编译运行。
- 真实券商ETF费率、逐证券结算规则、NAS长期分钟档案及在线AI密钥仍需各自环境验证。

## 下一开发断点
1. 继续从B-MASTER-ACCEPTANCE-MATRIX的P0/本地可推进Partial中审计业务缺口，不重复探测Actions、Xcode、Simulator或localhost权限。
2. 优先审查Risk Guard、交易计划持久化与DecisionContext的剩余 fail-closed 边界；补对应源码和测试，Matrix保留真实状态。
3. 继续完善自动主题的导航UI回归和交易成本持久化集成用例；等外部执行通道恢复后再运行完整Swift测试。

## 产品红线
- 只使用唯一真实账户；无模拟资金/持仓/成交；不自动下单。
- NAS负责长期研究，手机生成唯一最终指导；没有可信数据时不生成伪精确建议。
- 真实成交只在用户确认后修改账本；LLM不得重算交易数字。
- 历史相关性不是因果关系或交易授权；不允许未来数据进入当时决策。
- A/B完全隔离；B的状态只由B源码与B测试证据决定。