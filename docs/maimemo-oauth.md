# OAuth 授权与高级配置

首次部署按 [Windows 教程](windows-setup.md)，日常错误按[故障排查](troubleshooting.md)。本页说明凭证边界和可选回退，不是另一套部署流程。

## 本项目的授权方式

OAuth 是在官方页面授权应用访问账号的方式，不要求把墨墨密码交给本项目。OIDC 是它使用的身份认证协议。

- **Access Token**：本次请求墨墨 API 的短期通行证，仅在 Actions 进程内存及子进程环境中使用。
- **Refresh Token**：用来申请新的 Access Token，保存在自己仓库的 `MAIMEMO_OIDC_CREDENTIALS` Secret。它同样是敏感凭证，不应公开。
- **固定 API Token**：另一种授权凭证，不是 Refresh Token，不具备本项目 OAuth 流程的自动续期能力。
- **公共 client ID**：官方 CLI 的应用身份标识，不是个人 Token；不能随意更改它来解决拒绝。

本项目锁定 `@maimemo/memo-api@1.3.1` 和 `openid-client@6.8.4`，使用官方 issuer、公共 client ID 和刷新方式。Windows 首次人工授权用官方 CLI；Actions 使用同一 OIDC 协议在内存刷新，以便检测 Refresh Token 是否轮换，不直接使用会写本地缓存的 CLI 刷新路径。

不需要用户申请开发者应用或设置公网回调地址。官方 CLI 登录会使用本机 `127.0.0.1:18884` 回调，浏览器必须在同一电脑打开。将来若官方客户端策略变化，需要维护者核查兼容性，不能保证永远无需人工处理。

## 凭证的保存与安全边界

1. 官方 CLI 在当前用户的 `.config/memo-api.json` 保存本机授权。不要打印、复制到仓库或分享该文件；不同 Windows 用户的目录不同。
2. [导入脚本](../scripts/import-maimemo-oauth.ps1)从**自身所在 Git 克隆**的 origin 识别目标仓库，核对 GitHub 写权限，要求输入完整仓库名。确认前不读取墨墨凭证；不支持 ZIP 目录，也不使用硬编码仓库。
3. 只把 `rt.token` 与原始 `rt.expireAt` 通过标准输入上传 Secret，不上传整个配置、固定 Token 或缓存的 Access Token。脚本不支持自定义 `MEMO_API_CONFIG_PATH`，请按默认登录流程使用。
4. Actions 每次读取 Secret，在内存刷新，再 GET 核对目标的 ID、名称和响应结构。正式同步通过后才启动 .NET，诊断只启动 GET 审计。
5. Access Token 只通过进程环境变量交给子进程，不进入命令参数、仓库、日志、GITHUB_OUTPUT、授权缓存或构建产物。

同步和诊断的目标统一来自 Repository Variable `MAIMEMO_NOTEPAD_ID`；不解析历史硬编码 ID，不回退到他人的词本。目标名称也核对为 `欧路词典同步（严格）`。

相关工作流共用并发组，不取消正在执行的任务。避免本机或其他仓库同时刷新同一份授权。若服务端返回不同的 Refresh Token，本项目报 `refresh_rotated_stop` 并停止，**不会假装新凭证已持久化**。

<a id="renew"></a>
## 到期或撤销后的重新授权

官方 CLI 1.3.1 在首次授权时记录约 90 天的本地刷新期限，刷新不会自动延长它。这是客户端的记录方式，不是服务端保证的最短可用时间。服务器撤销、账号权限和安全策略也可能提前使其失效。

只有 `refresh_expired_local` 或 `refresh_rejected_reauthorization_required` 等明确凭证问题，才按下面恢复。`oauth_client_rejected` 先看[专门排障](troubleshooting.md#oauth-client-rejected)，不能统一靠重新登录处理。

1. 在 Windows PowerShell 进入原来克隆的项目文件夹，检查 `git remote get-url origin`。
2. 在官方墨墨页面重新登录同一账号：

   ```powershell
   npx.cmd --yes --package=@maimemo/memo-api@1.3.1 memo-api auth login
   ```

3. 确认 GitHub CLI 仍登录自己的账号（`gh api user --jq .login`）；失效时才重做教程中的 GitHub 登录。
4. 导入新凭证，仍输入自己仓库全名确认：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\import-maimemo-oauth.ps1
   ```

5. 检查成功输出和 Secret 更新时间，再运行 **MaiMemo Read-only Diagnostics**。预检通过后等正常定时运行即可，或按需手动运行一次。

无需重建词本，不修改欧路授权、词本 ID 或历史正文。若更换 Windows 电脑，可在新电脑按教程克隆自己的仓库并重新授权；不要通过聊天转移凭证文件。

## 可选：固定 Token 手动回退

普通用户不需要配置这项。只有自己明确选择临时使用仍有效的官方固定 API Token 时：

1. 从墨墨官方支持的渠道获取自己的固定 API Token，按其授权与有效期要求使用；网页/实验功能得到的凭证不要当作 OAuth Refresh Token。
2. 保存为自己仓库的 **Repository Secret `MAIMEMO_TOKEN`**，不能放入 Variable、源码或命令参数。
3. 先按正常只读流程检查数据；如 OAuth 故障使只读流程无法完成，停止并让维护者协助，不因选择 fixed 而跳过安全预检。
4. 手动运行 **Sync Words** 时显式将 `authentication` 选为 **fixed**。它仍然执行真实同步及原有安全校验，不是“尝试登录”按钮。

定时任务默认仍是 OAuth；OAuth 失败不会静默切换。fixed 成功不能证明 OAuth 恢复。固定 Token 失效需自己维护，本项目不抓 Cookie、不模拟登录、不提供长期授权服务。

## 可选：独立只读授权验证与建本工具

**MaiMemo OAuth Verification (preflight + two runners)** 用于维护者验证授权：预检成功后再按依赖顺序运行两台独立 Runner。只刷新及 GET，不验证实际写权限；新手正常预检不要求另外跑它。

**Prepare Strict MaiMemo Notebook** 是保留的手动建本工具，仍需固定 Token，**会创建词本**，不是只读诊断。教程不依赖它。不要在排障时反复创建或让它替换旧词本。

## 旧版本迁移与官方依据

从硬编码 ID 的版本升级前，先把当前完整目标 ID 配置到自己仓库的 Repository Variable `MAIMEMO_NOTEPAD_ID`；不改 Secrets、不重建词本。升级后先只读预检。自己改过工作流时先审阅差异，不直接粘贴其他用户的改动。

依据：[官方 CLI](https://github.com/maimemo/memo-api-cli)、[OIDC 登录与刷新源码](https://github.com/maimemo/memo-api-cli/blob/main/src/lib/oidc.ts)、[开放平台](https://memodocs.maimemo.com/docs/open/)、[API 规范](https://open.maimemo.com/api_bundle.yaml)。服务端实时授权状态不能只靠源码确认，具体未经验证的环节见[本轮验收记录](deployment-feedback.md#verification)。
