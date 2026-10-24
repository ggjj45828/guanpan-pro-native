# 观盘 NAS：基于你提供的 guanpan2 改造

版本：3.6.0-r14-phone-advisor-research。保留 Compose 项目 `guanpan-advisor`、默认端口 8789、数据卷 `guanpan_advisor_data` 和真实账本兼容；旧 NAS 网页入口已停用，网页文件不会进入镜像。此包不包含 `.env`、API Key 或数据库。

## 这次改了什么

- 后台继续采集已跟踪证券、已有 NAS 真实账本中的持仓的日 K、分钟行情和分红；不再默认采集源码写死的四个示例代码。
- 停止虚拟账户 G 和模拟网格的后台线程；相关旧接口返回 410。历史数据库表保留，避免升级时破坏原数据。NAS 的 `/v1/advisor/analyze` 与 `/v1/ai/analyze` 不再生成另一套手机交易指导。
- 增加只读 `/v1/mobile/research`，把 NAS 已归档日 K、分钟覆盖情况和真实时间戳交给手机。腾讯分钟累计成交量的单位尚未核实，接口不把它冒充“股数”或计算 VWAP，因此不会提供具体挂单价。
- `/health` 中的 `codeVersion` 可用于确认更新真的生效。
- 行情优先使用腾讯，缺失代码回退到东方财富；备用报价必须含上游事件时间戳，过期数据会被丢弃。日 K 超过 30 分钟会尝试更新，源失败时保留归档并标记 `staleArchive`，无归档则返回服务错误。
- `/v1/market/quotes` 对部分缺失代码返回 `missingCodes`；所有来源都没有有效报价时返回 503，不再以空数组伪装成功。

## 与当前手机 App 连接

手机 App 的“我的 → NAS连接”只配置一个 NAS 地址。填 `http://NAS地址:8789`，同一服务负责健康检查、真实账本同步、NAS备用行情、长期研究和分红历史；NAS 本地真实账本只作为同步副本，App 的真实持仓仍由手机账本参与统一决策。App 默认让手机直连报价、日K、盘中分时和新闻，减少 NAS 代理流量；用户也可选择 NAS 优先或仅NAS。连接测试会先读 `/health`，再读真实账本状态。

手机逐只读取 `/v1/research/{code}`，其中 `minuteStats` 是长期研究字段；`/v1/mobile/research` 是可浏览的只读总览接口。分钟量未通过日K交叉校验时统计窗口为空，分钟历史不足60个有效交易日时手机不生成具体做T或网格挂单价。NAS独立负责长期分钟采集和研究；新闻默认由手机直接获取、按证券关联后纳入AI统一指导，来源设置允许时才将NAS作为备用，不需要配置第二个“研究 NAS”。

## 更新前后

1. 备份 NAS 上的 `guanpan_advisor_data` 卷及当前 `.env`。不要将备份或密钥放入本包。此包复用原项目、端口和卷，不要与原容器同时启动。
2. 将本包完整解压到新目录；将自己现有的 `.env` 安全地复制到新目录，核对变量后运行 `docker compose -p guanpan-advisor up -d --build`。不要把 `.env.example` 当成真实密钥。
3. 检查 `docker compose -p guanpan-advisor ps` 和 `logs --tail=100`，再打开 `http://NAS地址:8789/health`，确认 `codeVersion` 是 `3.6.0-r14-phone-advisor-research`。
4. 打开 `http://NAS地址:8789/v1/mobile/research`，应返回 `ok:true` 和 `data.quality.researchSnapshot`；在 App 内执行“测试连接”，并检查 `/v1/research/512480` 是否包含 `minuteStats`。空档案、旧行情或缺量时手机应显示数据不足。
5. 如需回滚，先停止新容器，再以备份的旧代码和原数据卷启动；不要使用 `docker compose down -v`。

当前完成了源码改造、11 项 Python 测试与 Compose 配置校验。NAS 分时统计已接入手机现有的 `/v1/research/{code}` 解码链路：仅使用分钟量覆盖至少 98%、单日不少于 200 个点、并与独立日 K 成交量差异不超过 1% 的交易日计算 VWAP 和分钟路径往返次数。开发环境对四只 ETF 的真实 Tencent 分钟量与日 K 成交量抽样差异均小于 1%；这只是有限样本，不代表 NAS 已积累长期档案。此前从开发环境实测腾讯报价和 640 根日 K 返回。Docker Desktop daemon 未运行，尚未构建容器；你的 NAS 和 iPhone 连接仍待实机验证。服务无应用登录认证，只能在可信局域网/VPN 使用，不要直接暴露公网。
