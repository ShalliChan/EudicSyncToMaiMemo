# 部署反馈核查与验收记录

依据：[Issue #2](https://github.com/ShalliChan/EudicSyncToMaiMemo/issues/2)、[反馈者固定提交 README（60792b1）](https://github.com/Q-ParametricLab/EudicSyncToMaiMemo/blob/60792b1d6fd88ee11e65ef99b82cff9865ab389c/README.md)。已阅读全文、括号问题、命令、工作流修改建议及其中 10 张截图。Issue 本身只有反馈链接，没有额外评论。

反馈反映的成功/失败是用户当时的记录；本轮没有用任何人的真实账号重做授权或同步。未复制反馈者的工作流代码，也未把他尝试的修复直接当作结论。

## 问题分类与对应修改

分类：**A** 解释不足，**B** 步骤缺失/顺序问题，**C** 文档与代码不一致，**D** 真实技术问题，**E** 反馈中的理解或解决方案有误。一个问题可属于多类。

| 反馈问题 | 分类 | 核查结论与修改位置 |
|---|---|---|
| 不清楚 GitHub 怎样连接欧路、墨墨，想看完整图示 | A | [README](../README.md) 增加 Mermaid 数据流；区分云端执行、授权、只读和写入路径 |
| 没有先安装软件，npx/git/gh 无法执行 | B | [教程第 1 步](windows-setup.md#1-安装软件并打开正确的窗口)列出三项必装软件、官方入口、安装选项、检查命令 |
| Git 与 GitHub CLI 被混为一谈 | A | 软件表区分 Git、gh；[术语说明](windows-setup.md#2-fork-到自己的-github-账号)区分仓库操作 |
| npm/npx 是什么、是否另装 | A | 说明随 Node 安装；固定 Node 22，与云端一致 |
| 终端安装后仍不识别命令 | B | 明确关闭旧窗口重新打开；[终端排障](troubleshooting.md#terminal)提供 Get-Command 检查 |
| PowerShell 不工作便改 CMD，语法与路径混用 | A、B、E | 统一 Windows PowerShell；使用 npx.cmd 避免 `.ps1` 执行策略冲突，换 CMD 不作为通用修复 |
| README 用 pwsh，但 Windows 没有这个命令 | B、C | 新手改用自带 powershell.exe；导入纯校验在 5.1 和 7 验证，CI 同时覆盖，不要求安装 7 |
| 建议 Bypass，但不了解影响 | A | [导入步骤](windows-setup.md#5-将墨墨授权安全导入自己的仓库)解释仅一次子进程，需先信任脚本；不永久改策略，不绕过组策略 |
| 把 Fork 理解为分支，照抄作者 Clone 地址 | A、E | 解释 Fork 是自己账号下的仓库副本；从自己 Code → HTTPS 复制，不克隆作者地址 |
| “直接下载源代码也可以” | C、E | 导入依赖 Git origin，ZIP 不可互换；教程明确原因和不覆盖的恢复办法 |
| cd 的作用、个人路径中的内容不明 | A | 用 Set-Location $HOME 及相对文件夹；Get-Location、Test-Path 逐步验证，不保留个人路径 |
| 不理解 git remote get-url origin 的目的 | A | origin 决定凭证上传目标；在 Clone 和导入前两次检查 |
| 墨墨 npx 登录的目的、链接、成功标志不明 | A、B | [教程 4.1](windows-setup.md#41-墨墨-oauth-登录)说明官方页面、同机回调、终端与浏览器成功后再继续 |
| GitHub CLI 的 Y/n、设备验证码和网页流程不明 | A、B | [教程 4.2](windows-setup.md#42-github-cli-登录)逐步解释，明确登录自己的 Fork 账号和安全的账号名检查 |
| GitHub device/code 连接超时，建议所有人 VPN 全局模式或统一 IP | D 待证、E | 截图证明连接失败，不能证明应用缺陷；[网络排障](troubleshooting.md#network)用官方域名/TCP 检查，不推广特定网络方案 |
| 把 import 脚本理解为连接墨墨数据库 | E | 导入只上传已有刷新凭证，不读取学习词库；正文写入在后续正式同步 |
| 不理解为何输入完整 owner/repository | A | 解释目标仓库、写权限、大小写及 Enter 取消，保留现有确认机制，不弱化校验 |
| “出现 Secret”说得太笼统 | A | 给出 Settings → Secrets and variables → Actions → Secrets → Repository secrets，名称与成功输出对照 |
| 新词本初始正文只要 # 后随便写一个字 | A、E | 展示准确的 `# 欧路词典同步`（含英文空格），解释章节用途；不是让用户在终端执行 |
| “改名可能改变 ID”，不清楚为何保留旧本 | C、E | 不采信无依据的 ID 变化结论；代码确实核对完整名称，故必须保留正确名称；其他词本不受本同步管理 |
| 不清楚完整 np-ID、截断 ID 与网页数字 ID | A | [教程 6.1](windows-setup.md#61-创建或确认专用墨墨云词本)使用 CLI 显式字段、分页、名称同一行核对；不输出正文 |
| 欧路 Authorization 在哪取、如何填 | A、B | [教程 6.2](windows-setup.md#62-配置两个欧路-secrets)对应截图“获取授权”，说明完整字符串、不自行加 Bearer；不展示真实值 |
| Secret、Variable、两个 Book/Notepad ID 混淆 | A | [教程第 6 步](windows-setup.md#6-配置欧路授权和墨墨目标)逐项填写、四项检查表，解释类型与用途 |
| 不清楚 Actions 入口、Run workflow、日志在哪 | A、B | [第 7、8 步](windows-setup.md#7-首次只读预检)分别给出 workflow → job → step 名，先诊断再同步再诊断 |
| 诊断段落截图实际是 Sync Words #6 | E | 明确两个工作流不同，Build and Test 也不代表同步；不复用该截图作为只读成功示意 |
| “有错需要修改 workflow”并降级 checkout/setup-dotnet、改 .NET 版本 | D 待证、E | 未发现需要这些降级的证据；项目实际使用 .NET 10，保留 Actions 版本，不照抄反馈 YAML |
| 用户给通知 Enabled 增加 false 兜底 | C、D 已确认 | 确认缺失 Secret 会形成空字符串，.NET 绑定 bool 报错；只在 sync.yml 为缺失值默认 false，配配置行为测试及工作流回归测试 |
| 不懂 ready/would_add/missing/extra 等 | A | [第 7 步指标表](windows-setup.md#7-首次只读预检)解释每项、首次与同步后的不同要求、遮罩与停止条件 |
| 以绿色任务或无新增当作写权限已验证 | A、E | 首次同步验收要求真实新增时写后 GET；无新增不强行写、不重复测试 |
| 以为点击手动同步就是启动每日计划 | A、E | [第 9 步](windows-setup.md#9-确认每天自动运行)解释两个触发入口、Fork 启用、schedule 记录、电脑关机与调度延迟 |
| 几天后 oauth_client_rejected，该换墨墨还是欧路授权 | C、D 待证 | [专项排障](troubleshooting.md#oauth-client-rejected)定位为刷新客户端拒绝，核对官方客户端一致；服务端原因未证实，不能称 Token 过期或声称已修好 |
| 不懂固定 Token 的意义，高级命令干扰主流程 | A | [高级授权文档](maimemo-oauth.md)说明手动回退及限度；测试/本地服务迁入[开发文档](development.md) |

## 实际技术改动范围

- `.github/workflows/sync.yml`：`Notification__Enabled` 的空配置默认 `false`，显式配置行为不变。不改定时、认证选择、目标 Variable 或词条规则。
- `.github/workflows/build.yml`：增加 Windows 自带 PowerShell 5.1 的纯导入校验测试；已有 PowerShell 7 检查保留。
- `scripts/maimemo-oauth/run-sync.test.mjs`：通知缺失默认值回归检查。
- `scripts/maimemo-oauth/verify.test.mjs`：同时覆盖 invalid_client 与 unauthorized_client，确认只进入刷新、不访问资源，错误正文不泄露。
- `src/EudicSyncToMaiMemo.Tests/Helpers/NotificationConfigurationTests.cs`：复现空布尔值绑定失败，并验证显式 false/true；无真实授权、网络或同步。

未修改 import、OAuth 刷新实现、严格标题提取、合并、写后 GET 或只读保障。`oauth_client_rejected` 的确定来源是程序对两种官方错误的归类；未发现可在本轮安全修复的客户端参数错误。

## 文档文件分工

| 文件 | 内容 |
|---|---|
| [README.md](../README.md) | 项目入口、图示、边界、准备、成功标准和索引 |
| [windows-setup.md](windows-setup.md) | 唯一的 Windows 新手顺序教程 |
| [troubleshooting.md](troubleshooting.md) | 按症状/阶段处理错误，不重复完整部署命令流 |
| [maimemo-oauth.md](maimemo-oauth.md) | 授权边界、重新授权、可选固定 Token 与高级工具 |
| [development.md](development.md) | 开发测试、本地程序、Windows 服务及维护边界 |
| 本文 | 反馈逐项核查、技术修复和真人验收清单 |

截图已逐张核查：部分包含账号、本地路径、授权链接或设备一次性码；没有复制到新文档。以文字步骤和原生 Mermaid 为主，不伪造操作截图或成功日志。截图中的按钮用于对照，不承诺未来第三方界面不变。

<a id="verification"></a>
## 自动化检查与验证限度

本轮已执行：83 项 .NET 测试、30 项 OAuth/启动器 Node 测试、107 项只读诊断检查、20 项建本模拟检查、11 项导入纯校验（分别在 PowerShell 7 与 Windows PowerShell 5.1 运行）。均用模拟或回环数据，没有真人凭证；严格同步原测试保留。

文档还核对了相对路径、交叉引用、代码块、PowerShell 5.1 语法、工作流/步骤/变量名和官方 CLI 参数。CLI 的 list/create `--help` 在隔离的空配置下检查，不执行创建或真实查询。CLI 1.3.1 的 `--version` 本地显示 unknown，因此依据包的 package.json 和自动化检查确认版本，不把这个输出当成授权失败。**不将这些检查描述为全新机器上的端到端部署成功。**

尚需真人验证：

- 干净 Windows 上安装包的实际界面及新 PATH 生效；不同架构/受管设备情况。
- 墨墨与 GitHub 的浏览器登录、设备验证码、权限页面和真实 Secret 上传。
- 当前手机 App 创建云词本的具体入口、官方创建命令在本人账号的结果及完整 ID 查询。
- 欧路授权页登录后的当前界面、自己的默认生词本范围。
- 首次真实新增后的 GET 校验、手机显示，以及后续由 schedule 触发的运行。
- 受影响账号的 oauth_client_rejected 服务端原因及官方恢复状态。

本轮没有使用维护者或反馈者的真实账号、Secret、词库；没有触发同步或改授权。既有依赖 AngleSharp 的 NU1902 警告仍需独立维护，不通过更换 .NET/Actions 版本掩盖，本轮不扩展处理范围。

## 下一位零基础用户的部署验收清单

按[Windows 教程](windows-setup.md)执行，勾选时只记录是否完成，不填写凭证或完整 ID：

- [ ] 第 1 步：能区分 Git、gh、Node 与 PowerShell；版本检查全部成功，无需 AI 补充安装步骤。
- [ ] 第 2–3 步：页面属于自己的 Fork；Clone 成功，当前位置正确，origin 指向自己；没有使用 ZIP。
- [ ] 第 4 步：墨墨和 GitHub 分别登录成功，知道验证码属于哪一个服务，没有分享授权信息。
- [ ] 第 5 步：输入完整仓库名确认，看到 uploaded=1；在 Repository secrets 找到自动导入项。
- [ ] 第 6 步：目标名称、章节初始内容和完整 ID 对应；三项 Secrets、一项 Variable 类型/名称正确。
- [ ] 第 7 步：能找到 diagnose/Diagnose MaiMemo (GET only) 日志，理解指标与停止条件；安全预检通过。
- [ ] 第 8 步：只发起一次正式同步，有自然新增时看到写后校验通过；手机结果正确。
- [ ] 第 8 步：再次只读诊断 missing=0、would_add=0，原文保留、无重复和非法行；未靠删词通过。
- [ ] 第 9 步：Sync Words 已启用，理解手动与定时的区别、电脑可关机、09:05 可能延迟；后续看到 schedule 记录。
- [ ] 第 10 步：知道约 90 天/撤销可能需要维护；能按错误阶段找排障，不把所有 OAuth 错误当过期。

未完成的项目记录“卡在第几步、哪条提示不明”，不直接修改源码。所有词数以测试者自己的数据为准。
