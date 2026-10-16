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

function Invoke-MaiMemoContentAudit {
    param(
        [string]$Token,
        [string]$EudicAuthorization,
        [string]$EudicBookId,
        [switch]$LocateLiteralDollarOne,
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
            exit (Invoke-MaiMemoContentAudit -Token $env:MAIMEMO_TOKEN -EudicAuthorization $env:EUDIC_AUTHORIZATION -EudicBookId $env:EUDIC_BOOK_ID -LocateLiteralDollarOne:($env:MAIMEMO_LOCATE_DOLLAR_ONE -eq 'true'))
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
