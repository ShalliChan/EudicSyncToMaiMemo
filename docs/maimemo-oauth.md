# OAuth 授权与迁移

首次部署见 [README](../README.md)。官方 CLI 固定为 @maimemo/memo-api@1.3.1，刷新使用锁定的 openid-client，沿用官方 issuer 和公共 client ID。公共 client ID 不是个人凭证，不应替换成用户 Token。

## 凭证路径

1. 本机 CLI 将凭证保存到用户目录 .config/memo-api.json，限制本机文件访问权限。
2. 导入脚本从自身 checkout 的 origin 识别 GitHub 仓库，拒绝不支持的地址，核对访问权限并要求输入完整仓库名确认。
3. 确认后才读取凭证，仅将 rt.token 和原始 rt.expireAt 通过标准输入导入当前 Fork 的 MAIMEMO_OIDC_CREDENTIALS。
4. Actions 每次刷新，在内存处理凭证，Access Token 仅交给子进程环境。没有凭证缓存、命令行参数、仓库文件、GITHUB_OUTPUT 或授权产物。

目标 ID 统一来自 Repository Variable MAIMEMO_NOTEPAD_ID。启动器会检查 .NET 目标是否一致，不解析工作流中的历史个人 ID。

## 保护与维护

先刷新并 GET 核对词本 ID、名称和响应结构，再启动原有严格增量同步。诊断入口只启动 GET 审计。

定时与手动默认 oauth。只有显式选择 fixed 才使用固定 Token；OAuth 失败不静默回退。相关任务共用同一并发组，不取消正在执行的任务。避免本机同时刷新同一授权。

CLI 当前按首次登录后 90 天记录本地刷新期限，不在每次刷新时延长。服务器撤销可能提前失效。到期后重新登录和导入，不是永久授权。

| 错误码 | 处理 |
|---|---|
| target_configuration_missing_or_invalid | 检查当前仓库 Variable 和完整 ID |
| target_configuration_mismatch | 核对不同入口目标，不猜测或回退 |
| refresh_expired_local | 本机重新登录并导入 |
| refresh_rejected_reauthorization_required | 授权被拒绝，检查或重新授权 |
| refresh_rotated_stop | 停止，先解决安全持久化，不重复使用旧凭证 |
| refresh_failed_network_or_provider | 不代表过期；保留 Secret，排查网络与服务 |
| target_unauthorized | 停止，核对资源权限 |

单独的 OAuth Verification 工作流仅刷新和 GET，首轮成功后依次检查两台独立 Runner；不执行同步。没有新标题的运行不会 POST，不能单靠成功状态判断写权限。

## 从硬编码 ID 版本安全切换

现有用户在合并前，将目前使用的完整词本 ID 配置为同一仓库的 Repository Variable MAIMEMO_NOTEPAD_ID。不改 Secrets，不重新创建词本。

合并后先只读预检，核对目标、数量和保护指标，再按需手动同步。固定 Token 保留作显式回退。缺少 Variable 时必须失败，不使用旧 ID。

官方参考：[CLI](https://github.com/maimemo/memo-api-cli)、[开放平台](https://memodocs.maimemo.com/docs/open/)、[API 规范](https://open.maimemo.com/api_bundle.yaml)。
