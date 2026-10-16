$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'diagnose-maimemo.ps1')

$target = 'np-private-test-target'
$credential = 'private-test-token'
$privateContent = 'PRIVATE-NOTEPAD-CONTENT'
$workflowFile = [IO.Path]::GetTempFileName()
$testCount = 0

function Assert-Diagnostic {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function New-TestResponse {
    param([int]$Status = 200, $Payload)
    return @{ Status = $Status; Body = ($Payload | ConvertTo-Json -Depth 20 -Compress) }
}

function Test-Case {
    param([object[]]$Responses, [string]$ExpectedMatch, [int]$ExpectedRequests,
        [int]$ExpectedExit = 1, [string]$Token = $credential, [string]$ExpectedCode = '',
        [int]$ExpectedScanned = -1, [int]$ExpectedPages = -1, [int[]]$ExpectedOffsets = @())
    $state = @{
        Responses = [Collections.Generic.Queue[object]]::new()
        Calls = [Collections.Generic.List[string]]::new()
        Logs = [Collections.Generic.List[string]]::new()
    }
    foreach ($response in $Responses) { $state.Responses.Enqueue($response) }
    $request = {
        param($url, $tokenValue)
        if ($tokenValue -cne $Token) { throw 'Credential was changed' }
        if ($url -cnotmatch '^https://open\.maimemo\.com/open/api/v1/memo/notepads(?:\?limit=10&offset=\d+|/np-private-test-target)$') { throw 'Unexpected request URL' }
        $state.Calls.Add($url)
        if ($state.Responses.Count -eq 0) { throw 'Unexpected additional request' }
        $response = $state.Responses.Dequeue()
        if ($response -is [Exception]) { throw $response }
        return $response
    }.GetNewClosure()
    $writeLog = { param($line) $state.Logs.Add($line) }.GetNewClosure()
    $result = Invoke-MaiMemoReadOnlyDiagnostic -Token $Token -WorkflowPath $workflowFile -Request $request -WriteLog $writeLog
    Assert-Diagnostic ($result -eq $ExpectedExit) "Unexpected result for $ExpectedMatch (exit=$result; $($state.Logs -join '; '))"
    Assert-Diagnostic ($state.Calls.Count -eq $ExpectedRequests) "Unexpected request count for $ExpectedMatch"
    Assert-Diagnostic ($state.Logs.Count -gt 0 -and $state.Logs[-1] -match " target_match=$ExpectedMatch(?: |$)") "Unexpected match result for $ExpectedMatch"
    if ($ExpectedCode) { Assert-Diagnostic ($state.Logs[-1].Contains("error_code=$ExpectedCode ")) 'Unexpected error code' }
    foreach ($line in $state.Logs) {
        Assert-Diagnostic ($line -cmatch '^http_status=\d+ error_code=[a-z0-9_,]+ target_match=[a-z_]+ pages_scanned=\d+ scanned_count=\d+$') 'Unexpected log fields'
        foreach ($secret in @($credential, $target, $privateContent)) {
            Assert-Diagnostic (!$line.Contains($secret)) 'Private information leaked'
        }
    }
    if ($ExpectedScanned -ge 0) {
        Assert-Diagnostic ($state.Logs[-1].EndsWith("scanned_count=$ExpectedScanned")) 'Incorrect scanned count'
    }
    if ($ExpectedPages -ge 0) {
        Assert-Diagnostic ($state.Logs[-1].Contains("pages_scanned=$ExpectedPages ")) 'Incorrect page count'
    }
    if ($ExpectedOffsets.Count -gt 0) {
        $listCalls = @($state.Calls | Where-Object { $_.Contains('?') })
        Assert-Diagnostic ($listCalls.Count -eq $ExpectedOffsets.Count) 'Incorrect list page count'
        for ($index = 0; $index -lt $listCalls.Count; $index++) {
            Assert-Diagnostic ($listCalls[$index].EndsWith("offset=$($ExpectedOffsets[$index])")) 'Pagination did not advance by actual items'
        }
    }
    $script:testCount++
}

try {
    [IO.File]::WriteAllText($workflowFile, "env:`n  MaiMemo__DefaultNotepadId: `"$target`"`n")
    $listed = New-TestResponse -Payload @{ success = $true; data = @{ notepads = @(@{ id = $target; content = $privateContent }) } }
    $detail = New-TestResponse -Payload @{ success = $true; data = @{ notepad = @{ id = $target; content = $privateContent } } }
    $empty = New-TestResponse -Payload @{ success = $true; data = @{ notepads = @() } }
    $badId = New-TestResponse -Status 400 -Payload @{ success = $false; errors = @(@{ code = 'common_invalid_res_id'; message = "$target $credential $privateContent" }) }
    Test-Case @($listed, $detail) 'matched_detail_ok' 2 0 -ExpectedScanned 1 -ExpectedPages 1
    Test-Case @($empty, $badId) 'not_found_detail_failed' 2 -ExpectedScanned 0 -ExpectedPages 1 -ExpectedOffsets @(0)
    $shortPage = New-TestResponse -Payload @{ notepads = @(@{ id = 'np-other' }) }
    Test-Case @($shortPage, $empty, $detail) 'not_found_detail_ok' 3 0 -ExpectedScanned 1 -ExpectedPages 2 -ExpectedOffsets @(0, 1)
    Test-Case @($listed, $badId) 'matched_detail_failed' 2 -ExpectedCode 'common_invalid_res_id'
    Test-Case @($badId) 'unknown' 1 -ExpectedCode 'common_invalid_res_id'
    Test-Case @((New-TestResponse -Status 401 -Payload @{ errors = @(@{ code = 'common_invalid_token' }) })) 'unknown_authorization' 1
    Test-Case @(@{ Status = 403; Body = '<html>private-test-token</html>' }) 'unknown_authorization' 1
    Test-Case @((New-TestResponse -Payload @{ success = $false; errors = @(@{ code = 'common_permission_denied' }) })) 'unknown_authorization' 1
    Test-Case @([InvalidOperationException]::new("$credential $target $privateContent")) 'unknown' 1 -ExpectedCode 'transport_error'
    Test-Case @(@{ Status = 200; Body = '<html>private-test-token</html>' }) 'unknown' 1 -ExpectedCode 'non_json_response'
    Test-Case @((New-TestResponse -Payload @{ data = @{} })) 'unknown' 1 -ExpectedCode 'unexpected_list_response'
    Test-Case @((New-TestResponse -Payload @{ notepads = @(@{ content = $privateContent }) })) 'unknown' 1 -ExpectedCode 'unexpected_list_response'
    Test-Case @($listed, (New-TestResponse -Payload @{ notepad = @{ id = 'np-other' } })) 'matched_detail_unknown' 2
    Test-Case @($listed, [InvalidOperationException]::new($credential)) 'matched_detail_unknown' 2
    Test-Case @() 'unknown' 0 -Token '' -ExpectedCode 'configuration_unavailable'
    $fullPage = New-TestResponse -Payload @{ data = @{ notepads = @(0..9 | ForEach-Object { @{ id = "np-other-$_" } }) } }
    Test-Case @($fullPage, $listed, $detail) 'matched_detail_ok' 3 0 -ExpectedScanned 11 -ExpectedPages 2 -ExpectedOffsets @(0, 10)
    Test-Case @($fullPage, $empty, $badId) 'not_found_detail_failed' 3 -ExpectedScanned 10 -ExpectedPages 2 -ExpectedOffsets @(0, 10)
    Test-Case @($shortPage, $listed, $detail) 'matched_detail_ok' 3 0 -ExpectedScanned 2 -ExpectedPages 2 -ExpectedOffsets @(0, 1)
    Test-Case @(1..10 | ForEach-Object { $fullPage }) 'unknown_not_exhausted' 10 -ExpectedCode 'page_limit_reached' -ExpectedScanned 100 -ExpectedPages 10
    Test-Case (@(1..9 | ForEach-Object { $fullPage }) + @($empty, $badId)) 'not_found_detail_failed' 11 -ExpectedScanned 90 -ExpectedPages 10
    Test-Case @((New-TestResponse -Status 400 -Payload @{ errors = @(@{ code = $credential; message = $privateContent }) })) 'unknown' 1 -ExpectedCode 'unavailable'

    # 配置解析必须与现有 sync.yml 一致；拒绝多目标/动态表达式，不猜测 ID。
    $actualId = Get-MaiMemoDiagnosticTargetId (Join-Path $PSScriptRoot '../.github/workflows/sync.yml')
    Assert-Diagnostic ($actualId.StartsWith('np-')) 'Existing static target not recognized'
    foreach ($scalar in @("'$target'", $target)) {
        [IO.File]::WriteAllText($workflowFile, "env:`n  MaiMemo__DefaultNotepadId: $scalar # comment`n")
        Assert-Diagnostic ((Get-MaiMemoDiagnosticTargetId $workflowFile) -ceq $target) 'Static scalar changed'
    }
    [IO.File]::WriteAllText($workflowFile, "  MaiMemo__DefaultNotepadId: '$target'`n  MaiMemo__DefaultNotepadId: '$target'`n")
    Test-Case @() 'unknown' 0 -ExpectedCode 'configuration_unavailable'
    [IO.File]::WriteAllText($workflowFile, '  MaiMemo__DefaultNotepadId: ${{ secrets.TEST }}')
    Test-Case @() 'unknown' 0 -ExpectedCode 'configuration_unavailable'
    $workflow = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../.github/workflows/maimemo-diagnostics.yml'))
    Assert-Diagnostic ($workflow.Contains('workflow_dispatch:') -and !$workflow.Contains('Run Sync') -and !$workflow.Contains('dotnet run')) 'Diagnostic workflow can invoke sync'
    Assert-Diagnostic ($workflow.Contains('${{ secrets.MAIMEMO_TOKEN }}')) 'Existing Secret not used'

    # 本机 TCP 服务核验真正发出的 HTTP，避免 Mock 掩盖参数/认证头格式问题。
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $server = [PowerShell]::Create()
    try {
        $port = $listener.LocalEndpoint.Port
        [void]$server.AddScript({
            param($tcpListener)
            $client = $tcpListener.AcceptTcpClientAsync().WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 10000
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                try {
                    $lines = [Collections.Generic.List[string]]::new()
                    do { $line = $reader.ReadLine(); if ($line) { $lines.Add($line) } } while ($line)
                    $body = '{"success":true,"data":{"notepads":[]}}'
                    $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body")
                    $stream.Write($bytes, 0, $bytes.Length)
                    return $lines -join "`n"
                }
                finally { $reader.Dispose() }
            }
            finally { $client.Dispose() }
        }).AddArgument($listener)
        $pending = $server.BeginInvoke()
        $wireResult = Invoke-MaiMemoDiagnosticGet "http://127.0.0.1:$port/open/api/v1/memo/notepads?limit=10&offset=0" $credential
        $wireRequest = ($server.EndInvoke($pending)) -join ''
        Assert-Diagnostic ($wireResult.Status -eq 200) 'Loopback HTTP request failed'
        Assert-Diagnostic ($wireRequest.StartsWith('GET /open/api/v1/memo/notepads?limit=10&offset=0 HTTP/1.1')) 'Incorrect wire method or integer query encoding'
        Assert-Diagnostic ($wireRequest.Contains("Authorization: Bearer $credential")) 'Incorrect wire authorization scheme'
        Assert-Diagnostic ($wireRequest.Contains('Accept: application/json')) 'Incorrect Accept header'
        Assert-Diagnostic ($wireRequest -notmatch '(?im)^Cookie:|^Content-Length: [1-9]') 'Unexpected cookie or request body'
        $testCount++
    }
    finally { $listener.Stop(); $server.Dispose() }
    Write-Host "Read-only diagnostic tests passed: $testCount cases (mock responses and local loopback only)."
}
finally { [IO.File]::Delete($workflowFile) }
