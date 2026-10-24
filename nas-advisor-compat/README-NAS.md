# 观盘 NAS：基于你提供的 guanpan2 改造

版本：3.6.0-r14-phone-advisor-research。保留原 Compose 项目 `guanpan-advisor`、默认端口 8789、数据卷 `guanpan_advisor_data`、原网页和真实账本。此包不包含原压缩包内的 `.env`、API Key 或数据库。

## 这次改了什么

- 后台继续采集已跟踪证券、已有 NAS 真实账本中的持仓的日 K、分钟行情和分红；不再默认采集源码写死的四个示例代码。
- 停止虚拟账户 G 和模拟网格的后台线程；相关旧接口返回 410。历史数据库表保留，避免升级时破坏原数据。NAS 的 `/v1/advisor/analyze` 与 `/v1/ai/analyze` 不再生成另一套手机交易指导。
- 增加只读 `/v1/mobile/research`，把 NAS 已归档日 K、分钟覆盖情况和真实时间戳交给手机。腾讯分钟累计成交量的单位尚未核实，接口不把它冒充“股数”或计算 VWAP，因此不会提供具体挂单价。
- `/health` 中的 `codeVersion` 可用于确认更新真的生效。

## 与当前手机 App 连接

App 的“数据与同步”中，**真实账本同步地址**继续使用原来能提供 `/api/native/data` 的服务。新增“只读研究 NAS 地址”填 `http://NAS地址:8789`。手机从 guanpan2 只读历史研究；真实持仓仍以手机账本为准。若没有原生同步服务，可暂时只在手机保存真实账本，不能把 guanpan2 的旧账本当作已自动同步到手机。

`/v1/mobile/research` 是只读过渡接口，并不声称旧 guanpan2 已实现当前 App 的 `/api/native/data`、`/api/v2/channels/assets`、`/api/v2/channels/quant` 协议。旧 NAS 研究结果也不含已核验的逐分钟成交量/盘口，不会单独产生做 T 或网格价格。

## 更新前后

1. 备份 NAS 上的 `guanpan_advisor_data` 卷及当前 `.env`。不要将备份或密钥放入本包。此包复用原项目、端口和卷，不要与原容器同时启动。
2. 将本包完整解压到新目录；将自己现有的 `.env` 安全地复制到新目录，核对变量后运行 `docker compose -p guanpan-advisor up -d --build`。不要把 `.env.example` 当成真实密钥。
3. 检查 `docker compose -p guanpan-advisor ps` 和 `logs --tail=100`，再打开 `http://NAS地址:8789/health`，确认 `codeVersion` 是 `3.6.0-r14-phone-advisor-research`。
4. 打开 `http://NAS地址:8789/v1/mobile/research`，应返回 `ok:true` 和 `data.quality.researchSnapshot`。空档案、旧行情或缺量时手机应显示数据不足。
5. 如需回滚，先停止新容器，再以备份的旧代码和原数据卷启动；不要使用 `docker compose down -v`。

当前只完成源码改造、Python 测试和 Compose 配置校验。尚未在你的 NAS 上构建容器、连接真实行情或与真机联调。服务无应用登录认证，只能在可信局域网/VPN 使用，不要直接暴露公网。
