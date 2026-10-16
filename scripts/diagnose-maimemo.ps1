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
    param([string]$Url, [string]$Token)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(25)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    try {
        $request.Headers.Add('Authorization', "Bearer $Token")
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

if ($MyInvocation.InvocationName -ne '.') {
    try { exit (Invoke-MaiMemoReadOnlyDiagnostic -Token $env:MAIMEMO_TOKEN) }
    catch {
        # 最外层也不打印异常，防止 PowerShell 将 URL、Header 或响应正文带入日志。
        Write-Host 'http_status=0 error_code=diagnostic_error target_match=unknown'
        exit 1
    }
}
