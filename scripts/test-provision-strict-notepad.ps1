$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'provision-strict-notepad.ps1')
$tokenValue = 'private-test-token'
$newId = 'np-private-created-id'
$caseCount = 0

function global:Assert-Provision { param([bool]$Condition, [string]$Message) if (!$Condition) { throw $Message } }
function Response { param($Payload, [int]$Status = 200) @{ Status = $Status; Body = ($Payload | ConvertTo-Json -Depth 20 -Compress) } }
$empty = Response @{ data = @{ notepads = @() } }
$listed = Response @{ data = @{ notepads = @(@{ id = $newId; title = '欧路词典同步（严格）' }) } }
$created = Response @{ data = @{ notepad = @{ id = $newId } } }
$detail = Response @{ data = @{ notepad = @{ id = $newId; title = '欧路词典同步（严格）'; brief = '欧路词典自动同步专用'; status = 'UNPUBLISHED'; content = '# 欧路词典同步' } } }

function Test-Provision {
    param([object[]]$Responses, [int]$Posts, [bool]$Success = $true, [string]$Credential = $tokenValue, [string]$ExpectedCode = '')
    $manifestPath = [IO.Path]::GetTempFileName()
    [IO.File]::Delete($manifestPath)
    $state = @{ Queue = [Collections.Generic.Queue[object]]::new(); Calls = [Collections.Generic.List[object]]::new(); Logs = [Collections.Generic.List[string]]::new() }
    foreach ($response in $Responses) { $state.Queue.Enqueue($response) }
    $request = {
        param($method, $url, $token, $body)
        try {
        Assert-Provision ($token -ceq $Credential) 'Credential changed'
        Assert-Provision ($method -cin @('GET', 'POST')) 'Unsupported HTTP method'
        if ($method -ceq 'POST') {
            Assert-Provision ($url -ceq 'https://open.maimemo.com/open/api/v1/memo/notepads') 'POST can target existing resource'
            $payload = ConvertFrom-Json $body
            Assert-Provision (@($payload.PSObject.Properties).Count -eq 1) 'Unexpected top-level create field'
            Assert-Provision ((@($payload.notepad.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'brief,content,status,tags,title') 'Create fields do not match official schema'
            Assert-Provision ($payload.notepad.status -ceq 'UNPUBLISHED' -and $payload.notepad.content -ceq '# 欧路词典同步') 'Unexpected initialization'
            Assert-Provision ($payload.notepad.title -ceq '欧路词典同步（严格）' -and $payload.notepad.brief -ceq '欧路词典自动同步专用') 'Unexpected metadata'
            Assert-Provision ($payload.notepad.tags.Count -eq 0) 'Unexpected tags'
        }
        else { Assert-Provision ([string]::IsNullOrEmpty($body)) 'GET has request body' }
        $state.Calls.Add(@{ Method = $method; Url = $url })
        if ($state.Queue.Count -eq 0) { throw 'unexpected_repeat' }
        $response = $state.Queue.Dequeue()
        if ($response -is [Exception]) { throw $response }
        return $response
        }
        catch { $state.MockFailure = $_.FullyQualifiedErrorId; throw }
    }.GetNewClosure()
    $log = { param($line) $state.Logs.Add($line) }.GetNewClosure()
    try {
        $failed = $false
        try { $null = Invoke-StrictNotepadProvision -Token $Credential -ManifestPath $manifestPath -Request $request -WriteLog $log }
        catch { $failed = $true; Assert-Provision ($_.Exception.Message -ceq 'strict_provision_failed') 'Raw exception escaped' }
        Assert-Provision ($failed -ne $Success) "Unexpected provisioning outcome: $($state.Logs -join '; '); mock=$($state.MockFailure)"
        Assert-Provision ($state.Calls.Count -eq $Responses.Count) 'Unexpected request count or retry'
        Assert-Provision (@($state.Calls | Where-Object Method -CEQ 'POST').Count -eq $Posts) 'Unexpected creation count'
        foreach ($line in $state.Logs) {
            foreach ($private in @($tokenValue, $newId, 'PRIVATE-CONTENT', 'Authorization', 'Cookie')) { Assert-Provision (!$line.Contains($private)) 'Sensitive provision log' }
        }
        if ($ExpectedCode) { Assert-Provision ([bool]@($state.Logs | Where-Object { $_.Contains("error_code=$ExpectedCode") }).Count) 'Missing safe API error code' }
        if ($Success) {
            $manifest = ConvertFrom-Json ([IO.File]::ReadAllText($manifestPath))
            Assert-Provision ($manifest.id -ceq $newId -and $manifest.detail_verified -and !$manifest.preview_verified) 'Unverified or missing identity'
            Assert-Provision (!([IO.File]::ReadAllText($manifestPath)).Contains($tokenValue)) 'Manifest contains credential'
        }
        elseif (Test-Path -LiteralPath $manifestPath) {
            $manifest = ConvertFrom-Json ([IO.File]::ReadAllText($manifestPath))
            Assert-Provision (!$manifest.detail_verified -and !$manifest.preview_verified) 'Failure produced verified identity'
        }
        $listCalls = @($state.Calls | Where-Object { $_.Url.Contains('?') })
        if ($listCalls.Count -gt 1) { Assert-Provision ($listCalls[1].Url.EndsWith('offset=1') -or $listCalls[1].Url.EndsWith('offset=2')) 'Incorrect pagination' }
        $script:caseCount++
    }
    finally { if (Test-Path -LiteralPath $manifestPath) { [IO.File]::Delete($manifestPath) } }
}

Test-Provision @($empty, $created, $detail) 1
Test-Provision @($listed, $empty, $detail) 0
$duplicate = Response @{ data = @{ notepads = @(@{ id = $newId; title = '欧路词典同步（严格）' }, @{ id = 'np-other'; title = '欧路词典同步（严格）' }) } }
Test-Provision @($duplicate, $empty) 0 $false
Test-Provision @((Response @{ errors = @(@{ code = 'common_invalid_token'; message = $tokenValue }) } 401)) 0 $false -ExpectedCode 'common_invalid_token'
Test-Provision @((Response @{ data = @{} })) 0 $false
Test-Provision @(@{ Status = 200; Body = "PRIVATE-CONTENT $tokenValue" }) 0 $false
Test-Provision @($empty, (Response @{ errors = @(@{ code = 'common_invalid_param' }) } 400)) 1 $false -ExpectedCode 'common_invalid_param'
Test-Provision @($empty, [InvalidOperationException]::new($tokenValue)) 1 $false
Test-Provision @($empty, @{ Status = 200; Body = $tokenValue }) 1 $false
Test-Provision @($empty, (Response @{ data = @{ notepad = @{ id = 'invalid' } } })) 1 $false
Test-Provision @($empty, $created, (Response @{ errors = @(@{ code = 'common_permission_denied' }) } 403)) 1 $false
$wrongContent = Response @{ data = @{ notepad = @{ id = $newId; title = '欧路词典同步（严格）'; brief = '欧路词典自动同步专用'; status = 'UNPUBLISHED'; content = "# 欧路词典同步`napple PRIVATE-CONTENT" } } }
Test-Provision @($listed, $empty, $wrongContent) 0 $false
$wrongStatus = Response @{ data = @{ notepad = @{ id = $newId; title = '欧路词典同步（严格）'; brief = '欧路词典自动同步专用'; status = 'PUBLISHED'; content = '# 欧路词典同步' } } }
Test-Provision @($listed, $empty, $wrongStatus) 0 $false
Test-Provision @((Response @{ success = $false; errors = @(@{ code = $tokenValue }) })) 0 $false -ExpectedCode 'unavailable'
Test-Provision @() 0 $false -Credential ''
Test-Provision @(1..100 | ForEach-Object { Response @{ data = @{ notepads = @(@{ id = 'np-other'; title = 'other' }) } } }) 0 $false

foreach ($outcome in @('success', 'rejected', 'transport', 'extra')) {
    $manifestPath = [IO.Path]::GetTempFileName()
    $auditState = @{ Path = ''; Logs = [Collections.Generic.List[string]]::new() }
    try {
        $getTarget = ${function:Get-MaiMemoDiagnosticTargetId}
        [IO.File]::WriteAllText($manifestPath, (@{ id = $newId; detail_verified = $true; preview_verified = $false } | ConvertTo-Json))
        $audit = {
            param($token, $auth, $book, $path, $log)
            Assert-Provision ($token -ceq $tokenValue) 'Preview credential changed'
            $auditState.Path = $path
            Assert-Provision ((& $getTarget $path) -ceq $newId) 'Preview targets wrong ID'
            if ($outcome -eq 'transport') { throw $tokenValue }
            foreach ($metric in @('ready=1', 'prepared_set_equal=1', 'extra=0', 'target_duplicates=0', 'invalid_lines=0')) {
                $parts = $metric.Split('=')
                if ($outcome -eq 'rejected' -and $parts[0] -eq 'ready') { $parts[1] = '0' }
                if ($outcome -eq 'extra' -and $parts[0] -eq 'extra') { $parts[1] = '1' }
                & $log "source=strict_preview anomaly=$($parts[0]) codepoints=none count=$($parts[1])"
            }
            return 0
        }.GetNewClosure()
        $log = { param($line) $auditState.Logs.Add($line) }.GetNewClosure()
        $failed = $false
        try { Invoke-StrictManifestPreview -ManifestPath $manifestPath -Token $tokenValue -Audit $audit -WriteLog $log }
        catch { $failed = $true; Assert-Provision ($_.Exception.Message -ceq 'strict_preview_failed') 'Preview leaked raw exception' }
        $manifest = ConvertFrom-Json ([IO.File]::ReadAllText($manifestPath))
        Assert-Provision ($manifest.preview_verified -eq ($outcome -eq 'success') -and $failed -eq ($outcome -ne 'success')) 'Incorrect preview verification state'
        Assert-Provision (!(Test-Path -LiteralPath $auditState.Path)) 'Temporary preview config left behind'
        Assert-Provision (!(($auditState.Logs -join '').Contains($tokenValue))) 'Preview credential leak'
        $caseCount++
    }
    finally { [IO.File]::Delete($manifestPath) }
}
Write-Host "Strict notebook provisioning tests passed: $caseCount cases (mock requests only; no real API writes)."
