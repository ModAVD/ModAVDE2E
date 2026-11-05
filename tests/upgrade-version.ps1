#requires -Version 7.0
# Copyright 2026 jinghero. SPDX-License-Identifier: AGPL-3.0-or-later
# Run on Windows: pwsh -NoProfile -File tests/upgrade-version.ps1
param([string]$UpgradeScript = (Join-Path $PSScriptRoot '..\items\upgrade.ps1'))
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'These package overlay fixtures require Windows.' }
$item = $UpgradeScript
$scratch = Join-Path ([IO.Path]::GetTempPath()) "modavd-upgrade-104-$([guid]::NewGuid().ToString('N'))"
$savedEnv = @{}
foreach ($key in 'MODAVD_E2E_CONFIG', 'MODAVD_REGRESS_MANAGER', 'MODAVD_REGRESS_PACKAGE', 'TMPDIR') {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key)
}
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
$commands = [Collections.Generic.List[string]]::new()
function Check([bool]$ok, [string]$message) {
    $script:checks++
    if (-not $ok) { $script:failures.Add($message); Write-Host "FAIL $message" }
}
function Put([string]$path, [string]$text) {
    $null = New-Item -ItemType Directory -Force (Split-Path $path)
    Set-Content -LiteralPath $path -Value $text -Encoding utf8
}
function Manifest([string]$package, $version, [string]$raw) {
    if ($raw) { Put (Join-Path $package 'modavd-manifest.json') $raw }
    elseif ($null -ne $version) { Put (Join-Path $package 'modavd-manifest.json') (@{ version = $version } | ConvertTo-Json -Compress) }
}
function MockCommand([string]$path, [scriptblock]$body) {
    Set-Item -LiteralPath "function:global:$path" -Value $body
    $commands.Add($path)
}
try {
    Put (Join-Path $scratch 'local.psd1') '@{}'
    $env:MODAVD_E2E_CONFIG = Join-Path $scratch 'local.psd1'
    $env:MODAVD_REGRESS_MANAGER = ''
    $env:MODAVD_REGRESS_PACKAGE = ''
    $cases = @(
        @{ Name = 'patch, same build'; Old = 'v0.37.0'; New = 'v0.37.1'; Pass = $true; Version = 'v0.37.0 -> v0.37.1' }
        @{ Name = 'minor and build'; Old = 'v0.36.0'; New = 'v0.37.1'; OldId = 'mas-36'; Pass = $true }
        @{ Name = 'same package'; Old = 'v0.37.1'; New = 'v0.37.1'; Pass = $false; Problem = '清单版本没有上升' }
        @{ Name = 'same version, different build'; Old = 'v0.37.1'; New = 'v0.37.1'; OldId = 'mas-36'; Pass = $false; Problem = '清单版本没有上升' }
        @{ Name = 'downgrade, different build'; Old = 'v0.37.1'; New = 'v0.37.0'; OldId = 'mas-36'; Pass = $false; Problem = '清单版本没有上升' }
        @{ Name = 'numeric ordering'; Old = 'v0.37.9'; New = 'v0.37.10'; Pass = $true }
        @{ Name = 'optional v prefix'; Old = '0.37.0'; New = 'v0.37.1'; Pass = $true }
        @{ Name = 'release after prerelease'; Old = 'v0.37.1-rc.1'; New = 'v0.37.1'; Pass = $true }
        @{ Name = 'prerelease ordering'; Old = 'v0.37.1-rc.2'; New = 'v0.37.1-rc.10'; Pass = $true }
        @{ Name = 'metadata is not an upgrade'; Old = 'v0.37.1+old'; New = 'v0.37.1+new'; Pass = $false; Problem = '清单版本没有上升' }
        @{ Name = 'missing old manifest'; New = 'v0.37.1'; OldId = 'mas-36'; Pass = $true; Fallback = $true }
        @{ Name = 'missing old manifest, same build'; New = 'v0.37.1'; Pass = $false; Fallback = $true; Problem = '构建号还是' }
        @{ Name = 'missing new manifest, stale old manifest remains'; Old = 'v0.37.0'; OldId = 'mas-36'; Pass = $true; Fallback = $true }
        @{ Name = 'missing new manifest, same build'; Old = 'v0.37.0'; Pass = $false; Fallback = $true; Problem = '构建号还是' }
        @{ Name = 'both manifests missing'; OldId = 'mas-36'; Pass = $true; Fallback = $true }
        @{ Name = 'both manifests missing, same build'; Pass = $false; Fallback = $true; Problem = '构建号还是' }
        @{ Name = 'SDK with unrelated manifest'; Old = 'v0.37.0'; New = 'v9.0.0'; Sdk = $true; OldId = 'mas-36'; Pass = $true; Fallback = $true }
        @{ Name = 'SDK, same build'; Old = 'v0.37.0'; New = 'v9.0.0'; Sdk = $true; Pass = $false; Fallback = $true; Problem = '构建号还是' }
        @{ Name = 'bad old JSON'; OldRaw = '{'; New = 'v0.37.1'; Pass = $false; Problem = '包清单版本无效' }
        @{ Name = 'bad new JSON must not fall back'; Old = 'v0.37.0'; NewRaw = '{'; OldId = 'mas-36'; Pass = $false; Problem = '包清单版本无效' }
        @{ Name = 'missing version must not fall back'; Old = 'v0.37.0'; NewRaw = '{}'; OldId = 'mas-36'; Pass = $false; Problem = '包清单版本无效' }
        @{ Name = 'empty version'; Old = 'v0.37.0'; New = ''; Pass = $false; Problem = '包清单版本无效' }
        @{ Name = 'non-string version'; Old = 'v0.37.0'; New = 37; Pass = $false; Problem = '包清单版本无效' }
        @{ Name = 'invalid semantic version'; Old = 'v0.37.0'; New = 'newest'; Pass = $false; Problem = '包清单版本无效' }
    )
    for ($i = 0; $i -lt $cases.Count; $i++) {
        $case = $cases[$i]
        $base = Join-Path $scratch "case $i"
        $prev = Join-Path $base 'previous package'
        $next = Join-Path $base 'next package'
        $work = Join-Path $base 'work'
        $official = Join-Path $base 'official sdk'
        $oldId = if ($case.OldId) { $case.OldId } else { 'mas-37' }
        foreach ($pkg in $prev, $next) {
            Put (Join-Path $pkg 'sdk\emulator\emulator.exe') 'fixture'
            Put (Join-Path $pkg 'sdk\emulator\source.properties') "Pkg.BuildId=$(if ($pkg -eq $prev) { $oldId } else { 'mas-37' })"
            Put (Join-Path $pkg 'tools\modavd.exe') 'fixture'
            Put (Join-Path $pkg 'tools\modavd-bridge.ps1') 'fixture'
            Put (Join-Path $pkg 'ModAVD.exe') 'fixture'
        }
        Manifest $prev $case.Old $case.OldRaw
        Manifest $next $case.New $case.NewRaw
        $env:MODAVD_REGRESS_PACKAGE = Join-Path $next 'tools'
        $fixture = @{ Script = ''; Tag = ''; Starts = 0; Stops = 0 }
        foreach ($exe in (Join-Path $work 'cli\modavd.exe'), (Join-Path $work 'root\tools\modavd.exe')) {
            MockCommand $exe {
                $global:LASTEXITCODE = 0
                if ($args[2] -eq '--json') {
                    if ($args[3] -eq 'list') { return '{"ok":true,"data":{"port_base":23000}}' }
                    if ($args[3] -eq 'info') { return '{"ok":true,"data":{"serial":"emulator-23040","ports":{"console":23040,"adb":23041,"grpc":23042}}}' }
                }
                if ($args[2] -eq 'start') { $fixture.Starts++; return '数据盘已扩到 80 GB' }
                if ($args[2] -eq 'stop') { $fixture.Stops++ }
            }
        }
        $null = New-Item -ItemType Directory -Force (Join-Path $official 'system-images')
        Put (Join-Path $official 'platform-tools\adb.exe') 'fixture'
        foreach ($exe in (Join-Path $official 'platform-tools\adb.exe'), (Join-Path $work 'root\sdk\platform-tools\adb.exe')) {
            MockCommand $exe {
                $global:LASTEXITCODE = 0
                if ($args -contains 'push') {
                    $fixture.Script = Get-Content -LiteralPath $args[5] -Raw
                    if ($fixture.Script -match 'echo (upgrade-\d+) >') { $fixture.Tag = $Matches[1] }
                } elseif ($args -contains 'shell') {
                    if ($fixture.Script -match 'df -k /data') { return '/dev/block/data 83886080 1024 83885056 1% /data' }
                    if ($fixture.Script -match 'getprop ro.dalvik') { return 'libmodavd_bridge.so' }
                    if ($fixture.Script -match '^cat /data/local/tmp/upgrade-marker') { return @($fixture.Tag, $fixture.Tag, 'sdwait=0') }
                    return 'sdwait=0'
                }
            }
        }
        function global:Get-CimInstance { @() }
        $nextArg = if ($case.Sdk) { Join-Path $next 'sdk' } else { $next }
        if ($case.Sdk -and $case.New) { Manifest $nextArg $case.New '' }
        $output = @(& $item -Prev $prev -Next $nextArg -ModavdOut $next -Work $work -Official $official -Keep)
        $rows = @($output | Where-Object { $_ -like 'REGRESS-RESULT *' })
        Check ($rows.Count -eq 1) "$($case.Name): one result"
        $result = $rows[-1].Substring('REGRESS-RESULT '.Length) | ConvertFrom-Json
        Check ($result.pass -eq $case.Pass) "$($case.Name): pass=$($result.pass), summary=$($result.summary)"
        if ($case.Problem) { Check ($result.summary.Contains($case.Problem)) "$($case.Name): expected problem, $($result.summary)" }
        if ($case.Fallback) {
            Check ($result.summary.Contains('按构建号判定')) "$($case.Name): fallback recorded"
            Check (-not $result.summary.Contains('清单版本 ')) "$($case.Name): stale manifest ignored"
        }
        if ($case.Version) { Check ($result.summary.Contains("清单版本 $($case.Version)")) "$($case.Name): manifest versions recorded" }
        if (-not ($case.Problem -eq '包清单版本无效')) {
            Check ($result.summary.Contains("构建号 $oldId -> mas-37")) "$($case.Name): build IDs recorded"
            Check ($fixture.Starts -eq 4 -and $fixture.Stops -eq 4) "$($case.Name): full upgrade and final stop exercised"
        }
    }
} finally {
    foreach ($path in $commands) { Remove-Item -LiteralPath "function:global:$path" -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath function:global:Get-CimInstance -ErrorAction SilentlyContinue
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key]) }
    # Unlink only our junctions before deleting the isolated fixture tree.
    $full = [IO.Path]::GetFullPath($scratch)
    if ((Split-Path $full) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path $full -Leaf) -notlike 'modavd-upgrade-104-*') { throw 'Unexpected fixture cleanup path' }
    if (Test-Path -LiteralPath $full) {
        Get-ChildItem -LiteralPath $full -Recurse -Force -Attributes ReparsePoint | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
Write-Host "$($cases.Count) scenarios, $checks assertions, $($failures.Count) failures"
if ($failures.Count) { exit 1 }
