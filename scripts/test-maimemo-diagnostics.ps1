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
        [int]$ExpectedExit = 1, [string]$Token = $credential, [string]$ExpectedCode = '')
    $state = @{
        Responses = [Collections.Generic.Queue[object]]::new()
        Calls = [Collections.Generic.List[string]]::new()
        Logs = [Collections.Generic.List[string]]::new()
    }
    foreach ($response in $Responses) { $state.Responses.Enqueue($response) }
    $request = {
        param($url, $tokenValue)
        if ($tokenValue -cne $Token) { throw 'Credential was changed' }
        if ($url -cnotmatch '^https://open\.maimemo\.com/open/api/v1/memo/notepads(?:\?limit=100&offset=\d+|/np-private-test-target)$') { throw 'Unexpected request URL' }
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
    Assert-Diagnostic ($state.Logs.Count -gt 0 -and $state.Logs[-1].EndsWith("target_match=$ExpectedMatch")) "Unexpected match result for $ExpectedMatch"
    if ($ExpectedCode) { Assert-Diagnostic ($state.Logs[-1].Contains("error_code=$ExpectedCode ")) 'Unexpected error code' }
    foreach ($line in $state.Logs) {
        Assert-Diagnostic ($line -cmatch '^http_status=\d+ error_code=[a-z0-9_,]+ target_match=[a-z_]+$') 'Unexpected log fields'
        foreach ($secret in @($credential, $target, $privateContent)) {
            Assert-Diagnostic (!$line.Contains($secret)) 'Private information leaked'
        }
    }
    for ($index = 0; $index -lt $state.Calls.Count; $index++) {
        if ($state.Calls[$index].Contains('?')) {
            Assert-Diagnostic ($state.Calls[$index].EndsWith("offset=$($index * 100)")) 'Pagination did not advance'
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
    Test-Case @($listed, $detail) 'matched_detail_ok' 2 0
    Test-Case @($empty) 'not_found_for_current_token' 1
    Test-Case @((New-TestResponse -Payload @{ notepads = @(@{ id = 'np-other' }) })) 'not_found_for_current_token' 1
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
    $fullPage = New-TestResponse -Payload @{ data = @{ notepads = @(0..99 | ForEach-Object { @{ id = "np-other-$_" } }) } }
    Test-Case @($fullPage, $listed, $detail) 'matched_detail_ok' 3 0
    Test-Case @($fullPage, $empty) 'not_found_for_current_token' 2
    Test-Case @(1..10 | ForEach-Object { $fullPage }) 'unknown_not_exhausted' 10 -ExpectedCode 'page_limit_reached'
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
    Write-Host "Read-only diagnostic tests passed: $testCount cases (no network requests)."
}
finally { [IO.File]::Delete($workflowFile) }
