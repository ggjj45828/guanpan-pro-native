# 观盘 NAS：基于你提供的 guanpan2 改造

版本：3.6.0-r29-fx-context-pipeline。保留 Compose 项目 `guanpan-advisor`、默认端口 8789、数据卷 `guanpan_advisor_data` 和真实账本兼容；NAS 只做长期行情研究，不启动虚拟策略 worker，也不提供第二套 AI 交易建议。大模型 API Key 只保存在手机钥匙串，由手机调用；NAS Compose 不接收该密钥。旧 NAS 网页入口已停用，网页文件不会进入镜像。此包不包含 `.env`、API Key 或数据库。

## B版部署标识

- iOS Bundle ID：`com.guanpan.pro.native`；产品可执行名：`GuanpanPro`；显示名：`观盘Max`。
- NAS Compose 项目：`guanpan-advisor`；服务：`advisor`；Compose 未写死 `container_name`，默认生成容器名 `guanpan-advisor-advisor-1`。
- NAS API 默认宿主机/容器端口：`8789`，由 `GUANPAN_ADVISOR_PORT` 同步控制；数据卷：`guanpan_advisor_data`，容器目录：`/data`，SQLite 文件：`/data/guanpan-advisor.sqlite3`。
- 手机真实账本同步：`/v1/real/books/main`；协议健康版本与 `NextBook` 账本 `schemaVersion` 当前均为 `1`。研究走 `/v1/research/{code}` 和 `/v1/mobile/research`，不与真实账本同步混用。
- iOS 本地同步源文件保存在 `Application Support/GuanpanProNative/` 私有目录，恢复副本在 `Application Support/GuanpanProNative-Recovery/`；真实账本文件为 `real-ledger-v1.json`。持仓、资金、成交与收入的事实来源是手机本地账本。NAS SQLite 是同步副本和长期研究存储，不得据其旧快照覆盖更新的手机账本。
- 本仓库的 `nas-sync-server/` 是旧协议兼容/历史目录，不属于当前 B 版安装包。当前 NAS 包格式是 `nas-advisor-compat/compose.yml`、`.env.example`、`README-NAS.md`、`update.sh` 与 `server/`。

本版在 `/v1/research/{代码}` 的 `crossMarket.liveDivergences` 中增加最近15分钟跨市场与该ETF的同窗价格观察。必须有两端新鲜、时间端点相近的真实分钟点；数据过期或时间不齐就标为 `stale` / `insufficient_data`。方向相反只标记为 `observed_divergence`，明确 `eligibleForTradingSignal=false`，不产生预测、策略或交易价格。每条观察含 `expiresAt`；手机在离线使用研究缓存时再次检查到期时间，过期的背离不得进入当次在线AI决策文字。

分钟归档保留每个价格点第一次被 NAS 获取时的快照、来源和时间，同时继续维护最新归档供实时研究使用。历史假设回放只允许使用冻结时点之前首次采到的输入；结果行情按交易所时间戳作为后验标签，不受采集延迟影响。旧数据库无法还原初次采集记录，迁移时按可知的最后采集时间保守标注，较早冻结点会被拒绝使用，从而避免把收盘后补齐的旧行情伪装成当时已知信息。

## 这次改了什么

- 后台只采集手机明确登记的证券和 NAS 真实账本中的正持仓的日 K、分钟行情和分红；历史日K/分时表里的旧代码本身不会继续触发上游请求，也没有写死的示例代码名单。
- 停止虚拟账户 G 和模拟网格的后台线程；相关旧接口返回 410。历史数据库表保留，避免升级时破坏原数据。NAS 的 `/v1/advisor/analyze` 与 `/v1/ai/analyze` 不再生成另一套手机交易指导。
- 增加只读 `/v1/mobile/research`，把 NAS 已归档日 K、分钟覆盖情况和真实时间戳交给手机。腾讯分钟累计成交量的单位尚未核实，接口不把它冒充“股数”或计算 VWAP，因此不会提供具体挂单价。
- NAS 不再请求大模型或保存独立 AI 建议；旧 `/v1/ai/verify` 返回 410。最终 AI 分析只在手机端执行，长期研究接口只返回可追溯统计与研究因素。
- `/health` 中的 `codeVersion` 可用于确认更新真的生效。
- 行情优先使用腾讯，缺失代码回退到东方财富；备用报价必须含上游事件时间戳，过期数据会被丢弃。日 K 超过 30 分钟会尝试更新，源失败时保留归档并标记 `staleArchive`，无归档则返回服务错误。
- `/v1/market/quotes` 对部分缺失代码返回 `missingCodes`；所有来源都没有有效报价时返回 503，不再以空数组伪装成功。

## 与当前手机 App 连接

手机 App 的“我的 → NAS连接”只配置一个 NAS 地址。填 `http://NAS地址:8789`，同一服务负责健康检查、真实账本同步、NAS备用行情、长期研究和分红历史；NAS 本地真实账本只作为同步副本，App 的真实持仓仍由手机账本参与统一决策。App 默认让手机直连报价、日K、盘中分时和新闻，减少 NAS 代理流量；用户也可选择 NAS 优先或仅NAS。连接测试会先读 `/health`，再读真实账本状态。

手机逐只读取 `/v1/research/{code}`，其中 `minuteStats` 是长期研究字段；`/v1/mobile/research` 是可浏览的只读总览接口。分钟量未通过日K交叉校验时统计窗口为空，分钟历史不足60个有效交易日时手机不生成具体做T或网格挂单价。NAS独立负责长期分钟采集和研究；新闻默认由手机直接获取、按证券关联后纳入AI统一指导，来源设置允许时才将NAS作为备用，不需要配置第二个“研究 NAS”。

## 更新前后

1. 备份 NAS 上的 `guanpan_advisor_data` 卷及当前 `.env`。不要将备份或密钥放入本包。此包复用原项目、端口和卷，不要与原容器同时启动。
2. 将本包完整解压到新目录；将自己现有的 `.env` 安全地复制到新目录，核对变量后运行 `docker compose -p guanpan-advisor up -d --build`。不要把 `.env.example` 当成真实密钥。
3. 检查 `docker compose -p guanpan-advisor ps` 和 `logs --tail=100`，再打开 `http://NAS地址:8789/health`，确认 `codeVersion` 是 `3.6.0-r29-fx-context-pipeline`。旧 NAS `.env` 中的模型 Key 可以删去；新容器不读取它。
4. 打开 `http://NAS地址:8789/v1/mobile/research`，应返回 `ok:true` 和 `data.quality.researchSnapshot`；在 App 内执行“测试连接”，并检查 `/v1/research/512480` 是否包含 `minuteStats`。空档案、旧行情或缺量时手机应显示数据不足。
5. 如需回滚，先停止新容器，再以备份的旧代码和原数据卷启动；不要使用 `docker compose down -v`。

NAS Compose 使用 Docker 默认网络，没有设置 `network_mode: none`、自定义 DNS 或 IPv4/IPv6 策略；这只能说明源码没有主动封锁外网，不能证明 NAS 主机、路由器、DNS 或 Docker daemon 实际可访问行情源。容器继承 Docker 主机的系统时钟，当前 `/health` 也不检测时钟偏差。若接口返回 502/503，需要在 NAS 上分别核对 UTC 时间、DNS 解析和到 Tencent/Eastmoney 的 HTTPS 连接；Docker 镜像改用镜像站下载不等于容器的运行时外网一定被封，也不等于一定畅通。

本包 Python 测试覆盖采集对象、行情回退、分钟数据校验和旧入口停用；它们不能替代 NAS 网络和时钟实机诊断。NAS 分时统计已接入手机现有的 `/v1/research/{code}` 解码链路：仅使用分钟量覆盖至少 98%、单日不少于 200 个点、并与独立日 K 成交量差异不超过 1% 的交易日计算 VWAP 和分钟路径往返次数。开发环境对有限样本的行情源验证不能证明 NAS 已积累长期档案。

跨市场分钟采集 worker 使用已验证可返回分钟序列的两个只读上游：腾讯接口采集上证、深证、创业板、科创50、沪深300、中证A500和半导体指数；东方财富趋势接口采集恒生指数、日经225、韩国KOSPI、Nasdaq 100和S&P 500。NAS 在对应市场名义交易时段每5分钟请求一次完整当日分钟序列并按行情原始时间归档，东财北京时间戳会换算为交易所时区（包括美股夏令时），单次异常只标记降级，不覆盖旧的有效档案。连续3次遇到陈旧/非当日响应后暂停该市场当前盘段（含午间前后分段），下一盘段再尝试，避免在休市日重复请求。接口解析会拒绝未来点、非白名单代码和超过10分钟的末笔数据；目前这两个来源对这些指数没有可靠成交量字段，因此该跨市场档案只保存价格，不推算VWAP或交易量。市场时段按交易所时区、午休和美股夏令时计算；没有独立节假日日历，节假日依赖上游时间戳新鲜度拒绝陈旧数据，并可能在NAS状态中显示降级。

r29 新增 NAS 直连的 USD/CNY 上下文采集：工作日每5分钟请求 Sina `fx_susdcny` 的带时间戳买卖价，归档买卖中点及来源；来源时间超过15分钟、来自未来或买卖价无效时一律拒收。它不经手机/NAS穿透隧道，也不增加手机代理流量。`/v1/research/{code}` 会返回 `crossMarket.currencyContext`；该字段只说明汇率与持仓在同一真实时间窗内的变化，缺样本/过期时明确标记，永远不能单独生成做T、网格、买卖方向、候选价格或份额，只能要求手机重新核对风险。

`GET /v1/research/{code}` 会把该证券已归档的分钟数据与各跨市场分钟档案按真实时间戳对齐，计算独立交易日的8个领先窗口和4个前向窗口。对单只持仓一次扫描13个市场时按416种市场/窗口组合做Bonferroni校正。至少100个独立交易日、分段稳定性通过且校正后显著，才标成 `stable_candidate`；样本充分但未通过时明确返回 `no_stable_relationship` 和“没有稳定领先关系”，样本不够则返回 `insufficient_real_archive`。响应只携带逐市场精简摘要，包含来源、交易所最新点、数据年龄、市场状态和样本；跨市场研究量不可信时不参与手机策略定价。

新增的只读历史午休假设回放接口为 `/v1/research/cross-market/replay?leader=KR_KOSPI&asset=512480&start=2026-01-01&end=2026-10-23`，可附加 `leaderShockAtLeast`、`assetMorningAtMost`、`expectedDirection` 和 `minimumSamples`（默认100个独立有效交易日作为最低回放样本数）。它只读取 `cross_market_minute` 外部市场档案和真实持仓ETF分钟档案，12:50冻结假设，13:00之后的实际观测用于验证；目标时点之前的报价不能代替13:00价格。汇总按时间先后保留最后30%作为留出段，比较触发日和数据完整的未触发日，给出Wilson区间与增量效果区间。有效样本总数不足100，或留出段触发/对照各不足30时，`state` 和确认率保持 `insufficient_samples` / `null`；完整样本的命中率另放在 `inSampleConfirmationRate`，不冒充验证结果。只有区间能排除至少5个百分点的实际优势才报告 `no_stable_relationship`（“没有稳定领先关系”）；统计上看似有优势也只标为 `candidate_requires_replication`，不能称为已证实规律。每次回放会返回 `replayId`、生成时间和输入/结果两份规范化SHA-256指纹，并在NAS `research_runs` 独立研究表以确定性 gzip+base64 快照保存完整双边分钟序列、数据来源/采集时间和结果；检索时会分别重算输入与结果指纹，快照或结论损坏/不匹配则拒绝返回。通过 `GET /v1/research/cross-market/runs?limit=20` 可找回最近摘要，再以 `GET /v1/research/cross-market/runs/{replayId}` 取回原始证据复核。无分钟证据时只返回不足说明，不保存空记录。该研究记录不涉及真实账本、资金、持仓或成交。缺数据时不会产生预测结论。目前上游采集器和代码已具备，但当前 NAS 尚未部署、也未积累真实历史档案，不能据此声称日韩与任何ETF存在领先关系。

可变条件研究接口为只读 `POST /v1/research/cross-market/hypothesis`。请求传入 `leader`、真实ETF `asset`、`start`/`end` 和一个受限 `hypothesis` JSON：定义冻结时间、各序列时区、1–8个按分钟窗口计算的 `gte`/`lte`/`between` 条件、预期方向、13:00后验证时点及结果窗口。改变市场经验假设只需换请求里的条件参数，无需新增账户或交易代码；系统不会执行任意脚本。它与午休回放共用不可变证据留档和 `GET /v1/research/cross-market/runs/{replayId}` 检索接口。此接口只读历史分钟档案，没有数据就返回 `insufficient_real_archive`，不会回测虚拟资金或模拟成交。

如需检验尚未发生的市场经验，使用 `POST /v1/research/cross-market/registrations` 保存 `leader`、`asset`、受限 `hypothesis` 与带时区的未来 `notBefore`。服务会生成不可变定义指纹，返回 `awaiting_future_observations` 和 `eligibleForTradingSignal:false`；`GET /v1/research/cross-market/registrations` 及 `/{registrationId}` 只用于复核研究定义。未来窗口结束后，才可向 `POST /v1/research/cross-market/registrations/{registrationId}/evaluate` 提交已经结束的 `start`、`end` 与 `minimumSamples`。接口拒绝预注册窗口之前或当天尚未结束的数据，并沿用冻结回放与证据快照规则。单段未来结果仍只是候选；只有两段互不重叠、且各自通过留出/对照评估的未来样本才会形成 `prospectively_replicated`。任一有效评估显示 `no_stable_relationship` 会保持不可交易并明确否定稳定关系。这个流程只生成研究报告，绝不创建候选订单、虚拟成交或真实账本记录；即使未来复现通过，手机端也只允许它作为短时风险拦截，不能单独生成做T或网格价格。

Docker Desktop daemon 未运行，尚未构建容器；你的 NAS 和 iPhone 连接仍待实机验证。服务无应用登录认证，只能在可信局域网/VPN 使用，不要直接暴露公网。

r23 归档写入会按带时区的抓取时间择新：延迟抵达的旧日K、ETF分钟和外部市场分钟响应不能覆盖较新记录；旧日K仅可补缺失的历史交易日。逐只ETF研究报告新增 `rankedHistoricalCandidates`，只列统计门槛通过的历史候选；未通过来源不显示最佳领先窗口。该排名仍是发现性研究，`eligibleForTradingSignal` 固定为 `false`，验证状态为 `requires_pre_registered_future_replication`。在真实NAS长期归档和预注册未来样本复现完成前，手机不得据此修改做T、网格或加仓建议。
