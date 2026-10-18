# Run locally after the official CLI's interactive login. Never print credentials.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$credentialPath = Join-Path $HOME '.config/memo-api.json'
$process = $null
try {
    $config = [IO.File]::ReadAllText($credentialPath) | ConvertFrom-Json
    if ($config.rt.token -isnot [string] -or
        [string]::IsNullOrWhiteSpace($config.rt.token) -or
        $config.rt.token -match '\s' -or
        [double]::IsNaN([double]$config.rt.expireAt) -or
        [double]::IsInfinity([double]$config.rt.expireAt) -or
        [double]$config.rt.expireAt -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60) {
        throw 'invalid'
    }
    # Do not import the fixed apiToken, access token, or unrelated account data.
    $credentials = @{ rt = @{ token = [string]$config.rt.token; expireAt = [double]$config.rt.expireAt } } | ConvertTo-Json -Compress
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = 'gh'
    $start.Arguments = 'secret set MAIMEMO_OIDC_CREDENTIALS --repo ShalliChan/EudicSyncToMaiMemo'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.WriteLine($credentials)
    $process.StandardInput.Close()
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw 'upload_failed' }
    Write-Output 'oauth_credentials_uploaded=1 fixed_token_unchanged=1'
} catch {
    # Exception messages and gh output can contain sensitive data; never relay them.
    Write-Error 'OAuth import failed. Confirm official CLI login and gh auth login, then retry the import.' -ErrorAction Continue
    exit 1
} finally {
    $credentials = $null
    $config = $null
    if ($process) { $process.Dispose() }
}
