# 仅供临时手动诊断。禁止输出请求、响应正文、异常详情或环境变量。
$ErrorActionPreference = 'Stop'

function Get-MaiMemoDiagnosticTargetId {
    param([string]$WorkflowPath)
    # 读取现有配置，避免复制或改变目标 ID，也避免 Actions 的 env 摘要打印 ID。
    # 仅接受单个静态 YAML 标量；配置变化时安全退出，不猜测 ID。
    $pattern = @'
(?m)^\s+MaiMemo__DefaultNotepadId:[ \t]*(?:"(?<double>[^"\r\n]+)"|'(?<single>[^'\r\n]+)'|(?<plain>[^\s#'"{}]+))[ \t]*(?:#.*)?\r?$
'@
    $matchesFound = [regex]::Matches([IO.File]::ReadAllText($WorkflowPath), $pattern)
    if ($matchesFound.Count -ne 1) { throw 'Unsupported target configuration' }
    foreach ($group in @('double', 'single', 'plain')) {
        if ($matchesFound[0].Groups[$group].Success) {
            $value = $matchesFound[0].Groups[$group].Value
            if ($value.Contains('${{')) { throw 'Unsupported target configuration' }
            return $value
        }
    }
    throw 'Missing target configuration'
}

function Invoke-MaiMemoDiagnosticGet {
    param([string]$Url, [string]$Token, [switch]$RawAuthorization)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(25)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    try {
        $authorization = if ($RawAuthorization) { $Token } else { "Bearer $Token" }
        $request.Headers.Add('Authorization', $authorization)
        $request.Headers.Add('Accept', 'application/json')
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            return @{
                Status = [int]$response.StatusCode
                Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
        }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose(); $client.Dispose() }
}

function Get-MaiMemoDiagnosticErrorCode {
    param($Payload, [string]$Token, [string]$TargetId)
    $codes = @($Payload.errors | ForEach-Object { $_.code }) + @($Payload.error.code, $Payload.code)
    $safeCodes = @($codes | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object {
        $value = "$_"
        # 不输出任意服务器字符串；只允许短错误码，且屏蔽凭证/ID 的回显。
        if ($value -cmatch '^[a-z][a-z0-9_]{0,63}$' -and
            !$value.Contains($Token, [StringComparison]::Ordinal) -and
            !$value.Contains($TargetId, [StringComparison]::Ordinal)) { $value }
        else { 'unavailable' }
    } | Select-Object -Unique -First 4)
    if ($safeCodes.Count -eq 0) { return 'none' }
    return $safeCodes -join ','
}

function Invoke-MaiMemoReadOnlyDiagnostic {
    param(
        [string]$Token,
        [string]$WorkflowPath = (Join-Path $PSScriptRoot '../.github/workflows/sync.yml'),
        [scriptblock]$Request = { param($url, $credential) Invoke-MaiMemoDiagnosticGet $url $credential },
        [scriptblock]$WriteLog = { param($line) Write-Host $line }
    )
    $scanStats = @{ Pages = 0; Count = 0 }
    $sink = $WriteLog
    $WriteLog = {
        param($line)
        & $sink "$line pages_scanned=$($scanStats.Pages) scanned_count=$($scanStats.Count)"
    }.GetNewClosure()
    try {
        if ([string]::IsNullOrWhiteSpace($Token)) { throw 'Missing credential' }
        $targetId = Get-MaiMemoDiagnosticTargetId $WorkflowPath
    }
    catch {
        & $WriteLog 'http_status=0 error_code=configuration_unavailable target_match=unknown'
        return 1
    }

    $baseUrl = 'https://open.maimemo.com/open/api/v1/memo/notepads'
    # YAML 支持整数 limit/offset；官方演示输入范围为 1..10，CLI 默认值也是 10。
    $pageSize = 10
    $offset = 0
    $foundInList = $false
    $listComplete = $false
    # 分页不重试；最多 10 页。达到上限不能判定 ID 不存在。
    for ($page = 0; $page -lt 10; $page++) {
        $queryOffset = $offset.ToString([Globalization.CultureInfo]::InvariantCulture)
        try { $result = & $Request "${baseUrl}?limit=$pageSize&offset=$queryOffset" $Token }
        catch {
            & $WriteLog 'http_status=0 error_code=transport_error target_match=unknown'
            return 1
        }
        $status = [int]$result.Status
        try { $payload = ConvertFrom-Json -InputObject $result.Body -Depth 64 }
        catch {
            $match = if ($status -in @(401, 403)) { 'unknown_authorization' } else { 'unknown' }
            & $WriteLog "http_status=$status error_code=non_json_response target_match=$match"
            return 1
        }
        $code = Get-MaiMemoDiagnosticErrorCode $payload $Token $targetId
        if ($status -lt 200 -or $status -ge 300 -or $payload.success -eq $false -or $code -ne 'none') {
            $match = if ($status -in @(401, 403) -or $code -match 'auth|token|permission|forbidden|scope') {
                'unknown_authorization'
            } else { 'unknown' }
            & $WriteLog "http_status=$status error_code=$code target_match=$match"
            return 1
        }
        $listPayload = if ($null -ne $payload.data) { $payload.data } else { $payload }
        $items = $listPayload.notepads
        # 数组必须存在；无正文/错误结构不能误报为列表为空或 ID 不属于 Token。
        if ($null -eq $items -or $items -isnot [array] -or
            @($items | Where-Object { $_.id -isnot [string] -or [string]::IsNullOrEmpty($_.id) }).Count -gt 0) {
            & $WriteLog "http_status=$status error_code=unexpected_list_response target_match=unknown"
            return 1
        }
        $found = @($items | Where-Object { $_.id -is [string] -and $_.id -ceq $targetId }).Count -gt 0
        $scanStats.Pages++
        $scanStats.Count += $items.Count
        if ($found) {
            & $WriteLog "http_status=$status error_code=none target_match=matched_in_list"
            $foundInList = $true
            break
        }
        if ($items.Count -eq 0) {
            & $WriteLog "http_status=$status error_code=none target_match=not_found_for_current_token"
            $listComplete = $true
            break
        }
        # 不假定短页就是末页；按实际数量推进，避免服务端缩小页面时跳过记录。
        $offset += $items.Count
        & $WriteLog "http_status=$status error_code=none target_match=not_in_page"
    }
    if (!$foundInList -and !$listComplete) {
        & $WriteLog 'http_status=200 error_code=page_limit_reached target_match=unknown_not_exhausted'
        return 1
    }

    # 列表匹配或完整遍历后，均只用现有 ID/Token 独立 GET 一次详情。
    $matchPrefix = if ($foundInList) { 'matched' } else { 'not_found' }
    try { $detail = & $Request "$baseUrl/$([Uri]::EscapeDataString($targetId))" $Token }
    catch {
        & $WriteLog "http_status=0 error_code=transport_error target_match=${matchPrefix}_detail_unknown"
        return 1
    }
    $detailStatus = [int]$detail.Status
    try { $detailPayload = ConvertFrom-Json -InputObject $detail.Body -Depth 64 }
    catch {
        & $WriteLog "http_status=$detailStatus error_code=non_json_response target_match=${matchPrefix}_detail_unknown"
        return 1
    }
    $detailCode = Get-MaiMemoDiagnosticErrorCode $detailPayload $Token $targetId
    if ($detailStatus -lt 200 -or $detailStatus -ge 300 -or
        $detailPayload.success -eq $false -or $detailCode -ne 'none') {
        & $WriteLog "http_status=$detailStatus error_code=$detailCode target_match=${matchPrefix}_detail_failed"
        return 1
    }
    $notepad = if ($null -ne $detailPayload.data) { $detailPayload.data.notepad } else { $detailPayload.notepad }
    if ($null -eq $notepad -or $notepad.id -cne $targetId) {
        & $WriteLog "http_status=$detailStatus error_code=unexpected_detail_response target_match=${matchPrefix}_detail_unknown"
        return 1
    }
    & $WriteLog "http_status=$detailStatus error_code=none target_match=${matchPrefix}_detail_ok"
    return 0
}

function Write-MaiMemoTextAudit {
    param([string]$Source, [string[]]$Texts, [scriptblock]$WriteLog)
    $literalCount = 0
    $points = @{}
    foreach ($text in $Texts) {
        if ($null -eq $text) { continue }
        # 逐条计数，不把两个独立词条的 "$" 和 "1" 拼成误报。
        $literalCount += [regex]::Matches($text, [regex]::Escape('$1')).Count
        for ($index = 0; $index -lt $text.Length; $index++) {
            $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($text, $index)
            $point = [int][char]$text[$index]
            if ([char]::IsHighSurrogate($text[$index]) -and $index + 1 -lt $text.Length -and
                [char]::IsLowSurrogate($text[$index + 1])) {
                $point = [char]::ConvertToUtf32($text, $index)
                $index++
            }
            $kind = switch ($category.ToString()) {
                'Control' { if ($point -notin @(10, 13)) { 'control_candidate' }; break }
                'Format' { 'invisible_format_candidate'; break }
                'SpaceSeparator' { if ($point -ne 32) { 'unicode_space_candidate' }; break }
                'LineSeparator' { 'unicode_line_separator_candidate'; break }
                'ParagraphSeparator' { 'unicode_line_separator_candidate'; break }
                'Surrogate' { 'unpaired_surrogate'; break }
                'PrivateUse' { 'private_use_candidate'; break }
                'OtherNotAssigned' { 'unassigned_candidate'; break }
                { $_ -in @('MathSymbol', 'CurrencySymbol', 'ModifierSymbol', 'OtherSymbol') } { 'symbol_candidate'; break }
                default { $null }
            }
            if ($kind) {
                $hex = 'U+{0:X4}' -f $point
                $key = "$kind|$hex"
                if (!$points.ContainsKey($key)) { $points[$key] = 0 }
                $points[$key]++
            }
        }
    }
    & $WriteLog "source=$Source anomaly=literal_dollar_one codepoints=U+0024,U+0031 count=$literalCount"
    # 只输出码位/类别/总数，既不输出字符本身，也不输出其顺序、词条或上下文。
    $keys = @($points.Keys | Sort-Object)
    foreach ($key in ($keys | Select-Object -First 64)) {
        $parts = $key.Split('|')
        & $WriteLog "source=$Source anomaly=$($parts[0]) codepoints=$($parts[1]) count=$($points[$key])"
    }
    if ($keys.Count -gt 64) {
        & $WriteLog "source=$Source anomaly=codepoint_summary_truncated codepoints=none count=$($keys.Count - 64)"
    }
}

# 审计与正式同步共用同一份提取代码；这里不执行写入。
function Get-EudicTitleCandidate {
    param([AllowEmptyString()][string]$Word)
    if (!('EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper' -as [type])) {
        $helperPath = Join-Path $PSScriptRoot '../src/EudicSyncToMaiMemo.Services/Helpers/NotepadWordMergeHelper.cs'
        Add-Type -TypeDefinition ("using System; using System.Collections.Generic; using System.Linq;`n" + [IO.File]::ReadAllText($helperPath)) -ErrorAction Stop
    }
    $removed = 0
    $cleaned = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::RemoveInvalidControlCharacters($Word, [ref]$removed)
    return [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::ExtractTitle($cleaned)
}

# 仅描述已经被跳过的原始数据形态，不提取新标题或改变跳过决定。
function Get-EudicSkippedTitleClassification {
    param([AllowEmptyString()][string]$Word, [string]$Reason)
    $first = ([regex]::Split($Word, '\r\n|\n|\r'))[0].Trim()
    $english = '[A-Za-z]+(?:[''\u2019-][A-Za-z]+)*(?: +[A-Za-z]+(?:[''\u2019-][A-Za-z]+)*)*'
    $category = 'other_unsupported'
    $proposal = 'none'
    if ([string]::IsNullOrWhiteSpace($Word)) { $category = 'empty' }
    elseif (!$first) { $category = 'missing_first_line_title' }
    elseif ($Reason -eq 'ambiguous_multiline') { $category = 'ambiguous_multiline' }
    elseif ($first -match '^(?:#{1,6}\s+)?(?:学习笔记|笔记|释义|例句|Notes|Examples|Definition)(?:[:：\s]|$)') { $category = 'note_heading' }
    elseif ($first -cmatch "^$english(?: +[\u3400-\u9FFF]|\s*[:：=])") {
        $category = 'same_line_definition_candidate'; $proposal = 'definition_boundary_candidate'
    }
    elseif ($first -match '^(?:#{1,6}\s|\*|_|`|>|-\s|\[)|[\[\]`*]') {
        $category = 'markdown_or_markup'
        if ($first -cmatch ('^(?:\*\*{0}\*\*|__{0}__|`{0}`)$' -f $english)) { $proposal = 'standalone_markdown_candidate' }
    }
    elseif ($first -match '[\p{Cc}\p{Cf}]|[^\S ]') { $category = 'invisible_or_control' }
    elseif ($first -match '[()（）\[\]]') { $category = 'annotation_or_parentheses' }
    elseif ($first -match '[/,，;；]') { $category = 'multiple_title_separators' }
    elseif ($first -cmatch '^[A-Za-z][A-Za-z0-9 .''\u2019-]*$') {
        $category = 'punctuated_or_alphanumeric_candidate'; $proposal = 'possible_normal_term'
    }
    elseif ($first -match '[\p{S}\p{N}\p{P}]') { $category = 'symbols_numbers_or_punctuation' }
    elseif ($first -match '^[\u3400-\u9FFF]') { $category = 'non_english_note_candidate' }
    return @{ Category = $category; Proposal = $proposal }
}

function Write-EudicTitleAudit {
    param([string[]]$Words, [string]$ExistingContent, [scriptblock]$WriteLog)
    $titles = [Collections.Generic.List[string]]::new()
    $counts = @{ scanned = $Words.Count; syncable = 0; skipped = 0; plain = 0; notes_extracted = 0;
        ambiguous_multiline = 0; unsupported_title = 0; confirmed_at_a_cost = 0 }
    $skipCategories = @{}
    $proposals = @{}
    foreach ($word in $Words) {
        $candidate = Get-EudicTitleCandidate $word
        $counts[$candidate.Reason]++
        if ($null -eq $candidate.Title) {
            $counts.skipped++
            $classification = Get-EudicSkippedTitleClassification $word $candidate.Reason
            $skipCategories[$classification.Category]++
            if ($classification.Proposal -ne 'none') { $proposals[$classification.Proposal]++ }
            continue
        }
        $counts.syncable++
        $titles.Add($candidate.Title)
        if ($candidate.Title -ceq 'at a cost') { $counts.confirmed_at_a_cost++ }
    }
    $existingRemoved = 0
    $cleanedExisting = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::RemoveInvalidControlCharacters($ExistingContent, [ref]$existingRemoved)
    $counts.existing_controls_removed = $existingRemoved
    $existing = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::SplitContentLines($cleanedExisting)
    $merge = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::Merge($existing, $titles)
    $unique = [Collections.Generic.HashSet[string]]::new($titles, [StringComparer]::Ordinal)
    $counts.unique_titles = $unique.Count
    $counts.duplicate_titles = $titles.Count - $unique.Count
    $counts.already_present = $unique.Count - $merge.Item1.Count
    $counts.would_add = $merge.Item1.Count
    # 更新 content 必须携带完整已有正文；保留 CRLF、空行和章节，仅追加新增标题。
    $finalContent = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::AppendNewTitles($cleanedExisting, $merge.Item1)
    $counts.existing_lines = $existing.Count
    $counts.existing_chapters = [regex]::Matches($ExistingContent, '(?m)^#').Count
    $counts.final_chapters = [regex]::Matches($finalContent, '(?m)^#').Count
    $counts.final_lines = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::SplitContentLines($finalContent).Count
    $counts.existing_content_preserved = [int]$finalContent.StartsWith($ExistingContent, [StringComparison]::Ordinal)
    $counts.second_merge_additions = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::Merge(
        [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::SplitContentLines($finalContent), $titles).Item1.Count
    foreach ($key in ($counts.Keys | Sort-Object)) {
        & $WriteLog "source=title_extraction anomaly=$key codepoints=none count=$($counts[$key])"
    }
    # 主分类互斥，数量之和必须等于 skipped；候选规则统计不代表已确认可恢复。
    foreach ($key in ($skipCategories.Keys | Sort-Object)) {
        & $WriteLog "source=title_skipped anomaly=$key codepoints=none count=$($skipCategories[$key])"
    }
    foreach ($key in ($proposals.Keys | Sort-Object)) {
        & $WriteLog "source=title_rule_review anomaly=$key codepoints=none count=$($proposals[$key])"
    }
    # 保持已有词本逐行不变；只在内存中检查候选新增标题。
    Write-MaiMemoTextAudit 'extracted_titles' $titles.ToArray() $WriteLog
    Write-MaiMemoTextAudit 'proposed_final_content' @($finalContent) $WriteLog
}

function Write-EudicSourceAudit {
    param([string[]]$Words, $Notepad, [hashtable]$Ignored, [scriptblock]$WriteLog, [bool]$IsDefaultBook = $false)
    $rawSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $literalTitles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $titles = [Collections.Generic.List[string]]::new()
    $candidates = [Collections.Generic.List[object]]::new()
    $derived = 0
    foreach ($word in $Words) {
        [void]$rawSet.Add($word)
        $candidate = Get-EudicTitleCandidate $word
        $candidates.Add($candidate)
        if ($null -ne $candidate.Title) {
            $titles.Add($candidate.Title)
            if ($candidate.Reason -eq 'notes_extracted') { $derived++ }
            if ($word.Trim() -ceq $candidate.Title) { [void]$literalTitles.Add($candidate.Title) }
        }
    }
    $titleSet = [Collections.Generic.HashSet[string]]::new($titles, [StringComparer]::Ordinal)
    $contentLines = @([EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::SplitContentLines($Notepad.content) | Where-Object { !($_.StartsWith('#')) -and $_ -cne '//' })
    $contentSet = [Collections.Generic.HashSet[string]]::new([string[]]$contentLines, [StringComparer]::Ordinal)
    $parsed = [Collections.Generic.List[string]]::new()
    $parsedAvailable = $Notepad.list -is [array]
    $unknownItems = 0
    if ($parsedAvailable) {
        foreach ($item in $Notepad.list) {
            if ($item.type -cin @('WORD', 'DRAFT_WORD') -and $item.word -is [string]) { $parsed.Add($item.word) }
            elseif ($item.type -cne 'CHAPTER') { $unknownItems++ }
        }
    }
    $parsedSet = [Collections.Generic.HashSet[string]]::new($parsed, [StringComparer]::Ordinal)
    $summary = @{
        records_scanned = $Words.Count; raw_unique = $rawSet.Count; raw_exact_duplicates = $Words.Count - $rawSet.Count;
        accepted_records = $titles.Count; valid_unique_titles = $titleSet.Count; title_duplicates = $titles.Count - $titleSet.Count;
        rejected_records = $Words.Count - $titles.Count; titles_from_notes = $derived;
        literal_valid_unique_titles = $literalTitles.Count;
        derived_only_unique_titles = @($titleSet | Where-Object { !$literalTitles.Contains($_) }).Count;
        content_rows = $contentLines.Count; content_unique = $contentSet.Count; content_duplicates = $contentLines.Count - $contentSet.Count;
        content_without_current_title = @($contentSet | Where-Object { !$titleSet.Contains($_) }).Count;
        titles_missing_from_content = @($titleSet | Where-Object { !$contentSet.Contains($_) }).Count;
        parsed_available = [int]$parsedAvailable; parsed_word_rows = $parsed.Count; parsed_unique_words = $parsedSet.Count;
        parsed_unknown_items = $unknownItems;
        parsed_without_content_line = @($parsedSet | Where-Object { !$contentSet.Contains($_) }).Count;
        content_starts_chapter = [int]$Notepad.content.StartsWith('#'); content_starts_prototype = [int]$Notepad.content.StartsWith('//');
        semantic_error_count_unknown = 1
        default_book_configured = [int]$IsDefaultBook
        target_title_matches = [int]($Notepad.title -ceq '欧路词典同步')
    }
    foreach ($key in ($summary.Keys | Sort-Object)) { & $WriteLog "source=source_audit anomaly=$key codepoints=none count=$($summary[$key])" }
    # 仅针对用户指定表达输出计数，不能将子串命中当作独立收藏或同步新增的证据。
    $focus = [ordered]@{ do_with = 'do with'; do_with_sth = 'do with sth.'; boil_down = 'boil down'; boil_down_to = 'boil down to'; boil_down_to_sth = 'boil down to sth.'; down_to = 'down to' }
    foreach ($key in $focus.Keys) {
        $term = $focus[$key]
        $metrics = @{ raw_exact = 0; raw_trimmed_exact = 0; raw_casefold_exact = 0; first_line_exact = 0; extracted_title_exact = 0; title_casefold_exact = 0;
            raw_embedded_not_title = 0; notes_body_mentions = 0; ignored_metadata_mentions = 0;
            content_line_exact = 0; parsed_word_exact = 0 }
        $pattern = '(?<![\p{L}\p{Nd}])' + [regex]::Escape($term) + '(?![\p{L}\p{Nd}])'
        for ($index = 0; $index -lt $Words.Count; $index++) {
            $word = $Words[$index]
            $lines = [regex]::Split($word, '\r\n|\n|\r')
            if ($word -ceq $term) { $metrics.raw_exact++ }
            if ($word.Trim() -ceq $term) { $metrics.raw_trimmed_exact++ }
            if ($word.Trim().Equals($term, [StringComparison]::OrdinalIgnoreCase)) { $metrics.raw_casefold_exact++ }
            if ($null -ne $candidates[$index].Title -and $candidates[$index].Title.Equals($term, [StringComparison]::OrdinalIgnoreCase)) { $metrics.title_casefold_exact++ }
            if ($lines[0].Trim() -ceq $term) { $metrics.first_line_exact++ }
            if ($candidates[$index].Title -ceq $term) { $metrics.extracted_title_exact++ }
            elseif ([regex]::IsMatch($word, $pattern)) { $metrics.raw_embedded_not_title++ }
            if ($lines.Count -gt 1 -and [regex]::IsMatch(($lines[1..($lines.Count - 1)] -join "`n"), $pattern)) { $metrics.notes_body_mentions++ }
        }
        foreach ($field in @('phon', 'exp', 'context_line')) {
            foreach ($text in $Ignored[$field]) { if ([regex]::IsMatch($text, $pattern)) { $metrics.ignored_metadata_mentions++ } }
        }
        $metrics.content_line_exact = @($contentLines | Where-Object { $_ -ceq $term }).Count
        $metrics.parsed_word_exact = @($parsed | Where-Object { $_ -ceq $term }).Count
        foreach ($metric in ($metrics.Keys | Sort-Object)) { & $WriteLog "source=focus_$key anomaly=$metric codepoints=none count=$($metrics[$metric])" }
    }
}

function Write-StrictDifferenceAudit {
    param([string[]]$Words, $Notepad, [scriptblock]$Request, [string]$Token, [scriptblock]$WriteLog)
    $helper = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]
    $titles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $records = foreach ($word in $Words) {
        $removed = 0
        $cleaned = $helper::RemoveInvalidControlCharacters($word, [ref]$removed)
        $strict = $helper::ExtractIndependentTitle($cleaned)
        $relaxed = $helper::ExtractTitle($cleaned)
        if ($null -ne $strict.Title) { [void]$titles.Add($strict.Title) }
        [pscustomobject]@{ Raw = $word; Cleaned = $cleaned; Strict = $strict; Relaxed = $relaxed }
    }
    $stored = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $helper::SplitContentLines($Notepad.content)) {
        if (![string]::IsNullOrWhiteSpace($line) -and !$line.StartsWith('#')) { [void]$stored.Add($line) }
    }
    $extra = @($stored | Where-Object { !$titles.Contains($_) } | Sort-Object -CaseSensitive)
    # This temporary disclosure is authorized for exactly the three difference titles only.
    if ($extra.Count -ne 3) {
        & $WriteLog "difference_audit_stopped=unexpected_difference_count count=$($extra.Count)"
        return
    }
    foreach ($term in $extra) {
        if ($null -eq $helper::ExtractIndependentTitle($term).Title -or $term.Length -gt 120) {
            & $WriteLog 'difference_audit_stopped=unsafe_title'
            return
        }
    }
    $history = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $historyStatus = 'unavailable'
    try {
        # The old notebook is retained; inspect its raw body only, never parser expansions.
        $offset = 0; $oldIds = [Collections.Generic.List[string]]::new(); $complete = $false
        for ($page = 0; $page -lt 50; $page++) {
            $response = & $Request "https://open.maimemo.com/open/api/v1/memo/notepads?limit=10&offset=$offset" "Bearer $Token"
            if ([int]$response.Status -ne 200) { throw 'History unavailable' }
            $payload = ConvertFrom-Json $response.Body -Depth 64
            if ($payload.success -eq $false -or $payload.data.notepads -isnot [array]) { throw 'History unavailable' }
            foreach ($item in $payload.data.notepads) {
                if ($item.title -ceq '欧路词典同步' -and $item.id -is [string] -and $item.id -cne $Notepad.id) { $oldIds.Add($item.id) }
            }
            if ($payload.data.notepads.Count -lt 10) { $complete = $true; break }
            $offset += $payload.data.notepads.Count
        }
        if (!$complete) { throw 'History incomplete' }
        foreach ($id in $oldIds) {
            $response = & $Request "https://open.maimemo.com/open/api/v1/memo/notepads/$([Uri]::EscapeDataString($id))" "Bearer $Token"
            if ([int]$response.Status -ne 200) { throw 'History unavailable' }
            $payload = ConvertFrom-Json $response.Body -Depth 64
            if ($payload.success -eq $false -or $payload.data.notepad.id -cne $id -or $payload.data.notepad.content -isnot [string]) { throw 'History unavailable' }
            foreach ($line in $helper::SplitContentLines($payload.data.notepad.content)) { [void]$history.Add($line) }
        }
        $historyStatus = if ($oldIds.Count) { 'old_notebook_body_checked' } else { 'no_old_notebook_found' }
    } catch { $history.Clear(); $historyStatus = 'unavailable' }
    foreach ($term in $extra) {
        $raw = @($records | Where-Object { $_.Raw.Trim() -ceq $term }).Count
        $skipped = @($records | Where-Object { $null -eq $_.Strict.Title -and ($_.Relaxed.Title -ceq $term -or ([regex]::Split($_.Cleaned, '\r\n|\n|\r')[0].Trim() -ceq $term)) }).Count
        $casefold = @($titles | Where-Object { $_.Equals($term, [StringComparison]::OrdinalIgnoreCase) }).Count
        $row = [ordered]@{ title = $term; raw_exact = $raw; skipped_record_match = $skipped;
            current_title_casefold_match = $casefold; historical_check = $historyStatus;
            old_notebook_body_match = [int]$history.Contains($term);
            origin = $(if ($skipped) { 'current_record_rejected_by_strict_rule' } elseif ($casefold) { 'possible_title_case_change' } else { 'not_in_current_source_cause_unproven' }) }
        & $WriteLog ('difference_json=' + ($row | ConvertTo-Json -Compress))
    }
}

function Write-StrictSyncPreview {
    param([string[]]$Words, $Notepad, [scriptblock]$WriteLog)
    $titles = [Collections.Generic.List[string]]::new()
    $invalid = 0; $notes = 0
    foreach ($word in $Words) {
        $removed = 0
        $cleaned = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::RemoveInvalidControlCharacters($word, [ref]$removed)
        $candidate = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::ExtractIndependentTitle($cleaned)
        if ($null -ne $candidate.Title) { $titles.Add($candidate.Title) }
        elseif ($candidate.Reason -eq 'non_independent_record') { $notes++ }
        else { $invalid++ }
    }
    $plan = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::PrepareStrictContent($Notepad.content, $titles)
    $prepared = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::PrepareStrictContent($plan.Content, $titles)
    $metrics = @{ scanned = $Words.Count; accepted_records = $titles.Count; unique_titles = $plan.SourceUnique;
        invalid_or_ambiguous = $invalid; notes_excluded = $notes; total_excluded = $invalid + $notes;
        source_duplicates = $titles.Count - $plan.SourceUnique; target_titles = $plan.StoredTitles; missing = $plan.Missing;
        extra = $plan.Extra; target_duplicates = $plan.Duplicates; invalid_lines = $plan.InvalidLines;
        target_chapter_mode = [int]$plan.ChapterMode; ready = [int]$plan.Safe; would_add = $plan.NewTitles.Count;
        current_set_equal = [int]($plan.Safe -and $plan.Missing -eq 0);
        prepared_set_equal = [int]($plan.Safe -and $prepared.Safe -and $prepared.Missing -eq 0);
        prepared_missing = $prepared.Missing; prepared_extra = $prepared.Extra }
    $metrics.original_content_preserved = [int]$plan.Content.StartsWith($Notepad.content, [StringComparison]::Ordinal)
    $metrics.prepared_union_equal = [int][EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::VerifyStrictAppend($Notepad.content, $plan, $plan.Content, $titles)
    $metrics.second_merge_additions = $prepared.NewTitles.Count
    $metrics.prepared_total_titles = $prepared.StoredTitles
    # Under additive policy, set equality means equality to original titles UNION source.
    $metrics.prepared_set_equal = $metrics.prepared_union_equal
    foreach ($key in ($metrics.Keys | Sort-Object)) { & $WriteLog "source=strict_preview anomaly=$key codepoints=none count=$($metrics[$key])" }
    & $WriteLog "source=strict_preview anomaly=$($plan.Reason) codepoints=none count=1"
    if ($Notepad.list -is [array]) {
        $body = [Collections.Generic.HashSet[string]]::new([string[]][EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::SplitContentLines($Notepad.content), [StringComparer]::Ordinal)
        $parsed = @($Notepad.list | Where-Object { $_.type -cin @('WORD', 'DRAFT_WORD') -and $_.word -is [string] } | ForEach-Object { $_.word } | Sort-Object -Unique -CaseSensitive)
        $parsedOnly = @($parsed | Where-Object { !$body.Contains($_) }).Count
        & $WriteLog "source=parser_layer anomaly=expressions_without_body_line codepoints=none count=$parsedOnly"
    }
    # 只读预览可成功报告被阻止的旧目标；ready=0 不代表可以更新。
}

function Invoke-MaiMemoContentAudit {
    param(
        [string]$Token,
        [string]$EudicAuthorization,
        [string]$EudicBookId,
        [switch]$LocateLiteralDollarOne,
        [switch]$TitleAudit,
        [switch]$SourceAudit,
        [switch]$StrictPreview,
        [switch]$DifferenceAudit,
        [string]$WorkflowPath = (Join-Path $PSScriptRoot '../.github/workflows/sync.yml'),
        [scriptblock]$Request = { param($url, $authorization) Invoke-MaiMemoDiagnosticGet $url $authorization -RawAuthorization },
        [scriptblock]$WriteLog = { param($line) Write-Host $line }
    )
    try {
        if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($EudicAuthorization) -or
            [string]::IsNullOrWhiteSpace($EudicBookId)) { throw 'Missing configuration' }
        $targetId = Get-MaiMemoDiagnosticTargetId $WorkflowPath
        if (!('EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper' -as [type])) {
            # 直接编译本次检出的生产 helper 源码，不另写清理/去重算法。
            $helperPath = Join-Path $PSScriptRoot '../src/EudicSyncToMaiMemo.Services/Helpers/NotepadWordMergeHelper.cs'
            $usings = "using System; using System.Collections.Generic; using System.Linq;`n"
            Add-Type -TypeDefinition ($usings + [IO.File]::ReadAllText($helperPath)) -ErrorAction Stop
        }
    }
    catch {
        & $WriteLog 'source=configuration anomaly=audit_unavailable codepoints=none count=1'
        return 1
    }

    try { $response = & $Request "https://open.maimemo.com/open/api/v1/memo/notepads/$([Uri]::EscapeDataString($targetId))" "Bearer $Token" }
    catch {
        & $WriteLog 'source=maimemo_fetch anomaly=transport_error codepoints=none count=1'
        return 1
    }
    if ([int]$response.Status -lt 200 -or [int]$response.Status -ge 300) {
        & $WriteLog "source=maimemo_fetch anomaly=http_$([int]$response.Status) codepoints=none count=1"
        return 1
    }
    try {
        $payload = ConvertFrom-Json -InputObject $response.Body -Depth 64
        if ($payload.success -eq $false -or @($payload.errors | Where-Object { $null -ne $_ }).Count -gt 0) { throw 'API error' }
        # 与生产程序的 EnvelopeDto 路径一致，不从另一种响应结构猜测正文。
        $notepad = $payload.data.notepad
        if ($null -eq $notepad -or $notepad.id -cne $targetId -or $notepad.content -isnot [string]) { throw 'Unexpected notepad' }
    }
    catch {
        & $WriteLog 'source=maimemo_fetch anomaly=unexpected_response codepoints=none count=1'
        return 1
    }

    $words = [Collections.Generic.List[string]]::new()
    $ignored = @{ phon = [Collections.Generic.List[string]]::new(); exp = [Collections.Generic.List[string]]::new(); context_line = [Collections.Generic.List[string]]::new() }
    $complete = $false
    for ($page = 0; $page -le 50; $page++) {
        $url = 'https://api.frdic.com/api/open/v1/studylist/words?language=en&category_id={0}&page={1}&page_size=100' -f
            [Uri]::EscapeDataString($EudicBookId), $page.ToString([Globalization.CultureInfo]::InvariantCulture)
        try { $response = & $Request $url $EudicAuthorization }
        catch {
            & $WriteLog 'source=eudic_fetch anomaly=transport_error codepoints=none count=1'
            return 1
        }
        if ([int]$response.Status -lt 200 -or [int]$response.Status -ge 300) {
            & $WriteLog "source=eudic_fetch anomaly=http_$([int]$response.Status) codepoints=none count=1"
            return 1
        }
        try {
            $payload = ConvertFrom-Json -InputObject $response.Body -Depth 64
            if ($payload.success -eq $false -or $payload.data -isnot [array]) { throw 'Unexpected word list' }
            foreach ($entry in $payload.data) {
                if ($null -eq $entry) { throw 'Null entry' }
                # WordDto 缺失 word 时默认空串；显式 null 则无法按生产清理函数重建。
                $word = if ($entry.PSObject.Properties.Name -contains 'word') { $entry.word } else { '' }
                if ($word -isnot [string]) { throw 'Non-string word' }
                $words.Add($word)
                foreach ($field in @('phon', 'exp', 'context_line')) {
                    if ($entry.$field -is [string]) { $ignored[$field].Add($entry.$field) }
                }
            }
        }
        catch {
            & $WriteLog 'source=eudic_fetch anomaly=unexpected_response codepoints=none count=1'
            return 1
        }
        if ($payload.data.Count -lt 100) { $complete = $true; break }
    }
    if (!$complete) {
        & $WriteLog 'source=eudic_fetch anomaly=scan_not_exhausted codepoints=none count=1'
        return 1
    }

    if ($DifferenceAudit) {
        Write-StrictDifferenceAudit $words.ToArray() $notepad $Request $Token $WriteLog
        return 0
    }
    if ($StrictPreview) {
        Write-StrictSyncPreview $words.ToArray() $notepad $WriteLog
        return 0
    }
    if ($SourceAudit) {
        Write-EudicSourceAudit $words.ToArray() $notepad $ignored $WriteLog -IsDefaultBook ($EudicBookId -ceq '0')
        return 0
    }
    if ($TitleAudit) {
        Write-EudicTitleAudit $words.ToArray() $notepad.content $WriteLog
        return 0
    }
    $removed = 0
    $cleanedExisting = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::RemoveInvalidControlCharacters($notepad.content, [ref]$removed)
    $cleanedWords = [Collections.Generic.List[string]]::new()
    foreach ($word in $words) {
        $cleaned = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::RemoveInvalidControlCharacters($word, [ref]$removed)
        if (![string]::IsNullOrWhiteSpace($cleaned)) { $cleanedWords.Add($cleaned) }
    }
    $existingLines = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::SplitContentLines($cleanedExisting)
    $merged = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::Merge($existingLines, $cleanedWords)
    $finalContent = [EudicSyncToMaiMemo.Services.Helpers.NotepadWordMergeHelper]::JoinContentLines($merged.Item2)
    & $WriteLog "source=eudic_word_raw anomaly=entries_scanned codepoints=none count=$($words.Count)"
    if ($LocateLiteralDollarOne) {
        foreach ($word in $words) {
            if (!$word.Contains('$1', [StringComparison]::Ordinal)) { continue }
            # 仅定位用户授权的原始 word 命中项；JSON 转义防止换行/控制字符注入日志。
            $safeWord = $word
            foreach ($secret in @($Token, $EudicAuthorization, ($EudicAuthorization -replace '^\S+\s+', ''), $targetId, $EudicBookId)) {
                if (![string]::IsNullOrEmpty($secret)) { $safeWord = $safeWord.Replace($secret, '[REDACTED]') }
            }
            $encodedWord = ConvertTo-Json -InputObject $safeWord -Compress -EscapeHandling EscapeNonAscii
            & $WriteLog "source=eudic_word_raw anomaly=literal_dollar_one_entry word_json=$encodedWord"
        }
    }
    & $WriteLog "source=merge anomaly=words_added codepoints=none count=$($merged.Item1.Count)"
    Write-MaiMemoTextAudit 'eudic_word_raw' $words.ToArray() $WriteLog
    Write-MaiMemoTextAudit 'notepad_content_raw' @($notepad.content) $WriteLog
    foreach ($field in @('phon', 'exp', 'context_line')) { Write-MaiMemoTextAudit "eudic_${field}_ignored" $ignored[$field].ToArray() $WriteLog }
    Write-MaiMemoTextAudit 'eudic_word_cleaned' $cleanedWords.ToArray() $WriteLog
    Write-MaiMemoTextAudit 'notepad_content_cleaned' @($cleanedExisting) $WriteLog
    Write-MaiMemoTextAudit 'final_content' @($finalContent) $WriteLog
    # 元数据也会随更新请求提交，但不参与词表合并，审计不修改它们。
    Write-MaiMemoTextAudit 'notepad_title_unchanged' @($notepad.title) $WriteLog
    Write-MaiMemoTextAudit 'notepad_brief_unchanged' @($notepad.brief) $WriteLog
    Write-MaiMemoTextAudit 'notepad_tags_unchanged' @($notepad.tags) $WriteLog
    $chapters = [regex]::Matches($finalContent, '(?m)^#').Count
    if ($chapters -gt 0 -and !$finalContent.StartsWith('#', [StringComparison]::Ordinal)) {
        & $WriteLog "source=final_content anomaly=chapter_mode_not_enabled_candidate codepoints=U+0023 count=$chapters"
    }
    # 没有 POST，因此无法验证服务器的字符白名单或重现其 $1 错误模板。
    & $WriteLog 'source=server_error anomaly=not_reproduced_read_only codepoints=none count=0'
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($env:MAIMEMO_CONTENT_AUDIT -eq 'true') {
            exit (Invoke-MaiMemoContentAudit -Token $env:MAIMEMO_TOKEN -EudicAuthorization $env:EUDIC_AUTHORIZATION -EudicBookId $env:EUDIC_BOOK_ID -LocateLiteralDollarOne:($env:MAIMEMO_LOCATE_DOLLAR_ONE -eq 'true') -TitleAudit:($env:MAIMEMO_TITLE_AUDIT -eq 'true') -SourceAudit:($env:MAIMEMO_SOURCE_AUDIT -eq 'true') -StrictPreview:($env:MAIMEMO_STRICT_PREVIEW -eq 'true') -DifferenceAudit:($env:MAIMEMO_DIFFERENCE_AUDIT -eq 'true'))
        }
        exit (Invoke-MaiMemoReadOnlyDiagnostic -Token $env:MAIMEMO_TOKEN)
    }
    catch {
        # 最外层也不打印异常，防止 PowerShell 将 URL、Header 或响应正文带入日志。
        if ($env:MAIMEMO_CONTENT_AUDIT -eq 'true') {
            Write-Host 'source=audit anomaly=unexpected_error codepoints=none count=1'
            exit 1
        }
        Write-Host 'http_status=0 error_code=diagnostic_error target_match=unknown'
        exit 1
    }
}
