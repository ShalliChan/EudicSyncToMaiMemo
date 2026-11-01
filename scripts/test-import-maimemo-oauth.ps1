$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'import-maimemo-oauth.ps1')
$count = 0
foreach ($origin in @('https://github.com/example/my-fork.git', 'git@github.com:example/my-fork.git', 'https://github.com/example/my-fork')) {
    if ((Resolve-ImportRepository $origin) -cne 'example/my-fork') { throw 'Wrong repository' }
    $count++
}
foreach ($origin in @('', 'https://evil.example/example/my-fork', 'https://token@github.com/example/my-fork', 'example/my-fork --repo other/repo')) {
    $rejected = $false
    try { $null = Resolve-ImportRepository $origin } catch { $rejected = $true }
    if (!$rejected) { throw 'Unsafe origin accepted' }
    $count++
}
foreach ($pair in @(@('other/repo','example/my-fork'), @('example/my-fork','other/repo'), @('example/my-fork',''))) {
    $rejected = $false
    try { Assert-ImportRepositoryConfirmation 'example/my-fork' $pair[0] $pair[1] } catch { $rejected = $true }
    if (!$rejected) { throw 'Wrong repository or confirmation accepted' }
    $count++
}
Assert-ImportRepositoryConfirmation 'example/my-fork' 'example/my-fork' 'example/my-fork'
$count++
Write-Host "Credential import tests passed: $count (pure validation; no credential reads or uploads)."
