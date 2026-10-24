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

- 本轮继续发现并修复指导数据缓存过期问题：每次生成指导刷新日K；仅在A股实时交易时段刷新分时；做T精确报价另校验分时样本必须属于上海时区当天且不超过5分钟，过期/旧日缓存会硬阻断具体价格。新增Swift回归用例覆盖旧日、超5分钟与新鲜分时。Swift/Xcode仍缺失，新增用例尚未运行。

- 当前本地验证分支新提交：64df68a（手机 AI 排版/清理旧NAS helper），714ba52（做T只接受当天且5分钟内的分时证据）。已再次尝试推送，仍因无法解析 github.com 失败；Actions 编译未触发。

- 进一步收紧日K新鲜度：做T/网格/统一扫描器都检查最新K线日期；缺日期、超前超过1天或晚于15天即拒绝具体价格。15天窗口兼容长假，不会把跨节期间周五日K误判成坏数据。新增Swift测试覆盖过期日K和长假窗口；需要macOS运行。

- 回答云编译/签名问题后继续改进打包：GitHub Actions的macOS构建工作流仍在 .github/workflows/build-ios.yml，模拟器验证在 validate-ios.yml；当前未跑的原因是本机GitHub推送网络被代理/DNS阻断，不是撤掉了云构建。当前Edge的GitHub页可浏览公开仓库，但没有可供命令行推送的gh CLI。
- IPA签名报错路径明确出现乱码中文 .app 名及中文主程序名，符合旧版本 PRODUCT_NAME/CFBundleExecutable 中文导致某些Windows sideload zip解码器找不到文件的症状；当前project.yml为ASCII产品名，但我进一步固定 EXECUTABLE_NAME=GuanpanPro，新增 verify_ipa.py 在云端检查包内 app 路径、Info.plist的可执行名、Mach-O头、Bundle ID、ZIP CRC与签名文件，发现错包即阻止上传。4个合成IPA正反例测试通过；还需实际云构建证明本轮产物。

- 当前会话确认了旧同步 NAS 包残留独立模拟策略 worker。已从两个 NAS Compose 文件移除 worker，删掉 worker 源码和 Dockerfile，禁用旧 `quant` 虚拟账户/租约接口（历史数据库表不删除），旧 NAS 网页路由返回410；对应过时模拟 Swift 包、工作流和测试已清理。NAS r29 格式继续以 `nas-advisor-compat` 为准，版本号升至 3.6.0-r15，最终压缩包应保留 `compose.yml`、`.env.example`、`README-NAS.md`、`update.sh`、`server/`，不含 `.env`、密钥和数据库。
- 本轮 NAS 研究测试11/11、旧同步存储/行情测试41/41通过，三套 Compose 文件解析通过，`git diff --check`通过；需要在可用回环网络的 CI 复跑 HTTP 测试。生成 NAS zip、完整源清单仍待最后回归。
- 为修复签名器找不到中文路径，IPA 校验改动已提交 `cb360d6`，本地推送分支为 `validation/acceptance-20261024`。此前命令行 push 在普通与提权网络下均无法连接 github.com:443，因此 Actions 尚未触发；用户指出浏览器可打开仓库，下一轮先从当前 Actions 页确认是否已有远端运行，再判断能否由已授权的浏览器/仓库路径提交。


## 2026-10-24 继续验收记录（手机端问答与回归）

- 补齐 AI Hub 的手机端“AI 持仓问答”二级页面：每次提问先刷新统一决策上下文，复用真实持仓、手机行情、NAS研究、新闻和画像；缺少真实持仓或本机 Key 时不给调用；对话只保存在当前页面状态，不修改账本或计划。AI回答通过已有结构化格式器呈现。
- 新增 XCUITest 导航用例，覆盖从 AI Hub 打开问答页、输入框和发送按钮。尚未运行：当前 Windows 环境无 Xcode/Swift。
- 本轮回归：nas-advisor-compat 12/12、legacy server 84/84、NAS同步服务 58/58、IPA校验 4/4，共158项通过。需要注意，legacy server 与 NAS同步测试使用合成测试夹具，不代表真实NAS/iPhone联调。
- 待继续：复查已生成的r16 NAS zip与校验清单、全部115项矩阵和Git差异；尝试已授权的远端同步/Actions但仅在网络通畅时进行；macOS构建、模拟器截图、NAS实机升级仍属于外部验证。

- 继续审计后，发现 NAS compat 服务仍带有独立 DeepSeek Key、每日模型研究和验证入口，与“手机唯一最终AI、NAS仅提供证据”冲突。已从当前部署包移除模型模块和 Compose 密钥注入，关闭 `/v1/ai/verify`（410），研究端点仅返回本地因子与分钟统计；旧数据库中的历史 AI 研究不删除但不再暴露给手机。iOS 研究页只展示 NAS统计证据，不再显示旧 NAS 模型文字。NAS版本升至 `3.6.0-r16-phone-only-ai-research`。
- 新增回归验证：NAS研究12/12；legacy server 84/84；NAS同步58/58；IPA校验4/4；Python语法与四套Compose配置解析通过；`git diff --check`通过。合计158项测试通过。
- 已生成 r16 NAS 包并通过 ZIP CRC、13个文件路径、SHA256清单和无 `.env`/模型模块/数据库检查；包 SHA256 为 `b1b77546c683cff9e1b7bd3e82e81cab2f3a108c397057fd704cd7e3d1e7e108`。iOS构建、模拟器截图、真实NAS部署仍需对应环境。

- 用户授权后成功推送 `266089f` 到 `validation/acceptance-20261024`。GitHub foundation 回归通过；macOS iOS 编译和 IPA 构建都发现既有 `NASService.swift` 在 `NextNASService` enum 末尾缺少 `}`，首轮 UI 测试未能开始。已在当前源码补闭合并更新矩阵；需推送修复并重跑两条云工作流，直到编译/测试实际通过或继续迭代。

- 修复 `be2e8b2` 已推送，触发 IPA 构建和 iOS 验证。首轮新构建进一步发现 `AIChatScreen` 状态摘要的 SwiftUI 类型检查复杂、`GPPalette` 阴影属性名引用错误；已在本地拆分字符串计算并改用 `cardShadowOpacity/cardShadowRadius`。需要提交并推送后重跑两条工作流。
- 本轮本地回归复核：NAS research 12/12、旧服务 84/84、NAS同步 58/58、IPA校验 4/4；总计158项通过。旧服务和NAS同步回环HTTP测试需在放行本机随机端口后才可运行，已通过。
- 当前 Actions 状态：`Validate iOS candidate`（run 40080847268）运行中；`Build iOS IPA`（run 40080847316）因上述两处Swift错误失败，尚未生成IPA。修复后继续推送和重跑。

- 最新macOS编译已成功，确认NASService闭合、AI持仓聊天状态摘要、主题卡片阴影引用均可编译。IPA在打包校验阶段失败：脚本 `cd` 到临时IPA目录后仍以相对路径访问校验器；工作流已改为 `$GITHUB_WORKSPACE/$PROJECT_DIR/scripts/verify_ipa.py`，需推送后重跑。
- 最新 Actions（2150bd0）：IPA run 40081298511 构建通过、打包路径失败；模拟器 run 40081298499 正在执行完整UI测试。继续等其结果和截图附件。

## 2026-10-24 NAS 外网/采集耗流量核查

- 用户询问 NAS 容器外网、系统时钟、DNS/IPv6 是否有故障，以及后台是否会为旧 demo ETF 持续请求上游。
- 源码静态检查结论：Compose 未禁用外网，也未配置自定义 DNS 或 IPv4/IPv6 策略；容器使用 Docker 主机时钟，`/health` 不检测时钟偏差。因此这三项是未诊断的运行环境风险，源码不能证明 NAS 上实际发生了任一故障。镜像拉取使用 DaoCloud 不能证明容器运行时出网失败或成功。
- 发现并修正采集范围漏洞：旧 `tracked()` 会把 `daily_bars`/`minute_archive` 中曾经出现的所有代码永久加入采集集合；现在只允许空的默认列表、手机明确登记的标的与 NAS 真实账本正持仓触发采集。版本升至 `3.6.0-r17-holdings-only-collection`，NAS README 说明该改变和环境诊断限制。
- 新增两个回归测试：历史 archive-only demo 代码不进入请求清单；显式登记标的与真实正持仓仍会采集。`nas-advisor-compat/tests` 本轮 14/14 通过。容器/NAS现场仍未验证。
- 穿透流量区分：workers 从 NAS 容器向 Tencent/Eastmoney 发出的请求走 NAS 主机出站链路；手机通过映射域名读取 NAS API 才经过用户配置的穿透通道。当前 README 与手机默认模式是手机直连行情，NAS只提供长期研究；实际 NAS 主机若将所有出站流量再路由到代理仍需现场确认。当前 worker 日K每30分钟轮询、分时盘中每分钟轮询；以后可将日K调为收盘后一次，分时频率取决于上游接口是否每次提供完整当日分钟序列。

## 2026-10-24 新增跨市场可证伪研究与回放

- 用户新增的跨市场研究需求编号实际为116–145，已完整追加到唯一《Master Acceptance Matrix.md》，原1–115项保留。矩阵145项计数：✅1、🟡16（14条 `Implemented / Not Verified` + 2条 `Implemented / Not Fully Verified`）、🟠124、⚠️4。新增项全部保持🟠，因为当前没有真实跨市场分钟行情档案。
- 新增 `nas-advisor-compat/server/cross_market.py`：时间戳强制带时区并统一UTC；过滤asOf之后的未来点；评估0/5/10/15/30/45/60/90分钟领先窗口、5/15/30/60分钟前向收益、样本数、相关、条件胜率、均值/中位数、最大不利变化和分段稳定性；样本少于40或稳定性不足时返回“暂无稳定领先关系”/insufficient，不输出伪概率。
- 加入A股午休11:30→12:50的实测价格变化计算。新增历史假设回放函数：12:50时只按当时可见输入形成冻结假设，13:00后样本独立用于确认/拒绝；回放按日期去重、保留输入指纹，达不到最低样本数时 `confirmationRate=null`。研究报告不会创建账户、交易、持仓或收益账本。
- `domain.py` 增加独立 `cross_market_minute` 证据档案表，保留交易所本地时间偏移；校验来源、价格、时间戳与未来数据。新增只读接口 `/v1/research/cross-market/replay`，从真实NAS分钟档案重放；没有档案时明确返回 `insufficient_real_archive`，不编造结果。该端点当前只能读取档案；真实跨市场提供方与采集worker尚未接入。
- NAS research tests：21/21通过；包括未来点排除、过期数据、午休缺样本、12:50冻结隔离、100个合成交易日累计与重复日期去重、分钟存储交易所日期、只读回放无档案时显式不足。`compileall`通过，`docker compose config -q`通过，`git diff --check`通过。
- 本轮既有候选计划修复已纳入验证分支：新鲜重大新闻作废原候选计划；计划过期/作废后仍允许补录券商真实部分成交。Swift回归已编写但当前无本机Swift/Xcode，尚未运行。
- 下一步必须先给NAS跨市场归档接入一个有验证证据和时间戳的分钟源/市场代码映射；再将NAS研究DTO、手机 `NextDecisionContext`、Risk Guard与DecisionMemory接上。没有找到可靠历史数据源前必须保留“暂无稳定领先关系/证据不足”。随后用真实归档滚动回放至少100–200个有效交易日；合成夹具不能代替该验收。
- 目前新跨市场功能没有更改或启动任何模拟账户，也没有自动下单。真实外部市场行情源、NAS部署和iPhone实测仍未验证。

- 当前本地提交 e73623，已通过Git Database API以远端最新 729abd8 为父提交追加到 alidation/acceptance-20261024，远端提交 39d2eb1287ad64e2d8c2e4bee25ec0a70cea981a；远端矩阵/延续记录与其他模型的先前修改已保留。Actions：Build iOS IPA run 40087046731、Validate isolated foundation run 40087046734 正在运行，Validate iOS candidate run 40087046787 排队。18-cross-market-replay-foundation仍无真实外部分钟采集worker，不能发布为功能完成。

## 2026-10-24 跨市场研究接入与回放防泄漏修复

- 延续本地 `validation/acceptance-20261024`，版本号更新至 `3.6.0-r19-cross-market-verified-collection`。已确认 `workers.py` 的跨市场采集循环完整存在；腾讯白名单为上证/深证/创业板/科创50/沪深300/A500/半导体指数，东财已验证映射为恒生、日经225、KOSPI、Nasdaq100、S&P500。各市场名义开市时间按本地时区、午休和美股DST控制；每5分钟请求完整分钟序列、只接纳10分钟内末笔数据。无可靠成交量/IOPV数据不计算相应指标，尚无官方节假日历。
- NAS `/v1/research/{code}` 已从静态占位改成真实档案读取：把持仓ETF分钟档案与13个市场分钟档案按真实时间戳对齐，计算每个市场的8种领先窗口×4种前向窗口，并输出精简的逐市场研究摘要；回放接口仍只读，不建立账户、虚拟资金或成交。Swift DTO/统一DecisionContext增加最佳市场、市场开闭状态、数据年龄；在线AI仍受约束，不允许凭空推断海外领先关系；市场关闭、数据过期或状态未知时，AI只能说明历史研究，不能冒充当天海外实时方向信号。
- 统计门槛继续收紧：样本单位是独立交易日，不是分钟条数；最少100日；相关通过Fisher-z检验和跨13市场/32窗口的416组Bonferroni校正，且要求前后半段稳定。数据不够返回 `insufficient_real_archive`；历史样本充足而未通过时明确返回 `no_stable_relationship` / “没有稳定领先关系”。这只是可证伪筛选，不证明因果关系。
- 修复回放结果价格配对方向：13:00基准、确认点和后续窗口只使用目标时点及之后真实观测，不能拿12:59价格冒充13:00；历史周末回放拒绝执行。历史单日的冻结假设与后验分离，变更13:00后数据不会改变冻结条件。
- 新增跨市场采集盘段熔断：连续3次收到陈旧/非当日时间戳后，暂停该市场当前交易盘段；跨越午休或进入下一交易日会自动恢复尝试。这样保留开盘初次延迟的重试机会，又避免休市日全天每5分钟重复请求。该保护由新增回归用例覆盖。
- 本地验证：当前最新 `nas-advisor-compat/tests` 32/32通过；Python `compileall`、Compose静态解析、`git diff --check`通过。新增数据库档案→持仓统计函数测试，使用100个测试交易日夹具确认“某市场→该ETF”研究链路；夹具不是实盘证据。`verify_ipa.py` 4/4通过。Swift解码/上下文测试需要Actions运行。额外全套旧server和nas-sync测试在本Windows沙箱运行时受临时目录权限/本地回环端口限制，不能计为通过，也不属于本批跨市场组件的回归结果。
- 当前验收矩阵仍145项：✅1、🟡16、🟠124、⚠️4；跨市场项目仍为🟠。真实NAS部署、源端长期积累、真实100–200日样本外回放、手机/ NAS端到端与iOS构建尚未验证。不能宣称发现日韩领先关系或完成全部需求。
- 已安全追加远端验证分支 `94c140ce4d956de3b6b2be8be8ef637e70cd07a9`，保留远端矩阵原1–115行；已触发Build iOS IPA与Validate iOS candidate（含重复的push/dispatch任务），其中隔离foundation通过，其余需等待。注意随后新增了iOS对“闭市/陈旧市场不得作为当天信号”的提示和测试，以及采集盘段熔断；这些后续变更尚未推送。
- 下一步：整理后续变更，安全追加到远端分支并触发macOS iOS build/validation；有编译错误就修复并重跑。检查iOS响应解码及DecisionContext用例，生成r19 NAS包但标注未部署；继续完善官方交易日历、TOPIX/KOSDAQ/SOX/期货/汇率可靠源映射和更严格的样本外验证。不要把当前开发环境采样或合成夹具写成真实长期历史结果。

## 2026-10-24 回放评估防过度结论

- 用户明确要求系统可证伪：真实历史不支持领先规律时要明确说“没有稳定领先关系”，不为迎合假设强行报信号；12:50冻结、13:00后真实数据验证是研究回放，不是模拟账户。
- 发现原回放只算触发样本命中率，不能区分条件是否比未触发日更有信息；而且旧合成测试将相同路径复制到不同日期，虽然用于接口通路测试，但容易被误读为独立市场证据。
- 新增回放汇总：按有效日期先后切出末30%留出段；仅纳入冻结条件数据完整且后验确认点真实存在的日期；报告触发组/未触发对照组的确认率、Wilson 95%区间及增量区间。总有效样本少于请求门槛，或留出段触发/对照任一组不足30天时状态为 `insufficient_samples`，公开的 `confirmationRate` 为null；完整样本命中率移至 `inSampleConfirmationRate`，避免冒充样本外验证。留出区间能排除≥5个百分点实际优势时返回 `no_stable_relationship` 并明确“没有稳定领先关系”；有增量但仅为候选时要求后续未见数据复现；其余返回 `inconclusive`。这不是因果证明，也不把不显著等同于无规律。
- 修正验证含义：没有触发信号的有效日期也计算同方向结果作为对照；零收益不再误判成向下预测命中；缺少冻结输入或确认点的日期不进入比较组。
- `Master Acceptance Matrix.md` 第120、121、128、144、145项更新。NAS测试33/33通过；Python语法、Compose配置和 `git diff --check` 通过。合成研究夹具只验证统计流程，不能代表真实市场关系。变更已合并并推送至 `validation/acceptance-20261024`，远端提交 `6a235b2`；GitHub API查询受限流，浏览器Actions页面加载超时，尚未确认该提交对应的macOS构建/测试结果。
- NAS包版本更新为 `3.6.0-r20-falsifiable-replay-assessment`；真实NAS样本外回放仍未完成。
- 下一步：继续检查回放样本的时序排序、输入指纹与逐日数据可追溯性；确认远端macOS验证结果并修复构建问题；真实NAS开始采集后，以预先固定的假设跑100–200个真实交易日再判断是否存在关系。全局矩阵仍145项，不能因此宣布全项完成。

## 2026-10-24 回放证据留档与完整交付要求

- 用户要求持续开发，最终一起提供 IPA、NAS 部署包和完整源码，并在全部可完成工作结束后列清单；不得把本次小改动当作最终交付。
- 回放接口现在生成唯一 `replayId`、UTC生成时间和规范化输入 SHA-256。NAS `research_runs` 留存研究请求、确定性 gzip+base64 压缩的完整双边分钟证据快照、来源、采集时间区间和报告；新增 `GET /v1/research/cross-market/runs/{replayId}` 会解压并重算指纹后只读取回，快照损坏或篡改会拒绝返回。明确与 `real_books` 分离，不写账户、现金、持仓、成交或收益。
- `get_minute` / `get_cross_market_minute` 现在连同归档观察返回采集时间元数据，使回放快照可以保留证据来源与时间。新增测试验证回放留档、按ID取回、输入指纹稳定和真实账本不变。
- NAS版本提升为 `3.6.0-r21-replay-evidence-archive`。NAS研究测试34/34通过；Python `compileall`、Compose静态配置和 `git diff --check` 均通过。完整145项矩阵中第144项已更新，仍为🟠，因为没有真实100–200日样本和后续未见数据复现。
- 当前构建情况：Windows环境没有Xcode/Swift编译器，需使用已授权GitHub Actions检查iOS构建/模拟器验证；本地NAS源码可用Python/Compose进行验证，但Docker Desktop未运行，仍不能声称NAS部署或iPhone联调完成。
- 下一步从本记录继续：完成NAS静态/回归验证，逐项核查提交差异和文档版本；随后在授权验证分支安全推送源码以触发iOS Actions，检查并修复失败；准备NAS兼容格式包与完整源码包，逐一验证包内文件/密钥排除和哈希。只在可完成事项均完成后提供文件及逐项状态清单，外部NAS/iPhone/真实历史依赖项明确保留⚠️。
