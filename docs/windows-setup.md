# Windows 零基础部署教程

本教程把欧路默认生词本中的有效标题，安全增量添加到你自己的墨墨云词本。安装和首次授权在电脑上完成；日后由 GitHub 云端运行。无需编写代码、修改 YAML 工作流或安装 .NET。

按顺序操作，**每一步成功后再继续**。出现错误先看本页对应提示或[故障排查](troubleshooting.md)，不要用反复运行、删词或改代码来让检查变绿。

步骤：[1 安装软件](#1-安装软件并打开正确的窗口) → [2 Fork](#2-fork-到自己的-github-账号) → [3 Clone](#3-克隆自己的-fork-并进入文件夹) → [4 登录](#4-在本机登录墨墨和-github) → [5 导入凭证](#5-将墨墨授权安全导入自己的仓库) → [6 配置](#6-配置欧路授权和墨墨目标) → [7 只读检查](#7-首次只读预检) → [8 首次同步](#8-第一次真实同步及验收) → [9 自动运行](#9-确认每天自动运行) → [10 维护](#10-日后维护)。

## 1. 安装软件并打开正确的窗口

### 需要哪些软件

| 名称 | 用途与是否安装 | 安装方式 |
|---|---|---|
| Git | 必装；把仓库克隆到电脑，并记录它来自哪个仓库 | [Git 官方 Windows 下载](https://git-scm.com/install/windows)，选择匹配电脑架构的 Setup 安装包。通常为 x64；不确定可在 Windows「设置 → 系统 → 系统信息」查看系统类型。安装时保留 **Git from the command line and also from 3rd-party software** 选项，其余可用默认值 |
| GitHub CLI | 必装；命令名 `gh`，负责 GitHub 登录和上传 Secret。它与 Git 是两个软件 | [GitHub CLI 官网](https://cli.github.com/)，选择 **Windows — Download MSI**，下载适合系统的 `.msi`，双击按提示安装 |
| Node.js | 必装；运行墨墨官方授权工具 | [Node.js 官方下载](https://nodejs.org/en/download)，选择 **v22.x、Windows、自己的架构、Windows Installer (.msi)**。保留 npm 和 Add to PATH；无需安装附加的原生编译工具 |
| npm / npx | 随 Node.js 安装，无需另装。npm 管理工具包，npx 运行指定版本的工具 | 本教程写 `npm.cmd`、`npx.cmd`，避免 Windows PowerShell 误选受执行策略限制的 `.ps1` 入口 |
| Windows PowerShell | Windows 10/11 通常自带 5.1；输入命令的窗口 | 按 Windows 键，搜索 **Windows PowerShell** 并打开普通窗口，无需管理员身份 |
| PowerShell 7 | 可选，命令名 `pwsh`；不是 Windows 自带的 5.1 | 新手流程不需要安装。看到 `pwsh` 无法识别时不要转去修改代码 |
| CMD | Windows 自带的另一种命令窗口 | 本教程统一用 Windows PowerShell，避免混用语法。无需打开 CMD 或 Git Bash |

安装完成后**关闭旧的终端窗口，再重新打开 Windows PowerShell**。旧窗口不会自动获得新软件的 PATH（查找命令的位置）。若从 Windows Terminal 打开，也需关闭整个应用再打开。

### 检查安装

在 Windows PowerShell 中，逐行复制下面的命令，每行按 Enter。不要复制窗口原有的 `PS C:\...>` 提示符，也不要复制代码块外的说明。

```powershell
$PSVersionTable.PSVersion
git --version
gh --version
node --version
npm.cmd --version
npx.cmd --version
```

**成功标志：**第一条 Major/Minor 为 5/1（已安装的 7.x 也可），Git 和 gh 各自显示版本，Node 显示 `v22.x.x`，npm/npx 显示版本数字。npm/npx 的版本号不必等于 Node。

若提示“不被识别”，先重开窗口，再检查是否安装了对应软件。浏览器能打开 GitHub，不代表 `gh` 已安装。[详细检查](troubleshooting.md#terminal)。本机不需要安装与 GitHub 云端相同的 .NET 环境。

## 2. Fork 到自己的 GitHub 账号

**目的：**建立你自己的项目副本，随后授权和词本配置都放在这个副本中。

- **Repository（仓库）**：GitHub 上存放项目文件的地方，地址包含“账号/仓库名”。
- **Fork**：把别人的仓库复制到自己的 GitHub 账号，保留与来源项目的联系；不会自动复制对方的 Secrets。
- **Clone（克隆）**：将某个仓库下载到电脑，供本地授权脚本使用。
- **origin**：本地克隆记住的来源仓库地址，导入脚本用它决定把凭证上传给谁。

如果还没有 GitHub 账号，先在 [GitHub 注册页面](https://github.com/signup)按提示设置邮箱、密码和用户名，并完成邮件验证。**用户名**用于仓库地址，不一定等于个人资料中的显示昵称。已有账号则直接登录，然后：

1. 打开[项目入口](https://github.com/ShalliChan/EudicSyncToMaiMemo)。
2. 点击右上角 **Fork → Create a new fork**；Owner 选自己的账号，仓库名保留 `EudicSyncToMaiMemo`，保留 `main` 默认分支，点击 **Create fork**。
3. 成功后左上角应显示 **你自己的账号 / EudicSyncToMaiMemo**。以后本教程提到的 Settings、Actions，都指这个仓库。
4. 点击 **Actions**。若有提示，点击 **I understand my workflows, go ahead and enable them**。启用后，先在左侧选择 **Sync Words**，右上 **… → Disable workflow**，防止配置期间定时任务提前运行。不要禁用后面要用的只读诊断。

如果已经 Fork，不要再建一个；在自己的仓库按本教程继续。第一次预检和同步前，保持 Sync Words 停用；第 8 步再启用它。

## 3. 克隆自己的 Fork 并进入文件夹

在**自己仓库**的 **Code** 页面点击绿色 **Code → Local → HTTPS**，复制地址。

回到 Windows PowerShell，先输入：

```powershell
Set-Location $HOME
```

这会进入当前 Windows 用户的文件夹；无需照抄其他人的 Windows 路径。接着输入 `git clone `（末尾有空格），粘贴刚才的 HTTPS 地址，按 Enter。命令应类似下面这样，**必须将 YOUR-NAME 换成自己的 GitHub 账号**：

```powershell
git clone https://github.com/YOUR-NAME/EudicSyncToMaiMemo.git
```

下载完成后逐行执行：

```powershell
Set-Location .\EudicSyncToMaiMemo
Get-Location
Test-Path .\scripts\import-maimemo-oauth.ps1
git remote get-url origin
```

**成功标志：**当前位置以 `EudicSyncToMaiMemo` 结尾，Test-Path 返回 `True`，origin 地址是**自己的账号/仓库**。后面所有本地命令都在这个窗口、这个文件夹运行。

**不要改用 Download ZIP。** ZIP 不含 `.git` 和 origin，当前导入脚本无法确认凭证应该上传到哪里。若曾克隆错仓库或下载 ZIP，停止导入，在另一个空文件夹克隆正确的 Fork；无需删除旧文件，也不要猜着修改 origin。

若提示文件夹已存在，不要覆盖；如果是已有的正确克隆，直接进入该文件夹并执行上述检查。关闭窗口后再回来时，可先 `Set-Location $HOME`，再 `Set-Location .\EudicSyncToMaiMemo`。

## 4. 在本机登录墨墨和 GitHub

这是两次不同的授权：墨墨允许程序操作你的词本，GitHub 允许本机将凭证保存到自己的仓库。使用同一个普通 Windows 用户完成下面步骤，避免凭证存到另一个用户目录。

### 4.1 墨墨 OAuth 登录

在 Windows PowerShell 中执行：

```powershell
npx.cmd --yes --package=@maimemo/memo-api@1.3.1 memo-api auth login
```

`npx.cmd` 会获取并运行固定版本的**墨墨官方 CLI**（命令行工具）。首次下载可能需要等待。`--yes` 表示同意安装这个明确指定的工具，不是把墨墨账号密码写进命令。

正常会自动打开浏览器；没有打开时，将终端显示的授权链接复制到**这台电脑的浏览器**。登录你手机上拥有目标词本的墨墨账号，核对账号后同意授权。保持命令窗口打开；成功后浏览器显示“登录成功”，终端也显示登录成功并回到提示符。

这一步会把本机凭证保存到用户目录的 `.config/memo-api.json`；**不要打开复制、打印或上传这个文件**。授权链接、回调地址和验证码也不要发给别人。不要添加 `--verbose`，它可能输出敏感请求信息。

失败时先看[墨墨登录排障](troubleshooting.md#maimemo-login)；没有成功就不要导入旧凭证。

### 4.2 GitHub CLI 登录

```powershell
gh auth login --hostname github.com --web --git-protocol https
```

如果询问 **Authenticate Git with your GitHub credentials?**，输入 `Y` 并按 Enter。留意终端中的 **one-time code**（一次性验证码，通常形如四位字符-四位字符），先复制它，再按 Enter 打开浏览器。

浏览器登录**自己 Fork 所属的 GitHub 账号**，在 GitHub 的设备授权页面输入刚才的验证码，核对 **GitHub CLI** 授权并确认。如果没有自动打开，手动访问 [github.com/login/device](https://github.com/login/device)。不是墨墨验证码，也不是仓库名，不要将其发给别人。

**成功标志：**终端出现 `Authentication complete` / `Logged in as`。用下面的命令只确认当前账号名：

```powershell
gh api user --jq .login
```

输出应是自己的账号。若连接失败、超时或无法打开网页，先处理[连接问题](troubleshooting.md#network)，不要通过更换 Shell 或修改 OAuth 参数解决网络故障。

## 5. 将墨墨授权安全导入自己的仓库

**目的：**让 GitHub 云端以后能刷新墨墨访问凭证。这一步只保存授权，不读取学习词库，不同步单词。

先再次确认 `git remote get-url origin` 是自己的 Fork，再执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\import-maimemo-oauth.ps1
```

本命令使用 Windows 自带的 PowerShell，不需要 `pwsh`。`Bypass` 只对这次新开的 PowerShell 进程临时放行脚本执行，不修改系统或用户的永久执行策略。**先核对脚本来自正确项目再运行**；公司管理的电脑若被组策略阻止，应联系管理员，不要绕过组织限制。[微软说明](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)。

脚本先从当前克隆的 origin 识别仓库，再查询 GitHub 确认你有写权限。终端会显示 `Target repository:`，要求输入完整的 `账号/EudicSyncToMaiMemo`。

1. 核对显示的是**自己的账号和仓库**，不是项目作者或其他人的仓库。
2. 按显示的大小写输入完整仓库名并按 Enter；不是仅输入账号，不是 HTTPS 链接，也不是输入 `Y`。
3. 不确定就直接按 Enter 取消。只有目标核对通过且你输入匹配之后，脚本才读取本机墨墨凭证并上传；不会自动回退上传到其他仓库。

**成功标志：**输出 `oauth_credentials_uploaded=1 fixed_token_unchanged=1`。后半句只表示没有改动固定 Token，并不要求你配置固定 Token。

在浏览器打开**自己的仓库 → Settings → Secrets and variables → Actions → Secrets**，在 **Repository secrets** 中应出现 `MAIMEMO_OIDC_CREDENTIALS`。Secret 是 GitHub 保存密码类数据的保密位置；页面能看到名称，不能读回明文，属于正常行为。不要另建一个同名 Variable，也不用手工填写这个凭证。

脚本不成功时会停止且不展示底层凭证。按[导入失败检查顺序](troubleshooting.md#import)检查，不要将本机凭证文件发送给维护者。

## 6. 配置欧路授权和墨墨目标

### 6.1 创建或确认专用墨墨云词本

目标词本必须属于刚才授权的墨墨账号，名称**完全一致**为 `欧路词典同步（严格）`（使用中文全角括号）。这是程序读取前的身份核对，不只是展示名称。不得把其他学习词本随意改名作为目标。

先在同一 PowerShell 窗口只读查询：

```powershell
npx.cmd --yes --package=@maimemo/memo-api@1.3.1 memo-api notepad list --fields id,title,status
```

输出每行一个词本，`id` 列为完整 ID，`title` 列为名称。默认一次列 10 条；若已有很多词本，继续执行：

```powershell
npx.cmd --yes --package=@maimemo/memo-api@1.3.1 memo-api notepad list --fields id,title,status --offset 10
```

仍有后续时把末尾 `10` 改成 `20`、`30` 等，直到无结果。不要因第一页没看到就重复创建。

如果已经有同名的正确同步词本，保留它和现有词汇，复制其 ID，跳过创建。若出现多个同名词本，先在 App 核实要用哪一个，不要猜选。

**仅当确认没有同名词本时**，可在墨墨 App 的云词本新建入口创建：名称填上面的完整名称，正文只填下面这一行，`#` 后有一个英文空格，状态选未发布（如有该选项）：

```text
# 欧路词典同步
```

不要把这行当成 PowerShell 命令。它是墨墨支持的章节标题，不是待学习单词。App 入口名称会随版本变化；找不到时，可在本机使用下面的**官方创建命令**代替（它会创建词本，请只执行一次；报错时先停止、查询是否已创建，不要重复提交）：

```powershell
npx.cmd --yes --package=@maimemo/memo-api@1.3.1 memo-api notepad create --title "欧路词典同步（严格）" --status UNPUBLISHED --brief "欧路词典自动同步专用" --content "# 欧路词典同步" --fields id,title,status
```

创建后再次执行前面的 `notepad list --fields id,title,status`，找到目标那一行并复制完整的 **`np-` 开头字符串**。不要复制 `id` 表头、列间空格、引号、带 `...` 的截断值或网页中的数字。`--fields` 显式选列避免 CLI 默认列宽截断。

**成功标志：**该 ID 与正确名称在同一行，手机 App 中是自己的目标词本。复制的 ID 只用于下一步配置，无需发给别人。改名是否改变 ID 没有依据；本项目会核对名称，所以不要随意改名。其他旧词本保持不动。

### 6.2 配置两个欧路 Secrets

在浏览器登录自己的欧路账号，打开[欧路获取授权页面](https://my.eudic.net/OpenAPI/Authorization)（左侧菜单“获取授权”）。复制页面提供的**完整 Authorization 授权信息**，包括原有前缀和空格；不要把网页地址、账号密码或截断字符串当作授权信息，也不要自行加 `Bearer`。

回到**自己的 GitHub 仓库 → Settings → Secrets and variables → Actions → Secrets**：

1. 点击 **New repository secret**，Name 填 `EUDIC_AUTHORIZATION`，Secret 填刚复制的完整授权，点击 **Add secret**。
2. 再点击 **New repository secret**，Name 填 `EUDIC_BOOK_ID`，Secret 填一个数字字符 `0`，点击 **Add secret**。它表示欧路默认生词本，不是墨墨词本 ID。
3. 如果名称已存在，点该条右侧的铅笔更新，不要创建不同拼写的新名称。

### 6.3 配置墨墨 Repository Variable

在同一页面切换到 **Variables** 标签，点击 **New repository variable**：

- Name：`MAIMEMO_NOTEPAD_ID`
- Value：第 6.1 步复制的完整 `np-` 开头 ID，不能有前后空格或换行。
- 点击 **Add variable**。

**Variable** 保存普通配置，值可在仓库设置中查看；**Secret** 保存保密授权，不能读回明文。词本 ID 不是访问凭证，只有配合授权才能读取；仍不需要在 Issue 中公开它。同步和诊断都使用这个 Variable，无需编辑工作流。

此时应有以下四项，逐项确认名称、类型和所在仓库：

| 类型与页面 | 名称 | 内容与来源 |
|---|---|---|
| Secrets → Repository secrets | `MAIMEMO_OIDC_CREDENTIALS` | 第 5 步脚本自动上传的墨墨刷新凭证 |
| Secrets → Repository secrets | `EUDIC_AUTHORIZATION` | 欧路完整 Authorization，供只读获取收藏 |
| Secrets → Repository secrets | `EUDIC_BOOK_ID` | `0`，欧路默认生词本 |
| Variables → Repository variables | `MAIMEMO_NOTEPAD_ID` | 自己墨墨目标的完整 `np-` ID |

不需要 `MAIMEMO_TOKEN`、通知相关 Secrets 或手工申请 OAuth 开发者应用。缺少目标配置、目标名称或 ID 不一致时程序会停止；不会替你猜 ID。

## 7. 首次只读预检

**目的：**在写入前读取两个词库，计算能安全追加什么，不改变任何词条。OAuth 刷新会向认证服务发送请求，但词库检查只用 GET，不会调用词本写接口。

在**自己的仓库网页**：

1. 点击顶部 **Actions**。左侧选择 **MaiMemo Read-only Diagnostics**，不要选择 Sync Words 或建本工具。
2. 右侧点击 **Run workflow**，Branch 选 **main**，`difference_audit` 不勾选（false），再点面板内绿色 **Run workflow**。
3. 等待新记录出现，必要时刷新网页；点击该记录。黄色表示等待/运行，绿色勾表示已完成，红色叉表示失败。不要只看另一条 Build and Test 的绿色结果。
4. 左侧 **Jobs** 下点击 **diagnose**，展开 **Diagnose MaiMemo (GET only)**。这是本次只读检查的日志。
5. 在日志中查找 `source=strict_preview`。每行 `anomaly=名称` 后的 `count=数字`，就是下面的指标。例如 `anomaly=ready ... count=1` 可读作 `ready=1`。

日志中的 `verification_passed=1` 只说明 OAuth 刷新和目标读取成功，**还要检查正文预览指标**：

| 指标 | 人话解释 | 首次写入前的判断 |
|---|---|---|
| `scanned` / `unique_titles` | 读到的欧路记录 / 筛选去重后的有效标题数量 | 应符合自己的收藏情况，不必等于手机所有语言、所有分组的总数 |
| `invalid_or_ambiguous` / `notes_excluded` | 无法可靠提取的记录 / 已排除笔记的记录 | 不等于授权失败；若数量意外，先核查收藏结构，不强行放宽规则 |
| `target_titles` | 墨墨正文已有标题数，不含章节名 | 新词本可以为 0；已有词本不应意外减少 |
| `missing` / `would_add` | 欧路有效标题中目标尚无的数量 / 预计实际追加数量 | 首次可大于 0，说明还没同步；数量意外时停止 |
| `extra` | 墨墨合法历史标题中，当前欧路集合没有的数量 | 可以大于 0，会保留，不需要删词 |
| `ready` | 当前结构与安全条件允许合并 | 必须为 1 |
| `target_chapter_mode` | 墨墨正文采用章节格式 | 必须为 1 |
| `prepared_union_equal` / `prepared_set_equal` | 拟提交结果恰好是原有标题加有效源标题 | 必须为 1；尚未写入 |
| `original_content_preserved` | 拟提交结果完整保留原正文 | 必须为 1 |
| `target_duplicates` / `invalid_lines` | 已有正文重复标题 / 非法行数量 | 必须为 0 |
| `second_merge_additions` | 在拟提交结果上再次模拟还会添加多少 | 必须为 0，证明重复运行不会反复追加 |
| `current_set_equal` | 目标当前已包含全部有效源标题 | 首次可以为 0；同步后应为 1，不要求 extra=0 |

**可以继续：**本次运行成功，所有“必须”指标满足，预计数量合理，目标身份读取通过。准备好的新词本通常显示 `target_titles=0`、`would_add` 为自己的有效标题数。

**必须停止：**`ready=0`、重复/非法行大于 0、原文保留或预计集合校验失败、目标身份不符、任一步失败或出现不能解释的数量变化。保留日志，查[排障](troubleshooting.md#preview)，不要清空词本或改工作流来通过。

GitHub 可能把与 Secret 相同的字符遮罩成 `***`，连数字 0 也可能被遮罩。不要关闭遮罩、删除 Secret 或打印正文；结合本次成功状态和可见保护指标判断。无法判断时先停止，提交错误码和指标名称供维护者检查。

## 8. 第一次真实同步及验收

**只有第 7 步通过后才执行。**这一步会向指定墨墨词本追加缺少的有效标题，不改欧路。

1. **Actions → Sync Words**，如果第 2 步停用了它，点击 **Enable workflow**（部分界面在 **…** 菜单内）。启用也允许后续定时运行，不是只启用这一次。
2. 点击 **Run workflow**，Branch 选 **main**，`authentication` 保持 **oauth**，点击绿色 **Run workflow**，只发起一次。
3. 打开这次运行 → 左侧 **sync** → 展开 **Run Sync**。先看到配置检查、OAuth 刷新成功和目标读取成功，随后是欧路读取、严格标题筛选、严格正文校验和新增结果。
4. 等待整个任务结束。若有真实新增，应有“已向墨墨同步新增 … 条”“同步完成”；程序在报告写入成功前已重新 GET 校验。若没有新增，会报告“没有新增单词”，不执行无意义写入。
5. 在手机墨墨刷新并进入自己的目标词本，抽查几个欧路已收藏的单词和完整短语。章节标题不是词条，App 的词形、释义和关联表达展示不一定等于正文存储行。
6. 再按第 7 步运行一次 **MaiMemo Read-only Diagnostics**。应有 `ready=1`、`current_set_equal=1`、`missing=0`、`would_add=0`，原文保留、预计集合、无重复/非法行校验仍通过。

如果两次读取之间刚好又收藏了新词，`missing`/`would_add` 可以反映这些新增，先核对时间，不要直接判断丢词。无需为了测试而新增无意义词汇或反复运行真实同步。没有新增的成功运行不能证明已经验证过写权限；等正常收藏带来一次真实新增，再核对该次写后成功和只读结果即可。

有授权、写入或写后校验异常时停止，**不要立即重跑**；先做只读检查，因为服务端可能已写入但校验尚未完成。不要回滚、覆盖或清空词本。

## 9. 确认每天自动运行

定时表达式已在项目的 **Sync Words** 中配置为每天 **UTC 01:05，即北京时间 09:05**。不用再建一个“定时工作流”，也不用每天点击按钮。

- 第 8 步启用 Sync Words 后，手动和定时入口都可使用。手动运行只是请求运行一次，**不会另外安装或启动一个定时器**。
- 在自己的仓库 **Actions → Sync Words** 确认没有 Disabled/Enable workflow 提示。查看后续记录的事件类型：手动为 `workflow_dispatch`，定时为 `schedule`（界面也可能显示 Scheduled）。点开记录可查看与第 8 步相同的日志。
- **电脑可以关机。**GitHub 提供临时云端电脑，每次读仓库配置并刷新授权；本地终端不用保持打开。
- GitHub 可能排队、明显延迟，少数计划任务可能被丢弃；09:05 是计划时间，不是到点承诺。先看当天记录，不要因为没准点就重复触发。
- Fork 的 Actions/定时任务不是自动替你启用的。长期没有运行时检查工作流状态；公开仓库连续约 60 天没有仓库活动，定时任务可能被 GitHub 停用，需要重新 **Enable workflow**。[GitHub 官方定时说明](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)。

以后只需要正常在欧路收藏并同步到云端，下一次成功运行会追加新标题。取消欧路收藏不会删除墨墨历史词汇。

## 10. 日后维护

当前墨墨官方 CLI 按首次登录约 90 天记录刷新凭证期限，服务器撤销或策略变化可能更早导致失败。**不是所有 OAuth 报错都代表过期**，尤其 `oauth_client_rejected` 要先按[专门排障](troubleshooting.md#oauth-client-rejected)确认。

明确过期或授权被撤销时，回到原克隆文件夹，依次重做 **4.1 墨墨登录 → 5 凭证导入 → 7 只读预检**；GitHub CLI 登录已失效才补做 4.2。不重建词本，不改目标 ID，不改欧路授权，不自动改用固定 Token。

遇到问题优先提供：出错的工作流与步骤、错误码、版本、运行链接（确认可公开）。不提供凭证、授权链接、验证码、完整个人词库或完整 ID。其他问题见[故障排查](troubleshooting.md)；固定 Token 和本地服务属于[高级用法](maimemo-oauth.md)。
