#requires -Version 7.0
# Copyright 2026 jinghero. SPDX-License-Identifier: AGPL-3.0-or-later
# Run on Windows: pwsh -NoProfile -File tests/qemu-ownership.ps1
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'These process/path fixtures require Windows.' }
$runner = Join-Path $PSScriptRoot '..\regress.ps1'
$scratch = Join-Path ([IO.Path]::GetTempPath()) "modavd-qemu-49-$([guid]::NewGuid().ToString('N'))"
$savedEnv = @{}
foreach ($key in 'MODAVD_E2E_CONFIG', 'MODAVD_REGRESS_MANAGER', 'MODAVD_REGRESS_PACKAGE', 'ANDROID_AVD_HOME', 'LOCALAPPDATA', 'ANDROID_EMULATOR_HOME', 'ANDROID_PREFS_ROOT') {
    $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key)
}
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
function Check([bool]$ok, [string]$message) {
    $script:checks++
    if (-not $ok) { $script:failures.Add($message); Write-Host "FAIL $message" }
}
function Qemu([int]$processId, [string]$image, [AllowNull()][string]$command) {
    [pscustomobject]@{ ProcessId = $processId; ExecutablePath = $image; CommandLine = $command; CreationDate = [datetime]::UtcNow.AddMinutes(-2) }
}
function Quote-Argument([string]$value) {
    '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}
try {
    $sdk = Join-Path $scratch 'root A\sdk'
    $baseline = Join-Path $scratch 'baseline sdk'
    $other = Join-Path $scratch 'root A-other'
    $testRoot = Join-Path $scratch 'test root'
    $avdHome = Join-Path $scratch 'game avds'
    $manager = Join-Path $scratch 'manager'
    $package = Join-Path $scratch 'package'
    $alias = Join-Path $scratch 'avd-home-alias'
    $null = New-Item -ItemType Directory -Force "$avdHome\mas_6.avd"
    $null = New-Item -ItemType Junction -Path $alias -Target $avdHome
    foreach ($file in @("$sdk\emulator\emulator.exe", "$baseline\emulator\emulator.exe", "$manager\tools\modavd.exe", "$manager\ModAVD.exe", "$package\modavd-bridge.ps1")) {
        $null = New-Item -ItemType Directory -Force (Split-Path $file)
        Set-Content -LiteralPath $file -Value 'fixture'
    }
    Set-Content -LiteralPath "$sdk\emulator\source.properties" -Value 'Pkg.BuildId=mas-fixture'
    $config = Join-Path $scratch 'local.psd1'
    $escape = { param($s) $s.Replace("'", "''") }
    Set-Content -LiteralPath $config -Value "@{ TestRoot = '$(& $escape $testRoot)'; GameAvdHome = '$(& $escape $avdHome)' }"
    $env:MODAVD_E2E_CONFIG = $config
    $env:ANDROID_AVD_HOME = $avdHome
    $suite = Join-Path $scratch 'suite.psd1'
    $suiteTemplate = @'
@{
    Avds = @('mas_6')
    Items = @(@{ Id = 'fixture'; Title = 'Fixture'; Criterion = 'Result'; Script = '{Repo}\fixture.ps1'; Args = @(__ARGS__) })
}
'@

    # All OS/process calls are doubles. No emulator, game, adb, or item is started.
    $fixture = @{ Processes = @(); QueryFails = $false; Pass = $true; Queries = 0 }
    function Get-CimInstance($ClassName, $Filter) {
        if ($ClassName -eq 'Win32_Process') {
            $fixture.Queries++
            if ($fixture.QueryFails) { throw 'Access denied' }
            return $fixture.Processes
        }
        if ($ClassName -eq 'Win32_OperatingSystem') {
            return [pscustomobject]@{ FreePhysicalMemory = 64GB / 1KB; FreeVirtualMemory = 64GB / 1KB }
        }
        throw "Unexpected CIM class $ClassName"
    }
    function Get-WinEvent($FilterHashtable, $ErrorAction) { }
    function Start-Process($FilePath, $ArgumentList, $RedirectStandardOutput, $RedirectStandardError, $WindowStyle, [switch]$PassThru) {
        ('REGRESS-RESULT ' + (@{ pass = $fixture.Pass; summary = 'fixture' } | ConvertTo-Json -Compress)) | Set-Content -LiteralPath $RedirectStandardOutput
        '' | Set-Content -LiteralPath $RedirectStandardError
        $process = [pscustomobject]@{ Id = 99; ExitCode = 0 }
        $process | Add-Member ScriptMethod WaitForExit { param($timeout) if ($null -ne $timeout) { return $true } }
        return $process
    }
    $image = "$sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe"
    $foreignImage = "$other\sdk\emulator\qemu-system-x86_64.exe"
    $data = 'qemu.exe -avd mas_6 -datadir ' + (Quote-Argument "$avdHome\mas_6.avd")
    $foreignData = 'qemu.exe -avd mas_6 -datadir ' + (Quote-Argument "$other\avd\mas_6.avd")
    $sysdir = 'qemu.exe -avd mas_6 -sysdir ' + (Quote-Argument "$sdk\system-images\android-34")
    $cases = @(
        @{ Name = 'A: other root with the same AVD name'; Processes = @(Qemu 101 $foreignImage 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @() }
        @{ Name = 'B: own leftover PID'; Processes = @(Qemu 102 $image 'qemu.exe -avd mas_6'); Runtime = "$avdHome\mas_6.avd"; Left = '102'; Unknown = @() }
        @{ Name = 'C: unreadable command line'; Processes = @(Qemu 103 $image $null); Left = '无'; Unknown = @(103) }
        @{ Name = 'D: root names share a prefix'; Processes = @(Qemu 104 "$sdk-other\emulator\qemu-system-x86_64.exe" 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @() }
        @{ Name = 'Case insensitive shared image'; Processes = @(Qemu 105 $image.ToUpperInvariant() 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @(105) }
        @{ Name = 'SDK argument case and trailing slash'; Processes = @(Qemu 106 $image 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @(106); Sdk = $sdk.ToUpperInvariant() + '\' }
        @{ Name = 'Forward slashes in shared image'; Processes = @(Qemu 107 $image.Replace('\', '/') 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @(107) }
        @{ Name = 'Dot components inside shared emulator directory'; Processes = @(Qemu 108 "$sdk\emulator\.\unused\..\qemu-system-x86_64.exe" 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @(108) }
        @{ Name = 'Dot components escape emulator directory'; Processes = @(Qemu 109 "$sdk\emulator\..\emulator-other\qemu-system-x86_64.exe" 'qemu.exe -avd mas_6'); Left = '无' }
        @{ Name = 'Emulator directory shares prefix'; Processes = @(Qemu 110 "$sdk\emulator-other\qemu-system-x86_64.exe" 'qemu.exe -avd mas_6'); Left = '无' }
        @{ Name = 'Extended-length shared image path'; Processes = @(Qemu 111 ('\\?\' + $image) 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @(111) }
        @{ Name = 'NT shared image path'; Processes = @(Qemu 112 ('\??\' + $image) 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @(112) }
        @{ Name = 'Quoted executable and AVD'; Processes = @(Qemu 113 $image ((Quote-Argument $image) + ' -avd "mas_6"')); Runtime = "$avdHome\mas_6.avd"; Left = '113' }
        @{ Name = 'Different AVD name'; Processes = @(Qemu 114 $image 'qemu.exe -avd mas_60'); Left = '无' }
        @{ Name = 'Same SDK but other AVD directory'; Processes = @(Qemu 115 $image $foreignData); Left = '无' }
        @{ Name = 'Own AVD directory without image access'; Processes = @(Qemu 116 '' $data); Left = '116' }
        @{ Name = 'Own AVD with external emulator'; Processes = @(Qemu 117 $foreignImage $data); Left = '117' }
        @{ Name = 'A data file alone does not identify the AVD home'; Processes = @(Qemu 118 '' ('qemu.exe -avd mas_6 -data ' + (Quote-Argument "$testRoot\avd\mas_6.avd\userdata-qemu.img"))); Left = '无'; Unknown = @(118) }
        @{ Name = 'Own output root'; Processes = @(Qemu 119 '' ('qemu.exe -avd mas_6 -datadir {Out}\upgrade\work\avd\mas_6.avd')); Left = '119'; ExpandOut = $true }
        @{ Name = 'AVD path case and trailing slash'; Processes = @(Qemu 120 '' ('qemu.exe -avd mas_6 -datadir ' + (Quote-Argument ($avdHome.ToUpperInvariant() + '\mas_6.avd\')))); Left = '120' }
        @{ Name = 'AVD directory shares prefix'; Processes = @(Qemu 121 $image ('qemu.exe -avd mas_6 -datadir ' + (Quote-Argument "$avdHome-other\mas_6.avd"))); Left = '无' }
        @{ Name = 'AVD path escapes through dot components'; Processes = @(Qemu 122 $image ('qemu.exe -avd mas_6 -datadir ' + (Quote-Argument "$avdHome\..\foreign\mas_6.avd"))); Left = '无' }
        @{ Name = 'Relative AVD path'; Processes = @(Qemu 123 $image 'qemu.exe -avd mas_6 -datadir relative\mas_6.avd'); Left = '无'; Unknown = @(123) }
        @{ Name = 'Shared sysdir without root evidence'; Processes = @(Qemu 124 '' $sysdir); Left = '无'; Unknown = @(124) }
        @{ Name = 'System images inside a root can still be shared'; Processes = @(Qemu 125 '' ('qemu.exe -avd mas_6 -sysdir ' + (Quote-Argument "$testRoot\sdk\system-images"))); Left = '无'; Unknown = @(125) }
        @{ Name = 'Foreign sysdir shares SDK prefix'; Processes = @(Qemu 126 $foreignImage ('qemu.exe -avd mas_6 -sysdir ' + (Quote-Argument "$sdk-other\system-images"))); Left = '无' }
        @{ Name = 'Foreign data overrides own sysdir'; Processes = @(Qemu 127 $image ($foreignData + ' -sysdir ' + (Quote-Argument "$sdk\system-images"))); Left = '无' }
        @{ Name = 'Both CIM fields inaccessible'; Processes = @(Qemu 128 '' $null); Left = '无'; Unknown = @(128) }
        @{ Name = 'Blank command line'; Processes = @(Qemu 129 $image '   '); Left = '无'; Unknown = @(129) }
        @{ Name = 'Name and parent environment are insufficient'; Processes = @(Qemu 130 '' 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @(130) }
        @{ Name = 'Relative image path'; Processes = @(Qemu 131 'emulator\qemu-system-x86_64.exe' 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @(131) }
        @{ Name = 'Path mentioned in unrelated argument'; Processes = @(Qemu 132 $foreignImage ('qemu.exe -avd mas_6 -note ' + (Quote-Argument $sdk))); Left = '无' }
        @{ Name = 'AVD option mentioned inside another argument'; Processes = @(Qemu 133 $image 'qemu.exe -note "-avd mas_6"'); Left = '无'; Unknown = @(133) }
        @{ Name = 'Missing option value'; Processes = @(Qemu 134 $image 'qemu.exe -avd mas_6 -sysdir'); Left = '无'; Unknown = @(134) }
        @{ Name = 'Multiple AVD options'; Processes = @(Qemu 135 $image 'qemu.exe -avd mas_6 -avd foreign'); Left = '无'; Unknown = @(135) }
        @{ Name = 'Baseline SDK remains covered'; Processes = @(Qemu 136 "$baseline\emulator\qemu-system-x86_64.exe" 'qemu.exe -avd mas_6'); Runtime = "$avdHome\mas_6.avd"; Left = '136'; Baseline = $baseline }
        @{ Name = 'Mixed own, other, and unknown processes'; Processes = @((Qemu 137 $image 'qemu.exe -avd mas_6'), (Qemu 138 $foreignImage 'qemu.exe -avd mas_6'), (Qemu 139 '' $null)); Runtime = "$avdHome\mas_6.avd"; Left = '137'; Unknown = @(139) }
        @{ Name = 'Failed process enumeration'; Processes = @(); Left = '无'; QueryFails = $true }
        @{ Name = 'No QEMU processes'; Processes = @(); Left = '无' }
        @{ Name = 'Failed item verdict remains failed'; Processes = @(); Left = '无'; FailedItem = $true }
        @{ Name = 'UNC AVD home with extended prefix'; Processes = @(Qemu 140 '' 'qemu.exe -avd mas_6 -datadir "\\?\UNC\server\share\root A\avd\mas_6.avd"'); Left = '140'; Root = '\\server\share\root A\' }
        @{ Name = 'UNC AVD home case and separators'; Processes = @(Qemu 141 '' 'qemu.exe -avd mas_6 -datadir "//SERVER/share/ROOT A/avd/mas_6.avd"'); Left = '141'; Root = '\\server\share\root A\' }
        @{ Name = 'UNC root shares prefix'; Processes = @(Qemu 142 $image 'qemu.exe -avd mas_6 -datadir "\\server\share\root A-other\mas_6.avd"'); Left = '无'; Root = '\\server\share\root A\' }
        @{ Name = 'UNC share shares prefix'; Processes = @(Qemu 143 $image 'qemu.exe -avd mas_6 -datadir "\\server\share-other\root A\mas_6.avd"'); Left = '无'; Root = '\\server\share\root A\' }
        @{ Name = 'Item Root argument'; Processes = @(Qemu 144 '' ('qemu.exe -avd mas_6 -datadir ' + (Quote-Argument "$other\avd\mas_6.avd"))); Left = '144'; ItemArgs = @('-Root', $other) }
        @{ Name = 'Item AvdHome argument'; Processes = @(Qemu 145 '' ('qemu.exe -avd mas_6 -datadir ' + (Quote-Argument "$other\mas_6.avd"))); Left = '145'; ItemArgs = @('-AvdHome', $other) }
        @{ Name = 'Shared executable alone cannot identify a root'; Processes = @(Qemu 146 $image 'qemu.exe -avd mas_6'); Left = '无'; Unknown = @(146) }
        @{ Name = 'Shared executable and sysdir cannot identify a root'; Processes = @(Qemu 147 $image $sysdir); Left = '无'; Unknown = @(147) }
        @{ Name = 'Own runtime record with a shared SDK'; Processes = @(Qemu 148 $image $sysdir); Runtime = "$avdHome\mas_6.avd"; Left = '148' }
        @{ Name = 'Foreign runtime record overrides a shared SDK'; Processes = @(Qemu 149 $image $sysdir); Runtime = "$other\avd\mas_6.avd"; Left = '无' }
        @{ Name = 'Own runtime record without executable access'; Processes = @(Qemu 150 '' 'qemu.exe -avd mas_6'); Runtime = "$avdHome\mas_6.avd"; Left = '150' }
        @{ Name = 'Shared baseline SDK alone is insufficient'; Processes = @(Qemu 151 "$baseline\emulator\qemu-system-x86_64.exe" 'qemu.exe -avd mas_6'); Baseline = $baseline; Left = '无'; Unknown = @(151) }
        @{ Name = 'Foreign runtime record overrides own data file'; Processes = @(Qemu 152 $image $data); Runtime = "$other\avd\mas_6.avd"; Left = '无' }
        @{ Name = 'Own runtime record with an external data file'; Processes = @(Qemu 153 $image $foreignData.Replace('-datadir', '-data')); Runtime = "$avdHome\mas_6.avd"; Left = '153' }
        @{ Name = 'Own run lock before runtime record exists'; Processes = @(Qemu 154 $image 'qemu.exe -avd mas_6'); Lock = "$avdHome\mas_6.avd"; Left = '154' }
        @{ Name = 'Foreign run lock with a shared SDK'; Processes = @(Qemu 155 $image 'qemu.exe -avd mas_6'); Lock = "$other\avd\mas_6.avd"; Left = '无'; Unknown = @(155) }
        @{ Name = 'Stale runtime record from a reused PID'; Processes = @(Qemu 156 $image 'qemu.exe -avd mas_6'); Runtime = "$avdHome\mas_6.avd"; StaleRuntime = $true; Left = '无'; Unknown = @(156) }
        @{ Name = 'Stale foreign record does not hide a current own lock'; Processes = @(Qemu 157 $image 'qemu.exe -avd mas_6'); Runtime = "$other\avd\mas_6.avd"; StaleRuntime = $true; Lock = "$avdHome\mas_6.avd"; Left = '157' }
        @{ Name = 'Stale run lock from a reused PID'; Processes = @(Qemu 158 $image 'qemu.exe -avd mas_6'); Lock = "$avdHome\mas_6.avd"; StaleLock = $true; Left = '无'; Unknown = @(158) }
        @{ Name = 'Unknown process start time cannot validate a record'; Processes = @(Qemu 159 $image 'qemu.exe -avd mas_6'); Runtime = "$avdHome\mas_6.avd"; NoCreationDate = $true; Left = '无'; Unknown = @(159) }
        @{ Name = 'Another PID holds the own AVD lock'; Processes = @(Qemu 160 $image 'qemu.exe -avd mas_6'); Lock = "$avdHome\mas_6.avd"; LockPid = 999; Left = '无'; Unknown = @(160) }
        @{ Name = 'Runtime record root shares a prefix'; Processes = @(Qemu 161 $image 'qemu.exe -avd mas_6'); Runtime = "$avdHome-other\mas_6.avd"; Left = '无' }
        @{ Name = 'Overridden Root excludes unused configured root'; Processes = @(Qemu 162 $image ('qemu.exe -avd mas_6 -datadir ' + (Quote-Argument "$testRoot\avd\mas_6.avd"))); ItemArgs = @('-Root', $other); Left = '无' }
        @{ Name = 'Overridden AvdHome excludes unused configured home'; Processes = @(Qemu 163 $image $data); ItemArgs = @('-AvdHome', $other); Left = '无' }
        @{ Name = 'Explicit Work outside default output'; Processes = @(Qemu 164 '' 'qemu.exe -avd mas_6'); Runtime = "$other\work\root\avd\mas_6.avd"; ItemArgs = @('-Work', "$other\work"); Left = '164' }
        @{ Name = 'Unreadable command line stays unknown despite a record'; Processes = @(Qemu 165 $image $null); Runtime = "$avdHome\mas_6.avd"; Left = '无'; Unknown = @(165) }
        @{ Name = 'Own runtime record accepts path normalization'; Processes = @(Qemu 166 $image 'qemu.exe -avd mas_6'); Runtime = ('\\?\' + $avdHome.ToUpperInvariant() + '\.\mas_6.avd\'); Left = '166' }
        @{ Name = 'Own datadir with an external data file'; Processes = @(Qemu 167 $image ($data + ' -data ' + (Quote-Argument "$other\userdata.img"))); Left = '167' }
        @{ Name = 'Fresh run lock readable while QEMU holds it'; Processes = @(Qemu 168 $image 'qemu.exe -avd mas_6'); Lock = "$avdHome\mas_6.avd"; HoldLock = $true; Left = '168' }
        @{ Name = 'AVD home reached through a junction'; Processes = @(Qemu 169 $image 'qemu.exe -avd mas_6'); Runtime = "$avdHome\mas_6.avd"; ItemArgs = @('-AvdHome', $alias); Left = '169' }
        @{ Name = 'Runtime record reached through a junction'; Processes = @(Qemu 170 $image 'qemu.exe -avd mas_6'); Runtime = "$alias\mas_6.avd"; Left = '170' }
        @{ Name = 'Bad process data cannot hide another leftover'; Processes = @((Qemu 171 $image 'qemu.exe -avd mas_6'), (Qemu 172 $image $data)); ThrowCommandLine = $true; Left = '172'; Unknown = @(171) }
        @{ Name = 'Own runtime record with relative data filename'; Processes = @(Qemu 173 $image 'qemu.exe -avd mas_6 -data userdata.img'); Runtime = "$avdHome\mas_6.avd"; Left = '173' }
        @{ Name = 'Run lock inside a custom Work root'; Processes = @(Qemu 174 $image 'qemu.exe -avd mas_6'); Lock = "$other\work\root\avd\mas_6.avd"; ItemArgs = @('-Work', "$other\work"); Left = '174' }
        @{ Name = 'Fresh runtime with a missing avd.dir falls back to lock'; Processes = @(Qemu 175 $image 'qemu.exe -avd mas_6'); RuntimeText = 'avd.name=mas_6'; Lock = "$avdHome\mas_6.avd"; Left = '175' }
        @{ Name = 'Foreign root can borrow a disk image from the own root'; Processes = @(Qemu 176 $image ('qemu.exe -avd mas_6 -data ' + (Quote-Argument "$avdHome\mas_6.avd\userdata-qemu.img"))); Left = '无'; Unknown = @(176) }
        @{ Name = 'Concurrent roots with identical SDK and command line'; Processes = @((Qemu 177 $image $sysdir), (Qemu 178 $image $sysdir), (Qemu 179 $image $null)); RuntimeRecords = @{ 177 = "$avdHome\mas_6.avd"; 178 = "$other\avd\mas_6.avd" }; Left = '177'; Unknown = @(179) }
        @{ Name = 'Forwarded QEMU arguments cannot prove root ownership'; Processes = @(Qemu 180 $image ('qemu.exe -avd mas_6 -qemu -datadir ' + (Quote-Argument "$avdHome\mas_6.avd"))); Left = '无'; Unknown = @(180) }
        @{ Name = 'Runtime discovery without LOCALAPPDATA'; Processes = @(Qemu 181 $image 'qemu.exe -avd mas_6'); Runtime = "$avdHome\mas_6.avd"; NoLocalAppData = $true; Left = '181' }
        @{ Name = 'Runtime discovery using ANDROID_PREFS_ROOT'; Processes = @(Qemu 182 $image 'qemu.exe -avd mas_6'); Runtime = "$avdHome\mas_6.avd"; NoLocalAppData = $true; UsePrefs = $true; Left = '182' }
    )
    foreach ($case in $cases) {
        $fixture.Processes = $case.Processes
        $fixture.QueryFails = [bool]$case.QueryFails
        $fixture.Pass = -not $case.FailedItem
        $rootArgument = if ($case.Root) { $case.Root } else { $testRoot }
        Set-Content -LiteralPath $config -Value "@{ TestRoot = '$(& $escape $rootArgument)'; GameAvdHome = '$(& $escape $avdHome)' }"
        $itemArgs = @($case.ItemArgs | Where-Object { $null -ne $_ } | ForEach-Object { "'$(& $escape $_)'" }) -join ', '
        $suiteTemplate.Replace('__ARGS__', $itemArgs) | Set-Content -LiteralPath $suite
        $out = Join-Path $scratch "out-$checks"
        $env:LOCALAPPDATA = Join-Path $scratch "profile-$checks"
        $discovery = Join-Path $env:LOCALAPPDATA 'Temp\avd\running'
        $env:ANDROID_EMULATOR_HOME = Join-Path $scratch "emu-home-$checks"
        if ($case.NoLocalAppData) {
            $env:LOCALAPPDATA = $null
            $discovery = Join-Path $env:ANDROID_EMULATOR_HOME 'avd\running'
            if ($case.UsePrefs) {
                $env:ANDROID_EMULATOR_HOME = $null
                $env:ANDROID_PREFS_ROOT = Join-Path $scratch "prefs-$checks"
                $null = New-Item -ItemType Directory -Force (Join-Path $env:ANDROID_PREFS_ROOT '.android')
                $discovery = Join-Path $env:ANDROID_PREFS_ROOT '.android\avd\running'
            }
        }
        $createdFiles = @()
        $records = @{}
        if ($case.Runtime -or $case.RuntimeText) { $records[$case.Processes[0].ProcessId] = $(if ($case.RuntimeText) { $case.RuntimeText } else { "avd.dir=$($case.Runtime)" }) }
        if ($case.RuntimeRecords) { foreach ($processId in $case.RuntimeRecords.Keys) { $records[$processId] = "avd.dir=$($case.RuntimeRecords[$processId])" } }
        foreach ($processId in $records.Keys) {
            $null = New-Item -ItemType Directory -Force $discovery
            $record = Join-Path $discovery "pid_$processId.ini"
            $records[$processId] | Set-Content -LiteralPath $record
            if ($case.StaleRuntime) { [IO.File]::SetLastWriteTimeUtc($record, $case.Processes[0].CreationDate.AddDays(-1)) }
        }
        if ($case.Lock) {
            $lockFile = Join-Path $case.Lock 'hardware-qemu.ini.lock\pid'
            $null = New-Item -ItemType Directory -Force (Split-Path $lockFile)
            $(if ($case.LockPid) { $case.LockPid } else { $case.Processes[0].ProcessId }) | Set-Content -LiteralPath $lockFile
            if ($case.StaleLock) { [IO.File]::SetLastWriteTimeUtc($lockFile, $case.Processes[0].CreationDate.AddDays(-1)) }
            $createdFiles += $lockFile
        }
        $lockHandle = $null
        if ($case.HoldLock) { $lockHandle = [IO.File]::Open($lockFile, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
        if ($case.NoCreationDate) { $case.Processes[0].CreationDate = $null }
        if ($case.ThrowCommandLine) {
            $case.Processes[0].PSObject.Properties.Remove('CommandLine')
            $case.Processes[0] | Add-Member ScriptProperty CommandLine { throw 'Access denied' }
        }
        if ($case.ExpandOut) { $fixture.Processes[0].CommandLine = $fixture.Processes[0].CommandLine.Replace('{Out}', (Quote-Argument $out)) }
        $sdkArgument = if ($case.Sdk) { $case.Sdk } else { $sdk }
        & $runner -Suite $suite -Sdk $sdkArgument -Baseline $case.Baseline -Manager $manager -PackageScripts $package -Out $out 6>$null
        Check ($LASTEXITCODE -eq [int][bool]$case.FailedItem) "$($case.Name): exit code"
        $log = Get-Content -LiteralPath "$out\regress.log" -Raw
        $line = ($log -split '\r?\n' | Where-Object { $_ -match '留下的测试机 qemu：' }) -replace '^.*留下的测试机 qemu：', ''
        Check ($line -ceq $case.Left) "$($case.Name): leftover PIDs (wanted $($case.Left), got $line)"
        foreach ($processId in $case.Unknown) {
            Check ($log -match "qemu $processId [^\r\n]*无法判断") "$($case.Name): explicit unknown for $processId"
        }
        if ($case.QueryFails) { Check ($log -match 'qemu：无法判断归属') "$($case.Name): explicit query failure" }
        elseif (-not $case.Unknown) { Check ($log -notmatch '无法判断') "$($case.Name): no unknown diagnostic" }
        $json = @(Get-Content -LiteralPath "$out\results.json" -Raw | ConvertFrom-Json)
        $status = if ($case.FailedItem) { '不通过' } else { '通过' }
        Check ($json.Count -eq 1 -and $json[0].status -eq $status -and $json[0].summary -eq 'fixture') "$($case.Name): JSON result preserved"
        $fields = 'id,title,criterion,status,summary,seconds,gpu_events,console' + $(if ($case.FailedItem) { ',why' })
        Check ((($json[0].PSObject.Properties.Name) -join ',') -eq $fields) "$($case.Name): JSON fields preserved"
        $md = Get-Content -LiteralPath "$out\results.md" -Raw
        $cell = if ($case.FailedItem) { '**不通过**：fixture（项目自己判不通过）' } else { '通过：fixture' }
        Check ($md.Replace("`r`n", "`n") -ceq "| 项目 | 判据 | 结果 |`n|---|---|---|`n| Fixture | Result | $cell |`n") "$($case.Name): Markdown result preserved"
        if ($lockHandle) { $lockHandle.Dispose() }
        foreach ($file in $createdFiles) { Remove-Item -LiteralPath $file -Force }
    }
    $queries = $fixture.Queries
    $dryOut = Join-Path $scratch 'dry-run'
    & $runner -Suite $suite -Sdk $sdk -Manager $manager -PackageScripts $package -Out $dryOut -DryRun >$null
    Check ($fixture.Queries -eq $queries -and -not (Test-Path -LiteralPath $dryOut)) 'DryRun does not query QEMU or write reports'
} finally {
    foreach ($key in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key]) }
    # Delete only the unique directory created by this test, beneath the OS temp directory.
    $resolved = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notmatch '^modavd-qemu-49-[0-9a-f]{32}$') { throw "Unsafe cleanup path: $resolved" }
    if ($lockHandle) { $lockHandle.Dispose() }
    if (Test-Path -LiteralPath $alias) { Remove-Item -LiteralPath $alias -Force }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host "$checks checks, $($failures.Count) failures"
if ($failures.Count) { exit 1 }
