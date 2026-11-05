$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\items\disk-usage-lib.ps1"
$count = 0
function Check([bool]$ok, [string]$message) {
    $script:count++
    if (-not $ok) { throw $message }
}
function Reject([string[]]$lines) {
    $failed = $false
    try { Convert-DataDf $lines '/dev/block/dm-3' | Out-Null } catch { $failed = $true }
    Check $failed "Accepted bad df output: $($lines -join ' | ')"
}
$device = Get-DataDevice @('/dev/block/dm-3 /data ext4 rw 0 0', '/dev/block/dm-3 /vendor/lib64/libvulkan_enc.so ext4 rw 0 0')
Check ($device -eq '/dev/block/dm-3') 'identify /data device'
foreach ($mounts in @(@('/dev/block/dm-3 /system ext4 rw 0 0'), @('/dev/block/dm-3 /data ext4 rw 0 0','/dev/block/dm-4 /data ext4 rw 0 0'))) {
    $failed = $false
    try { Get-DataDevice $mounts | Out-Null } catch { $failed = $true }
    Check $failed 'missing or ambiguous /data mount must fail'
}
$i = Convert-DataDf @('Filesystem Inodes IUsed IFree IUse% Mounted on', '/dev/block/dm-3 1048576 12345 1036231 2% /vendor/lib64/libvulkan_enc.so') $device
Check ($i.total -eq 1048576 -and $i.used -eq 12345 -and $i.available -eq 1036231) 'inode values'
$s = Convert-DataDf @('Filesystem 1K-blocks Used Available Use% Mounted on', '/dev/block/dm-3 65000000 5000000 60000000 8% /data') $device
Check ($s.total -eq 65000000 -and $s.used -eq 5000000 -and $s.available -eq 60000000) 'space values'
Reject @('header')
Reject @('header', '/dev/block/dm-4 100 20 80 20% /data')
Reject @('header', '/dev/block/dm-3 100 error 80 20% /data')
Reject @('header', '/dev/block/dm-3 100 -1 80 20% /data')
Reject @('header', '/dev/block/dm-3 100 20 80 20% /data', 'extra')
$baseline = [pscustomobject]@{ stage='before-install'; time='2026-01-01T00:00:01Z'; inodes=[pscustomobject]@{total=1048576} }
$testState = [pscustomobject]@{ samples=@($baseline); game=$null }
Assert-InstallState $testState 'abc' 'game.id'
$testState.game = [pscustomobject]@{installed=$false; apkSha256='abc'; packageId='game.id'; lastAttempt='2026-01-01T00:00:02Z'}
foreach ($case in @('stale','other-apk','other-package','installed','wrong-cap','wrong-stage')) {
    $copy = $testState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $copy.samples[-1].time = '2026-01-01T00:00:03Z'
    $sha = 'abc'; $id = 'game.id'
    switch ($case) {
        'stale' { $copy.samples[-1].time = '2026-01-01T00:00:01Z' }
        'other-apk' { $sha = 'different' }
        'other-package' { $id = 'other.id' }
        'installed' { $copy.game.installed = $true }
        'wrong-cap' { $copy.samples[-1].inodes.total = 99 }
        'wrong-stage' { $copy.samples[-1].stage = 'apk-installed' }
    }
    $failed = $false
    try { Assert-InstallState $copy $sha $id } catch { $failed = $true }
    Check $failed "Install accepted $case"
}
$testState.samples[-1].time = '2026-01-01T00:00:03Z'
Assert-InstallState $testState 'abc' 'game.id'
Check $true 'same APK with fresh baseline may be retried'
if ($IsWindows) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("disk-usage-test-" + [guid]::NewGuid())
    try {
        [IO.File]::WriteAllBytes($path, [byte[]]::new(8193))
        $n = Get-AllocatedBytes $path
        Check ($n -gt 8193) 'ordinary file allocation must include cluster rounding'
        & fsutil sparse setflag $path | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not mark test file sparse' }
        $f = [IO.File]::Open($path, 'Open', 'Write', 'ReadWrite')
        try { $f.SetLength(16MB) } finally { $f.Dispose() }
        $sparse = Get-AllocatedBytes $path
        Check ($sparse -lt 16MB) 'sparse allocation must exclude unallocated regions'
        Remove-Item -LiteralPath $path
        $failed = $false
        try { Get-AllocatedBytes $path | Out-Null } catch { $failed = $true }
        Check $failed 'missing file must fail'
    } finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
    $existing = Join-Path ([IO.Path]::GetTempPath()) ("disk-usage-existing-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $existing | Out-Null
    try {
        $marker = Join-Path $existing 'marker.txt'
        Set-Content -LiteralPath $marker 'preserve'
        $result = & pwsh -NoProfile -File "$PSScriptRoot\..\items\created-disk-usage.ps1" -Action Create -Work $existing 2>&1
        Check ($LASTEXITCODE -ne 0 -and (Get-Content -Raw $marker).Trim() -eq 'preserve') 'existing work directory must be untouched'
    } finally { Remove-Item -LiteralPath $marker; Remove-Item -LiteralPath $existing }
}
Write-Host "$count assertions passed"
