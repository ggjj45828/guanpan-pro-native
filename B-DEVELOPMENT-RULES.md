# B版开发与跨电脑恢复规则

B版是 Master Acceptance Matrix 独立路线。A/B源码、配置、测试证据和备份目录严格隔离；不得读取A版实现作为B的代码来源，不得merge或cherry-pick。

## 三层保存

1. **B自己的Git远程源码**：当前远程为B专属仓库。每个checkpoint核对本地HEAD、远端分支commit和推送结果；不得用历史推送记录推断最新提交已备份。
2. **NAS上的B独立灾备**：建议目录 `/guanpan-development/B/latest/` 保存 `B-LATEST.zip`、`B-STATUS.md`、`B-MASTER-ACCEPTANCE-MATRIX.md`，旧快照放 `/guanpan-development/B/archive/`。此目录不得与真实账本、行情数据库或生产研究数据混用。
3. **Project Files可检索checkpoint**：项目根目录持续维护 `B-LATEST.zip`、`B-STATUS.md` 和唯一最新矩阵 `B-MASTER-ACCEPTANCE-MATRIX.md`。旧矩阵明确标为 Historical/Superseded。

## 关机或换电脑前

检查工作树和重要修改；运行当前环境可运行的测试；提交并记录HEAD；推送B远程并确认远端确实含该commit；更新Matrix与B-STATUS；生成对应commit的B-LATEST.zip；NAS可用时只同步B版快照文件；记录精确续接断点。NAS不可用要如实记下，不能声称灾备完成。

安全关机至少需要一份脱离当前电脑的最新源码副本：已验证的B远程commit或NAS完整源码快照。两者都无法确认时，必须明确提示：**“B版最新工作仍仅存在当前电脑，不满足安全关机条件。”**

换电脑优先clone/pull B远程，checkout `B-STATUS.md`指定commit，核对Matrix与测试状态后从开发断点继续；Git不可用时从NAS解压对应B快照并核对commit。不得依赖旧电脑的绝对路径。

## 验收口径

快照、commit、远端存在性和NAS备份状态只代表可恢复性，不改变功能验收状态。代码存在不等于功能可用；测试定义不等于执行；旧commit通过不等于当前版本通过；External Pending不等于通过；A版证据不属于B版证据。checkpoint后若当前环境仍有可推进缺口，立即继续开发。
