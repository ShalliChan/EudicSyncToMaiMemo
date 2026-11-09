# 故障排查

回到[Windows 部署教程](windows-setup.md)。先找到**失败的步骤和错误码**，再做对应处理。不要反复重跑真实同步、删除正常词汇、清空词本或修改工作流来绕过检查。

<a id="terminal"></a>
## 命令找不到、终端与执行策略

| 现象 | 检查与处理 |
|---|---|
| `git` 无法识别 | 安装 Git for Windows，确认允许从命令行使用；关闭所有旧终端再开 |
| `gh` 无法识别 | 安装的是 **GitHub CLI**，不是只安装 Git、GitHub Desktop 或浏览器；重开窗口后 `gh --version` |
| `node`、`npm`、`npx` 无法识别 | 安装 Node.js 22，保留 npm 和 PATH 选项；重开窗口后依次检查版本 |
| `npm.ps1` / `npx.ps1` 无法加载，因为系统禁止脚本 | 使用教程的 `npm.cmd` / `npx.cmd`，不需要永久放宽执行策略 |
| `pwsh` 无法识别 | 它是另装的 PowerShell 7；新手导入使用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\import-maimemo-oauth.ps1`，无需安装 7 |
| `Set-Location`、`$HOME` 在 CMD 中报错 | 在开始菜单打开 **Windows PowerShell**，按教程重新进入克隆文件夹，不要混用不同终端的语法 |
| 找不到 `scripts\import-maimemo-oauth.ps1` | 执行 `Get-Location` 和 `Test-Path .\scripts\import-maimemo-oauth.ps1`；应在克隆的项目根文件夹，Test-Path 为 True |
| `not a git repository` / 没有 origin | 当前可能是 ZIP 解压目录或路径不对；用 Git 克隆自己的 Fork，不能靠新建空 `.git` 修复 |
| 组策略禁止脚本 | 单次 Bypass 不能越过组策略；联系设备管理员，不改注册表或永久关闭限制 |

在 Windows PowerShell 可运行 `Get-Command git,gh,node,npm.cmd,npx.cmd` 检查命令位置；不要在输出中附带环境变量。若已安装却找不到，先重启终端/电脑、检查安装选项，避免照抄别人的个人安装路径。

<a id="network"></a>
## GitHub 登录、下载或第三方连接失败

`failed to authenticate via web browser` 伴随 `dial tcp`、`connectex`、连接超时，通常表示**连接尚未完成**，不能据此判断授权码错误。换 CMD 不会解决同一网络连接故障。

1. 用浏览器分别打开 [GitHub](https://github.com/)、[GitHub 设备授权页](https://github.com/login/device)、[npm](https://www.npmjs.com/) 和[墨墨账号站点](https://accounts.maimemo.com/)。确认系统时间正确。
2. 在 Windows PowerShell 只测试域名和端口，不带凭证：

   ```powershell
   Test-NetConnection github.com -Port 443
   Test-NetConnection api.github.com -Port 443
   Test-NetConnection registry.npmjs.org -Port 443
   Test-NetConnection accounts.maimemo.com -Port 443
   ```

3. `TcpTestSucceeded=True` 只说明能建立 TCP 连接，不保证 HTTPS、登录或 API 成功。检查网络、防火墙及单位网络规定；可换一个允许访问相关服务的网络，或请网络管理员检查。浏览器与终端也可能使用不同网络设置。
4. 如果你自己已使用合法的代理/网络工具，按其官方文档检查终端设置；本项目不要求统一使用某个代理、端口、IP 或“全局模式”。不要关闭 TLS 证书校验或公开完整网络环境。
5. 连接恢复后只重做失败的登录步骤；不要重建词本或更换不相关的授权。

<a id="maimemo-login"></a>
## 墨墨本机登录失败

使用教程固定的 `npx.cmd --yes --package=@maimemo/memo-api@1.3.1 memo-api auth login`。浏览器应在运行命令的同一台电脑上打开，命令窗口保持运行。

- 端口 `18884` 被占用：先关闭之前未结束的登录命令（回到对应窗口按 Ctrl+C），再尝试一次。不要终止不认识的系统进程。
- 登录超时：CLI 的登录窗口约 10 分钟有效。先确认网络正常，再重新发起一次；旧授权链接不要再用。
- 回调页面打不开：检查本机安全软件是否阻止回环地址 `127.0.0.1`，不要把回调地址改成别人提供的服务器。
- 账号不符：只在官方页面选择自己拥有目标词本的墨墨账号；不要上传别人或其他 Windows 用户的凭证。
- 客户端被拒绝：看下一节，不能直接认为是用户凭证过期。

<a id="oauth-client-rejected"></a>
## oauth_client_rejected：不是欧路授权错误

看到：

```text
target_configuration_valid=1
oauth_sync_failed=oauth_client_rejected
```

第一行只证明目标 ID 的**配置格式**通过，还没有证明墨墨授权成功或词本可以访问。

第二行来自 [verify.mjs](../scripts/maimemo-oauth/verify.mjs) 的刷新阶段：只有官方 OIDC 库返回 OAuth `invalid_client` 或 `unauthorized_client` 才映射为这个错误。此时还没有启动 .NET 同步，也没有访问欧路或写入词本。

这里的“客户端”是向墨墨申请令牌的应用身份，**不是你的欧路账号，也不是目标词本 ID**。可能涉及墨墨客户端注册/安全策略或客户端与服务端兼容性；仅凭这两行日志，无法确认具体服务端原因。重新填欧路授权、改词本名、改 ID 都不能修复客户端拒绝。

### 已核对的事实与安全的下一步

- 截至 2026-11-08，本项目锁定官方 `@maimemo/memo-api@1.3.1` 和 `openid-client@6.8.4`；issuer、公共 client ID 和 `discovery → refreshTokenGrant` 调用与官方 CLI 1.3.1 源码一致。没有发现应由用户修改客户端参数的证据。
- 官方[此前 Issue #4 的回复](https://github.com/maimemo/memo-api-cli/issues/4#issuecomment-6286243219)解释过一次安全策略升级，并要求更新至 1.3.1；那次是**刷新成功后的资源 GET 401**，不能据此断言本次刷新阶段的客户端拒绝已解决。
- 先确认失败记录的 **Workflow file / commit** 属于当前项目版本，而非复制粘贴改过的工作流；检查自己的 Fork 是否落后。在合并上游更新前阅读差异，不直接降低 Actions 或 .NET 版本。
- 交给维护者的最小信息：发生时间、失败的步骤、上述错误码、运行链接、代码提交版本。不要附 Token、Secret、授权链接、验证码、完整词本或原始 HTTP 响应。
- 维护者应对照[官方 OIDC 源码](https://github.com/maimemo/memo-api-cli/blob/main/src/lib/oidc.ts)和[版本信息](https://github.com/maimemo/memo-api-cli/blob/main/package.json)，向墨墨确认客户端策略。若需要官方 CLI 对照，在用户本机用教程的 `notepad list --fields id,title,status` **只读**运行一次，不加 `--verbose`，只报告是否成功和脱敏错误码。CLI 可能复用尚有效的 Access Token，因此一次 list 成功**不证明**刷新端点已恢复。
- 官方 CLI 1.3.1 自身还会优先使用已配置的固定 API Token，并将多种刷新异常统一提示为“登录已过期”。因此它的成功或“过期”提示都不能单独证明 OAuth 刷新结果；不要删除凭证或开启 verbose 强行取证，维护者需结合本项目已分类的错误码判断。
- 在没有明确恢复依据前，暂停真实同步并保留现有配置；不要反复重新授权、修改 client ID/scope、关闭安全检查或静默切换固定 Token。确认兼容性已恢复后，先运行只读诊断，再恢复正式同步。

本轮未使用真人凭证复现这个服务端拒绝，也没有声称已修复它。能静态确认的是错误归类和客户端实现一致；具体服务端原因仍需官方或受影响用户验证。

## 按错误阶段处理授权问题

| 错误/阶段 | 含义 | 下一步 |
|---|---|---|
| `credentials_missing` | 当前仓库没有可用的墨墨 OAuth Secret | 检查 Secrets 名称和所在仓库，按教程导入 |
| `credentials_invalid` | 已保存凭证形状无效 | 使用官方本机登录与导入流程，不手工拼 JSON |
| `refresh_expired_local` | CLI 记录的本地到期时间已到 | 按[重新授权步骤](maimemo-oauth.md#renew)登录、导入，再只读预检 |
| `refresh_rejected_reauthorization_required` | 刷新收到 `invalid_grant`：凭证失效、撤销等 | 重新授权并导入；不保证能从该码分辨撤销还是到期 |
| `oauth_client_rejected` | `invalid_client` / `unauthorized_client` | 按上节核查客户端，不能统一当过期处理 |
| `refresh_rotated_stop` | 服务端返回不同的 Refresh Token | 停止，联系维护者先解决安全持久化；不要继续用旧凭证重跑 |
| `refresh_failed_network_or_provider` | 发现服务/刷新发生其他异常 | 可能是网络、服务端或其他未分类拒绝；不代表必然过期。保留 Secret 和错误码，不打印原始异常 |
| `target_unauthorized` | 已刷新，但墨墨目标 GET 返回 401 | 核对墨墨授权账号、资源权限和官方兼容性；不是欧路授权 |
| `target_configuration_missing_or_invalid` | `MAIMEMO_NOTEPAD_ID` 缺失或格式不符 | 在 Repository **Variables** 设置完整 `np-` ID，排除空格、引号、截断 |
| `target_configuration_mismatch` | 同一运行的目标配置不一致 | 停止，核查是否手改工作流；所有常规入口应使用同一 Variable |
| `target_identity_or_shape_mismatch` | GET 返回 ID/名称/结构未通过核对 | 确认目标名称为 `欧路词典同步（严格）`、ID 和账号正确，不随意改 ID |
| `target_request_failed` / `target_api_rejected` | 墨墨目标请求失败或业务拒绝 | 记录脱敏错误码和阶段，停止写入；不要猜着换 API 路径 |
| 欧路读取阶段返回 401/403 或授权配置错误 | `EUDIC_AUTHORIZATION` 对欧路不可用 | 重新从欧路官方页获取自己的完整 Authorization，仅更新对应 Secret |

<a id="import"></a>
## OAuth 凭证导入停止

导入脚本有意不转发底层错误正文，以免泄露凭证。按下面顺序检查：

1. `Get-Location`、`Test-Path .\scripts\import-maimemo-oauth.ps1`，确认在正确的 Git 克隆中。
2. `git remote get-url origin` 必须是自己的 GitHub HTTPS/SSH 仓库地址。ZIP、无 origin、其他主机或带内嵌凭证的 URL 都不支持。
3. `gh --version`、`gh api user --jq .login` 检查 CLI 和当前账号；未登录才重做 GitHub 登录。自己的 Fork 页面应有 Settings，账号应有写权限。
4. 在 `Target repository:` 后确认账号/仓库名；输入必须与显示的完整名称、大小写一致，不能只回 `Y`。取消或输错会在读取墨墨凭证前停止。
5. 确认墨墨官方 CLI 登录是在同一个 Windows 用户中成功完成，没有设置自定义 `MEMO_API_CONFIG_PATH`。本导入脚本只读默认用户目录的凭证，不猜其他文件路径。
6. 网络恢复或确认步骤修正后，再导入一次，检查 `oauth_credentials_uploaded=1` 和 Repository secrets 名称是否存在。不要发送凭证文件供他人检查。

<a id="preview"></a>
## 诊断、同步和词本内容

- **绿色诊断不等于可以写入**：预览可能成功报告 `ready=0`。还要按[指标表](windows-setup.md#7-首次只读预检)检查安全条件。
- **`extra > 0`**：保留的合法历史标题，不是错误；无需删除。`current_set_equal=1` 在增量模式下表示有效源标题已全部包含，不要求 extra=0。
- **`ready=0` / `target_chapter_mode=0`**：目标正文不符合章节模式等条件。新建空本应仅以 `# 欧路词典同步` 开头；已有本保留原文，先检查原因，不清空或覆盖。
- **`target_duplicates` / `invalid_lines` 大于 0**：安全保护会阻止正式写入。先只读核查，未经确认不删历史词或放宽规则。
- **控制字符 / `notepad_invalid_char`**：保留脱敏错误码，运行只读检查。不要全局删除 `$`、数字、标点或正常短语；源数据、转换和服务端错误文本要分别判断。
- **写后 GET 校验失败或写入时连接中断**：服务端可能已处理写入。停止重试，先做只读检查；不自动覆盖、回滚或重建。
- **`would_add=0`**：没有需要新增的标题是正常结果。该次不会 POST，不能声称已验证写权限；无需反复运行来验证。
- **App 有关联短语、词形或“自编此单词”**：App 解析层与原始正文不同，不据此删减正常源标题。项目不自动生成释义，部分词需在 App 内提交。
- **`Failed to convert configuration value ... Notification:Enabled ... Boolean`**：旧工作流在没有通知 Secret 时传空字符串。本版本已为未配置通知默认传 `false`；更新项目即可，普通用户不用建通知 Secret，也不用改 YAML。
- **`***` 遮罩**：与 Secret 重合的普通数字也可能被遮住，正常现象。不关闭 Secret 遮罩、不公开凭证或正文来获取“完整日志”。

## Actions 按钮或定时记录找不到

- 在自己的 Fork 操作，先启用 Actions；手动运行按钮在所选工作流页面右侧，不在 Settings。
- `Sync Words` 已 Disabled 时先按教程启用；选择 main。项目正式同步只允许 main，其他分支运行可能被跳过（Skipped），不算成功。
- `Build and Test` 只运行自动化测试，不会同步词库。`Prepare Strict MaiMemo Notebook` 会创建词本，不是诊断。
- 自动任务已在 workflow 中配置。手动运行不会另外创建定时器；电脑不用常开。
- 定时可能延迟或因长期无仓库活动被停用，见[自动运行检查](windows-setup.md#9-确认每天自动运行)。不要以修改 cron 或连续点击 Run workflow 来处理平台排队。

## 提交问题时提供什么

建议只提供：步骤编号、Windows/Node/Git/gh 版本、工作流及步骤名、运行链接、错误码和保护指标、发生时间。不提供真实凭证、OAuth 链接、一次性码、完整 ID 或词本正文。截图先遮住个人账号路径及授权信息，保留错误文字；不需要仿照别人的日志词数。
