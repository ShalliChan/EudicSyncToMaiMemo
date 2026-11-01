# Run locally after the official CLI's interactive login. Never print credentials.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
function Resolve-ImportRepository {
    param([string]$Origin)
    if ($Origin -cmatch '^(?:https://github\.com/|git@github\.com:)(?<owner>[A-Za-z0-9][A-Za-z0-9-]*)/(?<repo>[A-Za-z0-9_.-]+?)(?:\.git)?/?$') {
        return "$($Matches.owner)/$($Matches.repo)"
    }
    throw 'unsupported_origin'
}
function Assert-ImportRepositoryConfirmation {
    param([string]$Repository, [string]$CanonicalRepository, [string]$Confirmation)
    if (!$Repository.Equals($CanonicalRepository, [StringComparison]::OrdinalIgnoreCase) -or
        !$Repository.Equals($Confirmation, [StringComparison]::Ordinal)) { throw 'repository_not_confirmed' }
}
if ($MyInvocation.InvocationName -eq '.') { return }
$credentialPath = Join-Path $HOME '.config/memo-api.json'
$process = $null
try {
    # Resolve origin from this script's checkout, not gh's potentially upstream default.
    $origin = & git -C $PSScriptRoot remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'origin_missing' }
    $repository = Resolve-ImportRepository ($origin -join '')
    $repoResponse = & gh api "repos/$repository" --jq '{name: .full_name, push: .permissions.push}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'repository_unavailable' }
    $repoInfo = ($repoResponse -join '') | ConvertFrom-Json
    if ($repoInfo.push -ne $true) { throw 'repository_not_writable' }
    Write-Host "Target repository: $repository"
    $confirmation = Read-Host 'Type the exact owner/repository above to upload credentials (Enter cancels)'
    Assert-ImportRepositoryConfirmation $repository $repoInfo.name $confirmation
    # No credential file is read until the target is verified and explicitly confirmed.
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
    $start.Arguments = "secret set MAIMEMO_OIDC_CREDENTIALS --repo $repository"
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
    Write-Error 'OAuth import stopped. Check origin, repository write access, exact confirmation, and local CLI authorization. No fallback repository is used.' -ErrorAction Continue
    exit 1
} finally {
    $credentials = $null
    $config = $null
    if ($process) { $process.Dispose() }
}
