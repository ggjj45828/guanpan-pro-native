# CONTINUATION — Master Acceptance

更新时间：2026-10-24（Asia/Shanghai）

任务仍未完成。本说明用于下一轮无缝继续，必须先读取本文件与 `Master Acceptance Matrix.md`。用户要求以115项《完整开发、重构、测试与验收总要求》为最高标准；不要交付为最终版本，除非当前环境可完成的项目均已实现和验证。

## 产品红线
- 单一真实账户；没有模拟资金、虚拟持仓或虚拟成交；不自动下单。
- NAS研究长期行情并扫描真实持仓，手机结合最新行情、用户画像、新闻与规则生成唯一指导。
- 未确认的真实成交不得改账本；手工确认后才记录。
- 数据过期、来源不明、历史样本不足或交易规则未确认时，禁止给伪精确价格。
- 保持5套主题整体一致，底栏页面精简，高频入口留在底栏，其他功能放入短的二级入口。
- 不修改项目镜像 `sources/`。

## 当前目录和Git
- 仓库：`C:\Users\Administrator\.codex\.chatgpt-projects\g-p-6ac90ddb9a888191a751dc24eb6a329d\work\github-upload`
- 当前验证分支：`validation/acceptance-20261024`，本地 HEAD 应检查后续提交；本轮提交在本地，GitHub 推送因 github.com:443 网络连接重置/超时失败，尚未触发 Actions。
- 同名旧验证分支远端已比本地分叉；为避免强推覆盖，已撤销合并并创建独立验证分支。workflow 已接受 `validation/**`。
- 用户之前已明确授权把本轮 iOS 修改推送到验证分支并运行 Actions 编译。
- 默认仓库 compose 已改为从 `nas-advisor-compat/server` 构建，NAS compat compose 同步加入容器端口变量。

## 本轮已做
- 按用户最新数据边界调整手机/NAS分工：手机直连优先取实时报价、日K、盘中分时与新闻；NAS承担后台1分钟长期采集/保存、长期统计研究、账本同步，以及来源设置允许时作为备用。已更新默认 `phoneDirect` 模式的描述和设置说明。
- 新增iOS端 Google News RSS 手机直连新闻抓取：每只真实持仓按证券代码/名称搜索，仅接受30天内、时间可解析且HTTPS链接有效的标题，最多8条；不下载新闻正文，标记搜索聚合且未核实。手机直连优先，失败后依来源模式回退NAS；仅NAS模式不访问手机新闻源。
- 今日指导每次生成时刷新持仓新闻；即使没有配置NAS，新闻也可进入统一决策。新闻标题已进入离线事件关键词判断、最终在线AI上下文与决策记忆；提示在线AI结合来源/时间、当作未核实线索，并解释潜在持仓/计划影响，不要求用户逐条阅读。
- 新闻页文案改为“供来源查看，AI自动分析”，避免暗示新闻必须让用户自己阅读。已更新Master Acceptance Matrix第38–42项，仍标记部分实现，等待iOS构建和真实源测试。
- 新闻时效门槛：超出30天、未来超过2小时或无可解析发布时间的标题不会影响规则计划，也不会进入本次在线AI上下文；新增核心单测覆盖陈旧/无时间标题不失效计划。核心测试尚未运行，因为当前机器无Swift/Xcode。
- NAS回归仍为11/11通过，Compose配置通过，Python语法和115行矩阵计数通过。提交 `afc53bb` 已创建；推送 `validation/acceptance-20261024` 再次因当前环境无法解析 `github.com` 失败，因此未触发GitHub Actions，iOS编译仍待外部CI。
- 用户再次确认手机AI本身必须消费新闻并给出影响分析；这在架构上由手机抓新闻标题/来源/发布时间后放入手机AI统一上下文完成，而不是把阅读任务交给用户，也不是允许模型无来源地自由浏览。新闻页面仅为来源核对入口。
- 将NAS研究自动拉取加强为每次生成指导时都刷新每只持仓的压缩 `minuteStats`；不会从NAS下载全部原始分时，仅在NAS地址配置时取统计，并继续受样本新鲜度/质量规则约束。
- Bug扫查中移除NAS未调用的 `generate_g_twin_plan` AI虚拟账户分配器，以及 `domain.py` 中未调用的模拟网格/实验/虚拟账户读写方法；旧SQLite表结构保留，不做破坏性删库。增加测试断言G模拟AI helper不存在。
- 移除iOS打包在每个用户中的静态历史分红示例，分红事实必须来自NAS/用户真实记录；替换图表几处固定常量强制解包，并扫除生产Sources中剩余的显式 `try!`/强制URL解包（验收包和UI仍待编译）。
- 新增统一AI文字排版视图：识别结论/建议/证据/新闻/风险等中英文冒号与Markdown标题，逐节彩色卡片、列表点、结论重点字号；保留原文本内容和可选中复制，不改交易数值。在线AI提示改为短分段输出。跨页面截图和编译未验证。
- 静态崩溃风险扫查：iOS `Sources` 下未发现显式 `try!`、`as!`、`fatalError`、强制URL解包或 `Decimal(string:)!`；固定计算常量改为Decimal算术，测试夹具里的强制解包仍只在测试数据中。
- 新增手机每次指导自动拉NAS研究测试路径的代码并已更新115项矩阵中第3、5、38–42项；工作树这些后续修改需再提交。当前环境无Swift/Xcode，因此格式器布局、iOS新闻抓取、偏好持久化和iOS回归单测仍未通过实际编译。
- 最新可执行验证：NAS unittest 11/11，Compose config，Python py_compile，矩阵115行。`git diff --check` 已通过（仅有Windows换行格式提示）；NAS unittest 11/11通过，Compose配置和Python语法通过，矩阵行数115。
- 补上原先未接通的 NAS 分时研究链路：`/v1/research/{code}` 现在带 `minuteStats`，手机端的 `NextNASResearch.minuteStats` 会实际解码到；计算按最近240个日历日限量读取，按5/20/60/120个交易日窗口统计。
- 分时成交量须通过日K成交量独立交叉校验（分钟覆盖≥98%、每天≥200点、分时量与日K量相差≤1%）后，才进入VWAP及日内VWAP往返次数统计；不足60个有效交易日或长期质量不足时，手机已有的T计划硬门槛拒绝提供具体价格，网格也要求有效NAS区间。
- 数据质量/新鲜度按现有 iOS `NextNASMinuteStats` schema 输出，包括有效日数、分时覆盖、量覆盖、长期可用性、最后日期、样本年龄与过期原因。没有有效量价证据时返回空窗口，不会用简单均价填VWAP。
- 开发环境对4只ETF逐分钟成交量合计与日K成交量做过抽样比对，偏差约 -0.63%、+0.21%、-0.06%、-0.32%；这只是2026-10-23单日有限样本，不能证明长期源质量。
- NAS旧网页、模拟账户、网格推进/回测服务模块及网页文件已从 compat 包删除；旧路径明确返回410；新根路径只提示 NAS 研究与同步角色。workers 只启研究采集。
- 修正 compat Dockerfile 对已删除 web 目录的 COPY；start.sh 不再将旧 web 放回运行容器。
- 修正默认顶层 compose 误构建旧 `server/`；将默认构建切换到 r29 兼容研究服务。
- NAS 腾讯报价优先、东方财富回退；东财行必须有真实 f124 交易所时间戳并过期校验。全源失败返回503，部分缺码字段显式返回。
- NAS日K归档超过30分钟会尝试更新，数据源失败时保留旧归档并标记 staleArchive；无缓存且上游不可用返回503。NAS研究移动桥按真实采集时间设置 availableAt，避免伪装新鲜。
- 统一 SwiftUI colorScheme：五个主题不再受系统深色模式造成局部跳色，仪表盘全局深色；我的页改为短 hub，设置、画像、成交历史走二级入口。持仓页移除了旧的圆环/粗略市场温度重复卡片；“市场温度”原本把指数平均涨跌映射成温度且会给出“低价分批”等误导口径，已从持仓首页移除。
- 设置页标题明确为设置；UI测试随我的页入口更新。
- 持仓详情盘口渲染移除对 `orderBooks[code]!` 的强制解包，状态变化时安全处理快照缺失。
- NAS service minute/daily timestamps不再用当前接收时间填充；应用安全目录缺失时停止真实账本写入，避免临时目录伪持久化。
- 做T策略新增 NAS 研究质量和新鲜度硬门槛：分时档案过期或长期样本覆盖不足时，不能绕过规则生成具体价格；新增 Swift 回归测试，必须等 macOS Actions 实际运行。
- 崩溃风险审计替换图表空状态 `dataset!`、NAS URLComponents 强制解包、可空收息证券代码 `code!` 以及策略动态数值字符串强制解包；剩余来源级强制解包主要是编译期常量/固定时区，仍需通过 iOS 构建确认。
- App只有一个NAS地址，同时用于真实账本同步、行情、研究、新闻和分红接口；修正旧 README 对“单独研究NAS地址”的错误说明。
- 新增NAS测试：来源时间戳、全部源失败、陈旧日K缓存回退、分钟量交叉校验、VWAP/往返统计和手机研究接口解码形状；NAS测试当前11项通过。
- 真实行情只读请求在网络授权测试中成功：Tencent返回 512480 行情，时间 2026-10-23 16:14:55 +08:00；日K返回640根。**这是开发环境上游连通测试，不等于用户NAS或iPhone联调通过。**
- 矩阵更新了3、5–10、15–16、60、74行。其他行仍要逐模块继续审计，不能据此宣布满足。

## 已验证
- `python -m unittest discover -s nas-advisor-compat/tests -v`：11/11通过。
- 顶层 `docker compose config -q`：通过。
- `git diff --check`：通过（Git输出仅换行格式提示）。
- 真实Tencent行情/日K只读请求成功。
- Docker镜像没有构建：本机 Docker Desktop daemon 未运行（无法连接 npipe `dockerDesktopLinuxEngine`）。
- 本机无 Swift/Xcode/xcodegen；iOS编译、模拟器运行、真实截图仍必须通过 macOS Actions 验证。
- 独立验证分支的 push 尝试三次失败（远端旧同名分支先行更新导致拒绝；独立分支在 HTTP/2 与 HTTP/1.1 下均连接 github.com 失败）。不要强推旧分支；网络恢复后重试推送 `validation/acceptance-20261024`。

## 下一步顺序
1. 先复核现有修改和矩阵，确认Swift schema 解码与导航、测试更新；用Bundled Python重新跑NAS测试和 Compose 配置。
2. 检查 NAS 接口与 iOS 的 /health、quotes、daily、minute、research、news路径/字段完全一致；核对日K陈旧标记在手机端实际可见。
3. 检查指数卡尺寸、主题背景、Settings Form/Sheets/Alerts、卡片 NavigationLink 闪退与底栏路由。全部主题必须一个配色系统内，截图未知就标记未验证。
4. 继续按115项检查真实持仓、市场状态、做T/网格报价门槛、手续费0.10元每笔、成交反馈、AI记忆、动态画像、新闻映射与市场休市；发现未连通则修代码和测试。
5. 删除或停用仓库根 `server/` 的旧虚拟账户web入口，或确保无构建/部署路径再触达它；更新部署说明、确保升级保留数据卷。
6. Docker daemon无法启动时，继续通过Python/Compose静态验证并准确记录。
7. 提交当前验证分支并push（用户已经授权），触发 `validate-ios.yml` / `build-ios.yml`，读Actions结果。若CI失败，修复后重跑；模拟器截图需导出供视觉检查。
8. 把每项状态写入 `Master Acceptance Matrix.md`，准确区分验证与未验证。

## 关键文件
- `Master Acceptance Matrix.md`：115行验收跟踪矩阵。
- `guanpan-pro-native/Sources/GuanpanAdvisorApp.swift`：底栏、短Hub、主题统一、设置入口、持仓页。
- `guanpan-pro-native/Sources/NASService.swift` 与 `NextAppModelState.swift`：手机NAS/行情链路。
- `nas-advisor-compat/server/{app.py,market.py,mobile_research.py,domain.py,workers.py,Dockerfile,start.sh}`：NAS研究、行情、采集和部署。
- `nas-advisor-compat/tests/test_research_only.py`：当前11项NAS测试。
- `.github/workflows/{validate-ios.yml,build-ios.yml}`：iOS模拟器验证与IPA构建。

用户最新指示：主题必须全页一致，全面排查闪退与多余入口，NAS连接和 NAS Market 行情必须能取数；严格按115项验收，不要拖沓。

- 本轮继续验证手机AI文字卡片格式器：主指导和AI研究回答均已改用格式器；NAS 11/11回归、Compose和Python语法通过。iOS构建/模拟器仍无本机工具链，不能记为已验证。
- 新闻抓取通过静态链路核对，保留RSS标题/来源/发布时间/HTTPS链接，过滤无时间和超期标题；当前未在iPhone实网验证供应商可达性。
