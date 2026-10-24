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
- 当前分支：`upgrade/v2.13.55-r2`，比 origin/main 领先40个提交，存在本轮未提交变更。
- 用户之前已明确授权把本轮 iOS 修改推送到验证分支并运行 Actions 编译。
- 默认仓库 compose 已改为从 `nas-advisor-compat/server` 构建，NAS compat compose 同步加入容器端口变量。

## 本轮已做
- NAS旧网页、模拟账户、网格推进/回测服务模块及网页文件已从 compat 包删除；旧路径明确返回410；新根路径只提示 NAS 研究与同步角色。workers 只启研究采集。
- 修正 compat Dockerfile 对已删除 web 目录的 COPY；start.sh 不再将旧 web 放回运行容器。
- 修正默认顶层 compose 误构建旧 `server/`；将默认构建切换到 r29 兼容研究服务。
- NAS 腾讯报价优先、东方财富回退；东财行必须有真实 f124 交易所时间戳并过期校验。全源失败返回503，部分缺码字段显式返回。
- NAS日K归档超过30分钟会尝试更新，数据源失败时保留旧归档并标记 staleArchive；无缓存且上游不可用返回503。NAS研究移动桥按真实采集时间设置 availableAt，避免伪装新鲜。
- 统一 SwiftUI colorScheme：五个主题不再受系统深色模式造成局部跳色，仪表盘全局深色；我的页改为短 hub，设置、画像、成交历史走二级入口。持仓页移除了旧的圆环/粗略市场温度重复卡片；“市场温度”原本把指数平均涨跌映射成温度且会给出“低价分批”等误导口径，已从持仓首页移除。
- 设置页标题明确为设置；UI测试随我的页入口更新。
- NAS service minute/daily timestamps不再用当前接收时间填充；应用安全目录缺失时停止真实账本写入，避免临时目录伪持久化。
- 新增NAS测试：来源时间戳、全部源失败、陈旧日K缓存回退；NAS测试当前9项通过。
- 真实行情只读请求在网络授权测试中成功：Tencent返回 512480 行情，时间 2026-10-23 16:14:55 +08:00；日K返回640根。**这是开发环境上游连通测试，不等于用户NAS或iPhone联调通过。**
- 矩阵更新了3、6、7、8、60、74行。其他行仍要逐模块继续审计，不能据此宣布满足。

## 已验证
- `python -m unittest discover -s nas-advisor-compat/tests -v`：9/9通过。
- 顶层 `docker compose config -q`：通过。
- `git diff --check`：通过（Git输出仅换行格式提示）。
- 真实Tencent行情/日K只读请求成功。
- Docker镜像没有构建：本机 Docker Desktop daemon 未运行（无法连接 npipe `dockerDesktopLinuxEngine`）。
- 本机无 Swift/Xcode/xcodegen；iOS编译、模拟器运行、真实截图仍必须通过 macOS Actions 验证。

## 下一步顺序
1. 先复核现有修改和矩阵，确认Swift语法/导航、测试更新；用Bundled Python重新跑NAS测试和 Compose 配置。
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
- `nas-advisor-compat/tests/test_research_only.py`：当前9项NAS测试。
- `.github/workflows/{validate-ios.yml,build-ios.yml}`：iOS模拟器验证与IPA构建。

用户最新指示：主题必须全页一致，全面排查闪退与多余入口，NAS连接和 NAS Market 行情必须能取数；严格按115项验收，不要拖沓。
