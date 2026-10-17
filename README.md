# EudicSyncToMaiMemo

[欧路词典](https://www.eudic.net/v4/en/app/eudic) 生词本同步到 [墨墨背单词](https://www.maimemo.com/) 云词库。

## 介绍

由于欧路词典提供了全平台的客户端，并且支持可定制的词库，我在日常生活与工作中都使用欧路词典来收集生词。然后我会定期将新的生词导入到更专注于背单词的软件——墨墨背单词中进行记忆。为了减少重复的工作，我开发了这个项目。

### 工作流程

![flow.excalidraw.png](docs/img/flow.excalidraw.png)

## 使用说明

### 获取授权信息

#### 欧路词典

1. 访问 [欧路词典开放平台授权页面](https://my.eudic.net/OpenAPI/Authorization)
2. 完成登录后在页面找到 Authorization 值

#### 墨墨背单词（推荐：开放 API）

1. 获取请求凭证，有两种方式获取：
   1. 通过墨墨背单词 App：我的 -> 更多设置 -> 实验功能 -> 开放 API
   2. 点击[此处](https://open.maimemo.com/open/api/v1/tokens/openapi)获取
2. 复制 Token，配置到 `MaiMemo:Token`
3. 文档详情见 [墨墨开放 API](https://open.maimemo.com/)

#### 墨墨背单词（Legacy 过渡）

若尚未迁移 Token，可将 `MaiMemo:Provider` 设为 `Legacy`，继续使用用户名与密码，程序会通过网页登录完成授权。

### 获取词库 ID

#### 获取欧路词典生词本 ID

欧路词典默认的生词本 ID 是 `0`。若希望使用特定的生词本，需按照以下步骤操作：

1. 使用 API 测试工具向 [https://api.frdic.com/api/open/v1/studylist/category?language=en](https://api.frdic.com/api/open/v1/studylist/category?language=en) 发起请求
2. 查看响应数据中的生词本列表，获取所需生词本的 ID

#### 获取墨墨背单词云词库 ID

Open API 与网页版使用**不同的 ID**，请按 `MaiMemo:Provider` 选择：

**Open API 模式（推荐）：**

1. 用 Token 请求 [GET /open/api/v1/memo/notepads](https://open.maimemo.com/)
2. 在响应中找到目标词库的 `id` 字段，格式为 `np-` 开头的长字符串
3. 填入 `MaiMemo:DefaultNotepadId`

若你只有网页版数字 ID、但记得词库标题，可改填 `MaiMemo:DefaultNotepadTitle`，程序会拉取列表按标题精确匹配（`DefaultNotepadId` 可暂填任意占位，如 `0`）

**Legacy 网页模式：**

1. 登录 [墨墨背单词网页版](https://www.maimemo.com/)
2. 导航至「我的编辑」-「云词库」
3. 打开目标云词库，从 URL 中取数字 ID（如 `https://www.maimemo.com/notepad/detail/1234567?scene=` 中的 `1234567`）
4. 填入 `MaiMemo:DefaultNotepadId`

### 运行同步程序

支持三种运行方式，共用同一套同步逻辑。

#### 控制台单次同步

1. 访问 [Releases 页面](https://github.com/viazure/EudicSyncToMaiMemo/releases) 下载对应平台产物（`win-x64.zip` / `linux-x64.tar.gz` / `osx-x64.tar.gz`）
2. 解压缩并 [修改配置文件](#修改配置文件)
3. 双击 `EudicSyncToMaiMemo.exe`，或执行：

```powershell
.\EudicSyncToMaiMemo.exe --sync-once
```

#### Windows 服务（自托管循环）

1. 下载 Release zip
2. [修改配置文件](#修改配置文件) 中的 `appsettings.json`
3. 将 `scripts/install-service.ps1` 拷贝至程序同级目录下，使用 PowerShell 以管理员身份运行
4. 服务会按 `Sync:IntervalDays` 定期同步

卸载服务：将 `scripts/uninstall-service.ps1` 拷贝至程序同级目录下，使用 PowerShell 以管理员身份运行

#### GitHub Actions 定时同步

在仓库 Settings → Secrets 中配置：

| Secret                | 说明               |
|-----------------------|--------------------|
| `EUDIC_AUTHORIZATION` | 欧路 Authorization |
| `EUDIC_BOOK_ID`       | 欧路生词本 ID      |
| `MAIMEMO_TOKEN`       | 墨墨开放 API Token |
| `MAIMEMO_NOTEPAD_ID`  | 墨墨云词库 ID      |
| `NOTIFICATION_*`      | 可选通知配置       |

workflow 见 [.github/workflows/sync.yml](.github/workflows/sync.yml)，支持 cron 与手动 `workflow_dispatch`。

本地模拟 GHA 环境变量：

```powershell
$env:Eudic__Authorization = "NIS xxx"
$env:Eudic__DefaultBookId = "0"
$env:MaiMemo__Provider = "OpenApi"
$env:MaiMemo__Token = "your_token"
$env:MaiMemo__DefaultNotepadId = "1234567"
dotnet run --project src/EudicSyncToMaiMemo/EudicSyncToMaiMemo.csproj -c Release -- --sync-once
```

### 修改配置文件

**配置文件 `appsettings.json`**

```json
{
  "Sync": {
    "IntervalDays": 7
  },
  "Eudic": {
    "Authorization": "NIS XXX",
    "DefaultBookId": "0"
  },
  "MaiMemo": {
    "Provider": "OpenApi",
    "Token": "your_token",
    "Username": "",
    "Password": "",
    "DefaultNotepadId": "np-your_notepad_id",
    "DefaultNotepadTitle": ""
  },
  "Notification": {
    "Enabled": false,
    "Url": "",
    "RequestBody": "",
    "Headers": ""
  }
}
```

**字段说明：**

| 来源     | 字段名                      | 说明                                        | 必填                   |
|----------|-----------------------------|---------------------------------------------|------------------------|
| 同步     | Sync:IntervalDays           | 自托管模式下两次同步间隔（天）              | Hosted 模式            |
| 欧路词典 | Eudic:Authorization         | 接口授权                                    | 是                     |
| 欧路词典 | Eudic:DefaultBookId         | 默认生词本 ID，0 为默认生词本               | 是                     |
| 墨墨     | MaiMemo:Provider            | `OpenApi` 或 `Legacy`                       | 是                     |
| 墨墨     | MaiMemo:Token               | 开放 API Token                              | Provider=OpenApi       |
| 墨墨     | MaiMemo:Username / Password | 网页登录                                    | Provider=Legacy        |
| 墨墨     | MaiMemo:DefaultNotepadId    | OpenApi：`np-` 开头 ID；Legacy：网页数字 ID | 是                     |
| 墨墨     | MaiMemo:DefaultNotepadTitle | OpenApi 下按标题匹配，与 np- ID 二选一      | OpenApi 且无 np- ID 时 |
| 通知     | Notification:*              | Webhook 通知                                | 否                     |

环境变量与配置键对应关系：`Eudic__Authorization`、`MaiMemo__Token` 等（双下划线）。

根节点 `SyncInterval` 仍兼容读取，建议迁移到 `Sync:IntervalDays`。

### 配置通知服务

消息通知服务的接入逻辑参考了 [jeessy2/ddns-go](https://github.com/jeessy2/ddns-go) 项目的通知服务实现，特此表示感谢。

#### 配置步骤

1. 打开配置文件 `appsettings.json`，找到 `Notification` 节点
2. 将 `Enabled` 设置为 `true`
3. 根据您使用的服务继续设置 `Url`、`RequestBody`、`Headers`
4. RequestBody 为转义后的 JSON 字符串，例如：`{\"message\":\"同步完成：{content} \"}`。为空时使用 GET，否则 POST

**支持的变量：**

| 变量名    | 说明                                         |
|-----------|----------------------------------------------|
| {content} | 同步结果：有新词时为单词列表，否则为状态说明 |

**示例（Server 酱）：**

```url
https://sctapi.ftqq.com/<SENDKEY>.send?title=单词同步&desp={content}
```

更多配置参考：[ddns-go Webhook 配置参考](https://github.com/jeessy2/ddns-go/issues/327)

## 构建与打包

开发者 clone 后可自行编译：

```powershell
# 编译与测试
dotnet build src/EudicSyncToMaiMemo.slnx -c Release
dotnet test src/EudicSyncToMaiMemo.slnx -c Release

# 发布 zip（输出到 artifacts/publish）
./scripts/publish.ps1
```

Release 由 tag `v*` 触发，产物包含 `win-x64.zip`、`linux-x64.tar.gz`、`osx-x64.tar.gz`。

## 项目依赖

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- [Visual Studio 2022](https://visualstudio.microsoft.com/) 17.12 或更高版本（可选）

## 问题排查

日志默认位于 `%PROGRAMDATA%\EudicSyncToMaiMemo\logs`。GitHub Actions 与 `--sync-once` 模式同时输出到控制台。修改 Serilog `WriteTo` 可调整路径。

### 严格同步与新词本迁移

自动定时已暂时停用：`Sync Words` 当前仅保留 `workflow_dispatch`，不会在定时或推送时同步。

若官方演示网页无法创建词本，可手动运行 **Actions → Prepare Strict MaiMemo Notebook → Run workflow → main**。该工作流在 GitHub 云端使用现有 Secret，不读取或导出 Token 明文。它完整分页查询名称「欧路词典同步（严格）」；无匹配时仅创建一次，发送官方五个必填字段 `status=UNPUBLISHED`、指定标题/简介、章节正文、`tags=[]`，不写入单词。有唯一同名词本时仅 GET 复用并核对其状态、简介和空章节正文；多个同名、字段不符或请求失败即停止，无自动重试。

创建后 GET 验证完整 ID，再用临时配置对新 ID 调用现有严格只读预览。必须满足 `ready=1`、`prepared_set_equal=1`、`extra=0`、`target_duplicates=0`、`invalid_lines=0` 才将 `strict-notepad-result` artifact 的 `preview_verified` 设为 true。artifact 只含 ID、元数据及验证标志，不含 Token/欧路内容。若验证失败，不再点击重跑或尝试重复创建，先查看具体失败阶段。工作流不运行 Sync Words、不改旧词本、不向新词本写入标题。

云端工作流只有仓库读取权限，不尝试修改其他工作流文件。运行后提供运行编号，读取 artifact 并确认 `detail_verified=true`、`preview_verified=true` 后，才将新 ID 写入 `sync.yml` 并 Commit/Push；此前旧 ID 保持不变。整个过程中保持手动触发，完成迁移验收后再另行决定是否恢复定时。

OpenAPI 正式同步只接受完整欧路收藏记录本身就是有效标题的条目：一个收藏最多对应一个完整标题，精确、区分大小写去重；不拆短语、不生成变体，不从 Markdown、释义或多行笔记提取前缀。控制字符仍按原规则在内存中清理，不修改欧路数据。来源审计基准为 791 条原始记录、781 个有效独立唯一标题、9 条无效/歧义记录，另有 1 条笔记记录被排除（此前提取的标题已在独立收藏中存在），故严格模式总排除 10 条，目标标题数量仍是 781。源词库发生变化时以新预览为准。

正式同步与只读预览共用 `ExtractIndependentTitle` / `PrepareStrictContent`。新空词本正文生成 `# 欧路词典同步` 章节头，然后每行一个完整标题，不启用 `//`。已有合法章节、换行、空行和标题只保留并追加，不重新拼接或自动删除。目标若不是章节格式，或含源外标题、重复行、无效行，会在 POST 前拒绝更新；旧词本不会被自动清空。源内新增标题支持增量追加；当前定时暂时关闭，仅在手动触发时同步；欧路删除/改名导致源外行时会提示复核，不自动删除墨墨历史学习内容。

迁移步骤：

1. 手动在墨墨中创建新词本，例如「欧路词典同步（严格）」，保留旧词本。正文留空；若界面要求正文，**只填一行 `# 欧路词典同步`**，不填占位单词。通过官方演示/API复制新词本的完整 `np-` ID，勿使用截断显示或网页版数字 ID。
2. 在 GitHub 编辑 `.github/workflows/sync.yml`，只把 `Run Sync` 步骤环境变量 `MaiMemo__DefaultNotepadId` 改为新 ID，提交到 `main`。该 ID 当前直接写在工作流里，不是 Secret；不要改 Token、其他 Secrets 或 API 路径；保持当前仅手动触发。诊断自动从同一文件读取目标 ID。
3. 在 Actions → **MaiMemo Read-only Diagnostics** → **Run workflow → main** 新建运行。当前 `MAIMEMO_STRICT_PREVIEW=true` 优先于历史来源/标题审计。查看 `source=strict_preview`：`ready=1`、`extra=0`、`target_duplicates=0`、`invalid_lines=0`、`prepared_set_equal=1`。未变化源数据的新空目标应为 `unique_titles=781`、`would_add=781`、`invalid_or_ambiguous=9`、`notes_excluded=1`。`ready=0` 时按原因复核目标，不直接运行同步。
4. 手动运行 **Sync Words → Run workflow → main** 一次。写入携带完整正文和原元数据，随后 GET 校验正文集合；失败不自动重试。再运行只读诊断，确认 `current_set_equal=1`、`missing=0`、`extra=0`、`target_duplicates=0`、`would_add=0`。第二次同步也不会重复添加。
5. `source=parser_layer anomaly=expressions_without_body_line` 仅表示墨墨解析层的正文外表达，不表示程序新增；不能通过删除正常源标题来修正。验收以正文集合为准，同时单独查看解析展示。新词本验证成功后再由你决定旧词本是否删除。

只读诊断的成功状态仅表示读取和预览已完成，`ready=0` 仍表示不允许更新。所有日志只输出计数、固定原因和状态，不输出原词、正文、完整 ID 或凭证。

### 历史只读诊断模式

以下为保留的历史审计说明；开启严格预览时优先执行上节模式，不改变正式严格规则。

保留 `MAIMEMO_SOURCE_AUDIT=true`，关闭严格预览后执行来源对照（仍仅 GET）。`source_audit` 汇总原始记录、原始完整文本重复数、当前有效唯一标题、标题重复、笔记提取标题、词本正文行和 API `list` 解析词条；`default_book_configured` 和 `target_title_matches` 分别核对默认源词本和目标名称，不输出 ID。`literal_valid_unique_titles` 是无需解析笔记即可取得的有效唯一原始标题数，供评估最简规则；`derived_only_unique_titles` 是仅依赖笔记提取的标题数。当前正式规则保持不变，是否改为仅接受完整原始标题须另行确认。

六组 `focus_*` 对应用户指定的 do with、do with sth.、boil down、boil down to、boil down to sth.、down to。`raw_exact`/`raw_trimmed_exact` 为完整原始记录匹配，`extracted_title_exact` 为实际候选标题匹配，`notes_body_mentions`/`raw_embedded_not_title` 仅为笔记或嵌入命中，不能当独立收藏；`content_line_exact` 是提交正文独立行，`parsed_word_exact` 只看 `WORD`/`DRAFT_WORD` 类型，排除章节和释义字段。大小写差异另有 `raw_casefold_exact`、`title_casefold_exact`，不会因此合并原始数据。

`parsed_without_content_line` 仅表示服务端解析有而正文独立行没有，不能认定是程序添加或学习卡片重复；`content_without_current_title` 也不能区分旧版本残留、手工内容或源词库后续变化。`parsed_available=0` 时不能声称解析层没有该表达。语义错误提取数量无法仅凭字符串比较证明，故 `semantic_error_count_unknown=1` 表示尚未确证，而非错误数为 1。不会清空、重建或修改任何词本。实际新统计须运行工作流取得，不能套用此前 791/781 等历史数量。

进入 **Actions → MaiMemo Read-only Diagnostics → Run workflow → main**，启动一次，在 **diagnose → Diagnose MaiMemo (GET only)** 查看结果。使用现有 `MAIMEMO_TOKEN`、`EUDIC_AUTHORIZATION`、`EUDIC_BOOK_ID` Secrets，通过 GET 读取目标词本与欧路全部分页词条。目标 ID 从现有 `sync.yml` 读取。不会调用 POST/PUT/PATCH/DELETE、运行同步或通知，也不会记录词条、笔记正文、Token、完整 ID 或上下文。此前定位 `$1` 的逐条输出开关已关闭。

历史 `MAIMEMO_TITLE_AUDIT=true` 模式用于复核旧候选规则；正式同步资格以上述严格独立标题规则为准。候选允许词形中的数字、句点、Unicode 字母、组合附加符、词内连字符及撇号，完整保留短语空格；纯数字、复杂分隔符和括号不自动处理。多词且以句点结尾、无法确认是缩写的内容仍保守跳过。多行记录须有 Markdown 标题或显式笔记标题；不再对 `at a cost` 使用特殊截取规则。新增的通用行内边界限于：英文标题后 `:`/`：`/`=` 加中文释义（或 `meaning:`/`definition:`），明确的 `释义：` 等标记，以及“是一个/是一种”中文说明引导。不按第一个空格截断，不把任意中英文相邻当边界，也不回传笔记。这是保守的结构检查，仍需实际数据审计，不能证明任意纯字母短语的语义。

查看 `source=title_extraction`：`scanned` 为完整扫描条数；`syncable + skipped = scanned`；`plain`、`notes_extracted` 为可用候选分类；`ambiguous_multiline`、`unsupported_title` 为待跳过原因。`unique_titles`、`duplicate_titles` 区分词条与唯一标题，`already_present`、`would_add` 按原有逐行、区分大小写的合并规则统计。`confirmed_at_a_cost` 统计保留该短语的条数。`source=extracted_titles` 检查候选标题中是否还存在 `$1` 等字符。不会因跳过而删除墨墨已有行；未做 POST，数量不代表服务器已接受。实际截图已确认：791 条源记录中接受 782 条、跳过 9 条；其中两个标题均为 at a cost，去重后 781 个标题。3 条未能确认的句点/数字候选仍保守跳过，不等同于 3 条已确认正常词。

待跳过词条现额外输出 `source=title_skipped` 的互斥结构分类，各类数量之和等于 `skipped`：`same_line_definition_candidate`（疑似同一行释义）、`markdown_or_markup`、`note_heading`、`ambiguous_multiline`、`invisible_or_control`、`annotation_or_parentheses`、`multiple_title_separators`、`punctuated_or_alphanumeric_candidate`（可能是正常缩写/含数字词形）、`symbols_numbers_or_punctuation`，以及空值、首行缺失、非英文笔记候选和未分类项。`source=title_rule_review` 统计可能值得评估的通用规则及其命中数量：`definition_boundary_candidate`、`standalone_markdown_candidate`、`possible_normal_term`。这些是结构信号，不证明可可靠提取，也不证明其他分类都是异常词；不输出被跳过词条正文；普通格式不明确项继续保守跳过，不据此扩大规则。仅凭聚合数量不能验证语义，未分类项保持待复核。

标题审计额外模拟增量正文：保留已有 `content` 为完整前缀（含换行与空行），仅在末尾追加去重的新标题。查看 `existing_content_preserved=1`、`existing_chapters`、`final_chapters`、`existing_lines`、`final_lines` 及 `second_merge_additions=0`；`proposed_final_content` 只输出字符统计，不输出正文。正式 OpenAPI 同步也采用此追加结构；仅保留此前已明确允许的控制字符清理，正常文本、换行和空行不重排。官方 `api_bundle.yaml` 的更新接口要求 `notepad` 的 `status/content/title/brief/tags`，还将请求体 `id` 标为必填；`title` 是词本名称，提取的词条标题应追加在完整 `content` 中，不能只提交新增正文或把词条放到 `title`。正式请求体已补齐 id，并保留原 status/title/brief/tags；正式同步跳过日志仅输出数量与原因，新增词条正文不再写入日志。通知内容保持原有行为。

关闭标题审计后，原内容审计会在内存中调用生产清理、去重、合并函数，重建原同步逻辑拟提交的 content：

统计日志包含 `source`、`anomaly`、`codepoints`、`count`。对照 `eudic_word_raw`、`notepad_content_raw`、两处 `cleaned` 来源和 `final_content` 的 `literal_dollar_one` 数量，可区分输入已有 `$1`、清理后出现 `$1` 和最终正文不含 `$1`。音标、释义、例句标为 `ignored`，不参与合并；标题、简介、标签标为 `unchanged`，保持生产程序原有行为。审计不会修改原始或拟提交内容来迎合检查。`words_added=0` 时生产程序原本不会 POST。

不可见格式字符、特殊空格、符号、孤立代理项等只输出 Unicode 码位和数量，标为 `candidate` 的条目不等于墨墨不允许该字符，正常 Unicode 不会因此被删除。章节标记位置仅作格式提示。`server_error/not_reproduced_read_only` 明确表示此次没有 POST，不能凭只读审计证明服务器 `$1` 的模板含义，也不能排除两次运行之间数据变化。

以下为原列表/详情诊断模式（未开启 `MAIMEMO_CONTENT_AUDIT`）的日志说明：

每条诊断日志仅有 `http_status`、`error_code`、`target_match`、`pages_scanned`、`scanned_count`。后两项分别为已解析的列表页数（含结束空页）及累计扫描条数，不包括详情，不输出任何 ID。`http_status=0` 表示未取得 HTTP 响应或配置不可用；其余为实际 HTTP 状态码。非成功诊断会让该工作流失败，具体含义见下表：

| target_match | 含义与后续检查 |
|---|---|
| `unknown_authorization` | 401/403 或错误码表明授权异常；核对 Secret 的 Token 是否与演示页面使用的账号、权限范围和授权方式一致。 |
| `not_found_for_current_token` | 列表查询成功、遍历到空页且未匹配，随后仍会独立 GET 目标详情；不能仅据列表判断 Token 无权访问或词本归属。 |
| `matched_in_list` | 当前 Token 的列表中包含目标 ID，随后会使用同一 ID 独立 GET 详情。 |
| `matched_detail_ok` | 列表匹配且独立详情读取成功；若应用仍失败，优先对照应用版本、实际配置与请求构造。 |
| `matched_detail_failed` | 列表匹配，但独立详情请求也失败；结合状态码和错误码继续检查资源权限/API 行为，不能直接归因于应用。 |
| `not_found_detail_ok` | 列表未匹配，但同一 Token 可以读取目标；优先检查列表可见性/过滤行为，而不是认定账号不同。 |
| `not_found_detail_failed` | 列表未匹配且目标详情请求失败；可确认该请求下无法读取目标，但仅凭资源错误码仍无法区分账号、权限、授权范围或资源状态。 |
| `not_in_page` | 尚未在当前页匹配，继续下一页，不是最终结论。 |
| `unknown_not_exhausted` | 达到 10 页的诊断上限，不能认定 ID 不存在。 |
| `unknown` / `matched_detail_unknown` / `not_found_detail_unknown` | 传输、响应结构或其他错误，证据不足；参考状态码和安全错误码。 |

诊断不重试、不尝试其他 ID、路径或认证方案。列表每页 10 项、最多 10 页，偏移按实际收到的条数递增，短页后继续查询，空页才确认结束；匹配后停止分页。匹配或遍历至空页后，额外 GET 一次目标详情；达到页数上限且未匹配时只报告未扫描完。所有响应只在内存处理。可本地运行 Mock 和本机回环测试：`pwsh -File ./scripts/test-maimemo-diagnostics.ps1`，不会请求墨墨。

2026-10-16 参数核对：官方 YAML 明确支持整数查询参数 `limit`、`offset`，示例分别为 10 和 0，但未标注最大值；[官方演示](https://www.maimemo.com/pages/openapi-demo/index.html)的数量输入范围为 1–10，[官方 CLI](https://github.com/maimemo/memo-api-cli/blob/main/src/commands/notepad.ts)也默认使用 `limit=10&offset=0`。诊断和主程序均改用 10，后续偏移为 10、20 等，保留参数、认证和同步算法。原先的 100 超出官方演示范围，可能解释 `common_invalid_param`，仍需后续只读诊断确认；不能据此认定详情请求的 `common_invalid_res_id` 已解决。

HTTP 非成功响应会记录请求方法、脱敏 URL、数字状态码及服务器错误正文；异常消息也只包含脱敏信息。请求头和请求体不输出，URL 查询值与凭证会隐藏，JSON 只保留错误诊断字段，正文最多保留 4096 字符。不会自动重试。

获取 GitHub Actions 诊断日志：将修复提交推送到 GitHub 后，进入 **Actions → Sync Words → Run workflow**，选择包含修复的分支并启动一次。展开 **sync → Run Sync**，查找 `HTTP 请求失败`。请启动新运行；旧运行的 **Re-run jobs** 使用旧提交，不会自动加载这次修复。无需修改 Secrets。

2026-10-15 核对[墨墨官方 OpenAPI 规范](https://open.maimemo.com/api_bundle.yaml)：生产服务器为 `https://open.maimemo.com/open`，云词本列表使用 `GET /api/v1/memo/notepads`，详情使用 `GET /api/v1/memo/notepads/{id}`，更新使用 `POST /api/v1/memo/notepads/{id}`。项目三处请求统一包含 `/memo`，认证仍为 `Authorization: Bearer <token>`。此次路径修复保留原有词本 ID、合并逻辑、Secrets 和脱敏诊断；真实同步结果需通过后续手动运行确认。

## Todo

- [x] MVP 版本：默认词库自动同步（控制台程序）
- [x] 可注册为 Windows 服务，并定期执行
- [x] 接入消息通知服务
- [x] 接入墨墨开放 API（Legacy 网页方案仍可选）
- [x] GitHub Actions 定时同步
- [x] 调整项目打包方式，支持多平台部署
- [ ] ~~接入 Telegram Bot~~，计划做可操作界面
