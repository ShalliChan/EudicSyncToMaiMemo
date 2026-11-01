# EudicSyncToMaiMemo

把欧路独立收藏的单词、短语自动增量添加到墨墨云词本。

Fork 自 [viazure/EudicSyncToMaiMemo](https://github.com/viazure/EudicSyncToMaiMemo)，保留原作者 viazure 的署名及 [MIT License](LICENSE)。本 Fork 增加严格标题筛选、安全增量合并、写后校验、OAuth 刷新和只读诊断。通知功能参考 [jeessy2/ddns-go](https://github.com/jeessy2/ddns-go)。

## 工作原理与边界

- 欧路新增 → 墨墨追加；欧路取消收藏 → 墨墨保留历史词汇。
- 只接受完整、有效的独立收藏标题；不拆短语、不生成词形、不从笔记或 Markdown 猜标题。
- 完整标题精确去重，区分大小写；没有新增就不写入。
- 原有合法标题、章节、空行及换行完整保留。非法行、重复标题及非章节结构阻止写入。
- 写后重新 GET：正文必须与计划追加结果完全一致，标题集合等于“原有标题 ∪ 当前有效源标题”，再次模拟新增应为零。
- 不修改欧路，不自动清空或重建词本。
- 墨墨部分未收录短语可能显示“自编此单词”，仍需在 App 中补充提交；不会自动生成释义。

## 推荐部署：GitHub Actions

需要欧路和墨墨账号，以及安装 Node.js 22+、GitHub CLI、PowerShell 的电脑。首次授权在本机完成，随后云端每天运行，电脑无需常开。

### 1. Fork 并克隆自己的仓库

点击 GitHub 的 **Fork**，保留默认分支 main。克隆自己的 Fork：
```powershell
git clone https://github.com/<你的账号>/EudicSyncToMaiMemo.git
cd EudicSyncToMaiMemo
git remote get-url origin
```
确认 origin 指向自己，不是上游。不要提交任何授权凭证。

### 2. 墨墨首次授权

```powershell
npx --yes --package=@maimemo/memo-api@1.3.1 memo-api auth login
gh auth login --hostname github.com --web --git-protocol https
pwsh -File ./scripts/import-maimemo-oauth.ps1
```
在浏览器登录拥有词本的墨墨账号并授权。导入脚本显示当前 origin 仓库；检查后输入完整的“账号/仓库名”确认。脚本确认仓库写权限后，通过标准输入上传刷新凭证，不打印凭证或上传整个配置文件。

成功后自己的 Fork 会出现 MAIMEMO_OIDC_CREDENTIALS Secret。不要将本机凭证文件粘贴到聊天、Issue、仓库或构建产物。

### 3. 配置自己的账号和词本

在 **Settings → Secrets and variables → Actions** 配置：

| 类型 | 名称 | 内容 |
|---|---|---|
| Secret | MAIMEMO_OIDC_CREDENTIALS | 上一步自动导入 |
| Secret | EUDIC_AUTHORIZATION | [欧路开放平台](https://my.eudic.net/OpenAPI/Authorization)提供的完整 Authorization |
| Secret | EUDIC_BOOK_ID | 默认生词本填 0 |
| Repository Variable | MAIMEMO_NOTEPAD_ID | 自己的完整 np- 开头云词本 ID |

在墨墨创建名称为 **欧路词典同步（严格）** 的词本，正文只填：
```text
# 欧路词典同步
```
保留其他旧词本。通过官方演示或下面的官方 CLI 查询自己的完整 ID：
```powershell
npx --yes --package=@maimemo/memo-api@1.3.1 memo-api notepad list
```
不要使用截断 ID 或网页数字 ID。词本 ID 配置在 **Variables**，不是 Secrets。同步和诊断共用它，不需要编辑工作流。缺失或不一致时停止，不回退到示例或其他人的 ID。

### 4. 先做只读预检

在自己的 **Actions** 启用工作流，运行 **MaiMemo Read-only Diagnostics → Run workflow → main**，保持 difference_audit=false。

查看 source=strict_preview：

- ready=1、prepared_union_equal=1、original_content_preserved=1。
- target_duplicates=0、invalid_lines=0、second_merge_additions=0。
- would_add 是预计新增数量；target_titles 是原有数量。
- extra 是合法历史标题数，允许大于零，不会删除。

以自己的数据为准，不套用他人的历史词数。数字被 GitHub 遮罩为 *** 时，不要关闭凭证遮罩。

### 5. 首次手动同步与验收

预检通过后运行 **Sync Words → Run workflow → main**，选择默认 oauth。查看 Run Sync 的刷新、目标读取、新增数量和写后校验。

随后再次运行只读诊断，确认 ready=1、missing=0、would_add=0，无重复或非法标题。不需要重复真实写入来测试去重。无新增的运行只验证读取和幂等，不代表实际测试了写权限。

### 6. 自动运行和维护

计划每天 UTC 01:05，即北京时间 09:05；**GitHub 调度可能明显延迟，不保证准点**。Fork 定时任务可能需要在 Actions 手动启用。首次配置前可先禁用 Sync Words，验收后再启用。

每次先刷新 Access Token，再通过子进程环境交给原 .NET 程序。任务共用并发组。OAuth 出错即停止，不自动回退。

当前 CLI 按首次授权后约 **90 天**记录刷新凭证到期，撤销或服务端策略也可能提前使其失效。届时重复本机登录和导入，不是永久免维护授权。发现 Refresh Token 轮换会停止，不使用公开文件或产物持久化。

查看自动结果：**Actions → Sync Words → 最新运行 → Run Sync**。报错后先排查，不反复重跑。

## 可选固定 Token 回退

仅需要回退时设置 MAIMEMO_TOKEN Secret，手动运行时明确选择 authentication=fixed。定时仍使用 OAuth。固定 Token 不具备本项目的自动续期能力。

Prepare Strict MaiMemo Notebook 是可选手动建本工具，仍需要固定 Token，**会创建词本，不是只读检查**。推荐教程不依赖它，也不要在排障中反复创建。

## 本地运行与开发

原 .NET 控制台和 Windows 服务保留。直接运行这些程序需自行提供有效 Token；独立可执行文件和 Windows 服务不会自动运行 GitHub 的 OAuth 包装脚本。

配置示例见 src/EudicSyncToMaiMemo/appsettings.json。真实授权只保存在本机，不提交。使用 .NET 10 SDK：
```powershell
dotnet test src/EudicSyncToMaiMemo.slnx
npm ci --prefix scripts/maimemo-oauth --ignore-scripts
npm test --prefix scripts/maimemo-oauth
pwsh -File scripts/test-maimemo-diagnostics.ps1
pwsh -File scripts/test-provision-strict-notepad.ps1
pwsh -File scripts/test-import-maimemo-oauth.ps1
```
测试使用模拟数据，不会同步真实词库。打包见 .github/workflows/release.yml 的 v* 标签流程。上游发布包不代表本 Fork 的功能，请使用对应仓库的版本或自行构建。

更多说明：[OAuth](docs/maimemo-oauth.md) · [故障排查](docs/troubleshooting.md)
