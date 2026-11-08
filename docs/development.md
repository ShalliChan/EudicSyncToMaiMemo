# 开发、本地运行与维护

新用户部署不需要此页的软件或命令，先看 [Windows 教程](windows-setup.md)。本页命令从 Git 克隆的项目根目录运行。

## 测试环境

需要 [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)、Node.js 22，以及 [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)（`pwsh`）。这是开发测试依赖，不是新手本机授权的前置条件。纯导入校验同时支持 Windows PowerShell 5.1。

```powershell
dotnet test src/EudicSyncToMaiMemo.slnx
npm.cmd ci --prefix scripts/maimemo-oauth --ignore-scripts
npm.cmd test --prefix scripts/maimemo-oauth
pwsh -NoProfile -File scripts/test-maimemo-diagnostics.ps1
pwsh -NoProfile -File scripts/test-provision-strict-notepad.ps1
pwsh -NoProfile -File scripts/test-import-maimemo-oauth.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-import-maimemo-oauth.ps1
```

测试使用模拟数据、模拟 HTTP 或本机回环服务，不访问个人词库、不读取真人凭证、不上传 Secrets。`Build and Test` PR 工作流运行这些检查，不等于部署或真实同步成功。

通知是可选功能，`NOTIFICATION_ENABLED` Secret 未配置时传 `false`。显式启用才需要配套 URL 等设置；不应要求首次部署用户创建无用的通知配置。保留已有的通知开关行为，不吞掉非法布尔配置。

## 必须保留的边界

- 不修改欧路原始数据。独立标题提取与安全单向增量合并共用已验证的规则。
- 合法源外历史标题保留，新增集合精确去重；非法行、重复标题及非章节结构不能绕过保护。
- 写前保存完整正文，写后 GET 验证精确追加结果、原文前缀、标题集合和再次零新增；无新增不 POST。
- 诊断资源请求只能 GET。OAuth 刷新服务本身会用协议要求的 POST，不等于词本写入。
- 目标 ID、名称和仓库确认机制不得弱化；OAuth 异常不得回退固定 Token。
- 不记录 Authorization、Token、Refresh Token、完整响应/词本或凭证文件。官方 CLI `--verbose` 会输出请求细节，不适合要求用户公开排障日志。

## 本地控制台、Windows 服务与发布

原 .NET 控制台和 Windows 服务入口保留；配置结构见 [appsettings.json](../src/EudicSyncToMaiMemo/appsettings.json)。直接运行 .NET 或安装 Windows 服务不会自动运行 GitHub OAuth 包装脚本，需要自行提供有效授权和配置，不是本教程的无人值守部署方式。

打包依据 [.github/workflows/release.yml](../.github/workflows/release.yml) 的 `v*` 标签流程。上游发布包不代表本 Fork 的新增功能。授权、工作流或安全规则修改应通过独立 PR 和模拟测试，不使用正式账号反复试写。

部署文档的真实用户反馈、最小技术修复及真人待验项目见[部署反馈记录](deployment-feedback.md)。原作者 viazure 的 [MIT License](../LICENSE) 与署名保留。
