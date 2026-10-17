$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'diagnose-maimemo.ps1')

function Invoke-StrictProvisionRequest {
    param([ValidateSet('GET', 'POST')][string]$Method, [string]$Url, [string]$Token, [string]$Body)
    $base = 'https://open.maimemo.com/open/api/v1/memo/notepads'
    if (!$Url.StartsWith($base, [StringComparison]::Ordinal) -or ($Method -eq 'POST' -and $Url -cne $base)) { throw 'endpoint_rejected' }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false; $handler.UseCookies = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(25)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Url)
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
        $request.Headers.Accept.ParseAdd('application/json')
        if ($Method -eq 'POST') { $request.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/json') }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try { return @{ Status = [int]$response.StatusCode; Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } }
        finally { $response.Dispose() }
    }
    finally { $request.Dispose(); $client.Dispose() }
}

function Invoke-StrictNotepadProvision {
    param([string]$Token, [string]$ManifestPath,
        [scriptblock]$Request = { param($method, $url, $tokenValue, $body) Invoke-StrictProvisionRequest $method $url $tokenValue $body },
        [scriptblock]$WriteLog = { param($line) Write-Host $line })
    $base = 'https://open.maimemo.com/open/api/v1/memo/notepads'
    $title = '欧路词典同步（严格）'
    $brief = '欧路词典自动同步专用'
    $header = '# 欧路词典同步'
    $state = @{ phase = 'configuration'; creation = 'not_attempted' }
    $call = {
        param($method, $url, $body)
        try { $response = & $Request $method $url $Token $body }
        catch { throw 'transport_error' }
        $payload = $null
        try { $payload = ConvertFrom-Json -InputObject $response.Body -Depth 64 } catch { }
        $code = if ($null -eq $payload) { 'unavailable' } else { Get-MaiMemoDiagnosticErrorCode -Payload $payload -Token $Token -TargetId '__no_resource_id__' }
        if ([int]$response.Status -lt 200 -or [int]$response.Status -ge 300) {
            & $WriteLog "phase=$($state.phase) http_status=$([int]$response.Status) error_code=$code"
            throw 'http_error'
        }
        if ($null -eq $payload) { throw 'invalid_json' }
        if ($payload.success -eq $false -or @($payload.errors | Where-Object { $null -ne $_ }).Count -gt 0) {
            & $WriteLog "phase=$($state.phase) http_status=$([int]$response.Status) error_code=$code"
            throw 'api_error'
        }
        & $WriteLog "phase=$($state.phase) http_status=$([int]$response.Status) error_code=none"
        return $payload
    }
    try {
        if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($ManifestPath)) { throw 'configuration_missing' }
        $matches = [Collections.Generic.List[string]]::new()
        $offset = 0; $complete = $false
        $state.phase = 'list'
        for ($page = 0; $page -lt 100; $page++) {
            $payload = & $call 'GET' "$base`?limit=10&offset=$offset" ''
            if ($payload.data.notepads -isnot [array]) { throw 'unexpected_list' }
            if ($payload.data.notepads.Count -eq 0) { $complete = $true; break }
            foreach ($item in $payload.data.notepads) {
                if ($item.id -isnot [string] -or $item.title -isnot [string]) { throw 'unexpected_list_item' }
                if ($item.title -ceq $title) { $matches.Add($item.id) }
            }
            $offset += $payload.data.notepads.Count
        }
        if (!$complete) { throw 'list_not_exhausted' }
        if ($matches.Count -gt 1) { throw 'duplicate_named_notebooks' }
        if ($matches.Count -eq 1) {
            $id = $matches[0]; $state.creation = 'reused'
        }
        else {
            $state.phase = 'create'; $state.creation = 'attempted'
            # 官方创建结构：只有 notepad 及五个必填字段；不发送 id/type/creator 等字段。
            $body = @{ notepad = @{ status = 'UNPUBLISHED'; title = $title; brief = $brief; content = $header; tags = @() } } | ConvertTo-Json -Depth 10 -Compress
            $payload = & $call 'POST' $base $body
            $id = $payload.data.notepad.id
            $state.creation = 'created'
        }
        if ($id -isnot [string] -or $id -cnotmatch '^np-[A-Za-z0-9_-]+$') { throw 'invalid_created_id' }
        $manifest = [ordered]@{ id = $id; title = $title; status = 'UNPUBLISHED'; creation = $state.creation; detail_verified = $false; preview_verified = $false }
        [IO.File]::WriteAllText($ManifestPath, ($manifest | ConvertTo-Json -Compress))
        $state.phase = 'verify_detail'
        $payload = & $call 'GET' "$base/$([Uri]::EscapeDataString($id))" ''
        $notepad = $payload.data.notepad
        if ($notepad.id -cne $id -or $notepad.title -cne $title -or $notepad.status -cne 'UNPUBLISHED' -or
            $notepad.brief -cne $brief -or $notepad.content -isnot [string] -or $notepad.content.Trim() -cne $header) { throw 'notebook_fields_mismatch' }
        # 仅输出身份验证状态；完整 ID 放入受控 artifact，不把 API 正文或凭证写入日志。
        $manifest.detail_verified = $true
        [IO.File]::WriteAllText($ManifestPath, ($manifest | ConvertTo-Json -Compress))
        & $WriteLog "creation=$($state.creation) detail_verified=true words_written=none"
        return $manifest
    }
    catch {
        # 只允许输出本文件定义的固定原因；底层异常可能包含 URL 或响应正文。
        $reason = $_.Exception.Message
        if ($reason -cnotmatch '^(configuration_missing|transport_error|http_error|invalid_json|api_error|unexpected_list|unexpected_list_item|list_not_exhausted|duplicate_named_notebooks|invalid_created_id|notebook_fields_mismatch)$') { $reason = 'unexpected_error' }
        & $WriteLog "phase=$($state.phase) creation=$($state.creation) failure=$reason no_retry=true"
        throw 'strict_provision_failed'
    }
}

function Invoke-StrictManifestPreview {
    param([string]$ManifestPath, [string]$Token, [string]$EudicAuthorization, [string]$EudicBookId,
        [scriptblock]$Audit = { param($tokenValue, $auth, $bookId, $path, $log) Invoke-MaiMemoContentAudit -Token $tokenValue -EudicAuthorization $auth -EudicBookId $bookId -WorkflowPath $path -StrictPreview -WriteLog $log },
        [scriptblock]$WriteLog = { param($line) Write-Host $line })
    $temporary = [IO.Path]::GetTempFileName()
    try {
        $manifest = ConvertFrom-Json ([IO.File]::ReadAllText($ManifestPath))
        if (!$manifest.detail_verified -or $manifest.id -cnotmatch '^np-[A-Za-z0-9_-]+$') { throw 'invalid_manifest' }
        $manifest.preview_verified = $false
        [IO.File]::WriteAllText($ManifestPath, ($manifest | ConvertTo-Json -Compress))
        [IO.File]::WriteAllText($temporary, "env:`n  MaiMemo__DefaultNotepadId: '$($manifest.id)'`n")
        $logs = [Collections.Generic.List[string]]::new()
        $log = { param($line) $logs.Add($line); & $WriteLog $line }.GetNewClosure()
        $result = & $Audit $Token $EudicAuthorization $EudicBookId $temporary $log
        foreach ($metric in @('ready=1', 'prepared_set_equal=1', 'extra=0', 'target_duplicates=0', 'invalid_lines=0')) {
            $parts = $metric.Split('=')
            if ($result -ne 0 -or !$logs.Contains("source=strict_preview anomaly=$($parts[0]) codepoints=none count=$($parts[1])")) { throw 'preview_rejected' }
        }
        $manifest.preview_verified = $true
        [IO.File]::WriteAllText($ManifestPath, ($manifest | ConvertTo-Json -Compress))
        & $WriteLog 'strict_preview_verified=true sync_words_not_run=true'
    }
    catch { & $WriteLog 'strict_preview_verified=false no_retry=true'; throw 'strict_preview_failed' }
    finally { [IO.File]::Delete($temporary) }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { $null = Invoke-StrictNotepadProvision -Token $env:MAIMEMO_TOKEN -ManifestPath $env:STRICT_NOTEBOOK_MANIFEST }
    catch { exit 1 }
}
