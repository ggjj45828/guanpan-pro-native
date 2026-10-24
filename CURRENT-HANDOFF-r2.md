# 观盘 Pro v2.13.55 升级候选 r2：编译交接

此文件属于 r2 历史交接说明，已由 `CURRENT-HANDOFF-r3.md` 和 `Master Acceptance Matrix.md` 取代。不要按本文件中的旧模拟引擎、独立 NAS worker 或旧布局指引继续开发；当前方向是一个真实账户、手机唯一 AI 指导、NAS 长期行情研究。

## 内容与验证
- guanpan-pro-native：iOS 源码、共享 JavaScript 模拟核心与研究模块、XcodeGen 配置、Apple 运行时单元测试。
- nas-sync-server：NAS Python 服务、独立三通道存储、历史行情存储、Node 虚拟交易执行器及网页。
- Experimental：此前模拟核心原型，保留参考，尚未执行 Swift 测试。
- tests：可复现离线测试；docs/validation 为本次实际运行日志。
- 本次 Node 测试 75 项通过，Python 测试 39 项通过，模拟示例通过。测试只使用合成数据和临时数据库。
- iOS/Xcode 编译、Apple 单元测试、真机运行、Docker 构建、实际 NAS 部署、实时行情与在线 AI 调用尚未验证。不能把代码存在等同于功能验收完成。

## 编译步骤
在 macOS 安装 Xcode 与 XcodeGen，在 guanpan-pro-native 下运行 `xcodegen generate`，打开生成的 GuanpanProNative.xcodeproj。先运行 GuanpanProValidation 的模拟器测试，再检查 GuanpanProNative 应用。仓库根目录 .github/workflows/validate-ios.yml 提供手动触发的 macOS Actions 编译与测试流程；需把整个压缩包内容放在仓库根目录，不能只上传 iOS 子目录。尚未替用户上传或触发远程构建。

本地 NAS 检查可运行 `python tests/run-validation.py`。旧版本的 Node 虚拟策略 worker 已从 Compose 部署清单移除；当前以 `CURRENT-HANDOFF-r3.md` 和 `Master Acceptance Matrix.md` 为准。

## 已新增但需要继续核对的部分
五项导航、场外基金只读归档、三通道状态、真实资产手动同步预览、虚拟账户与资金流、分批限价与手续费版本、A–G 研究策略、离线顾问及现有 AI 服务调用入口、行情归档与虚拟自动执行均有候选代码。不能据此声称所有完整需求已实现。

编译接手时优先检查 Swift 类型和 actor 隔离、XcodeGen 资源打包与测试宿主；所有新 Swift UI 尚未编译验证。顾问默认上下文可能使用已有虚拟快照，需要继续核对是否应始终读取当前真实资产；AI JSON 提案审核函数新增后尚无专项测试。全市场雷达目前仅分析已提供的标的范围，未建立完整市场数据源。在线模型建议、五档供应商字段与数量单位、公告/基本面/ETF 穿透数据、自动定期入金及分红调度、交易日规则完整覆盖、历史缺口自动发现仍需补全或实测。策略进化为研究候选评估，不代表自动上线已验证。

盘口数据缺失时不能假设低价触及即全额成交；供应商五档采集须显式确认 V2_BOOK_VOLUME_MULTIPLIER，默认不猜单位。ETF 每笔成交手续费默认 0.10 元、额外滑点 0；股票佣金率仍待用户确认。实际证券交易必须由用户决定。

## 数据保护
包内不含用户真实 SQLite 数据库、WAL/SHM、真实持仓备份或 API 密钥。不要使用新包覆盖现有 NAS data 目录。先完整备份现有数据库及 WAL/SHM，在独立测试目录/端口部署。真实资产仅可由用户明确操作同步；模拟不得写入真实账本。保留所有历史场外基金数据，不直接删除。请不要因编译失败推倒重写原工程或删去成熟行情、图表、主题功能。
