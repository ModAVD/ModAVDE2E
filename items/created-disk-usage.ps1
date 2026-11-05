# Opt-in measurement on a new, isolated root. Never added to the release suite.
param(
    [Parameter(Mandatory)][ValidateSet('Create','Baseline','Resume','Install','Sample','Stop')][string]$Action,
    [Parameter(Mandatory)][string]$Work,
    [string]$Package,
    [string]$OfficialSdk,
    [int]$PortBase = 27300,
    [int]$AdbPort = 27383,
    [int]$ScriptAdbPort = 27384,
    [int]$Index = 0,
    [ValidateRange(16,512)][int]$DataGB = 64,
    [string]$Apk,
    [string]$Game,
    [string]$PackageId,
    [string]$Stage,
    [switch]$NoStreaming
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\disk-usage-lib.ps1"
$Work = [IO.Path]::GetFullPath($Work)
$Root = Join-Path $Work 'root'
$statePath = Join-Path $Work 'measurement.json'
$exe = Join-Path $Root 'tools\modavd.exe'

function Run-Modavd([string[]]$ArgsList) {
    $out = & $exe --root $Root @ArgsList 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "modavd $($ArgsList -join ' ') failed: $($out -join ' ')" }
    $out | Out-Host
}
function Run-Adb([string[]]$ArgsList) {
    $out = & (Join-Path $Root 'sdk\platform-tools\adb.exe') -P $state.adbPort -s $state.serial @ArgsList 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "adb failed: $($out -join ' ')" }
    return $out
}
function Save-State { $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8 }
function Save-Data([string]$Label) {
    $device = Get-DataDevice @(Run-Adb @('shell','cat','/proc/mounts'))
    $inode = Convert-DataDf @(Run-Adb @('shell','df','-i','/data')) $device
    $space = Convert-DataDf @(Run-Adb @('shell','df','-k','/data')) $device
    $entry = [ordered]@{ stage = $Label; time = (Get-Date).ToString('o'); device=$device; inodes = $inode; spaceKiB = $space }
    $state.samples += $entry
    Save-State
    $entry | ConvertTo-Json -Depth 5 | Write-Host
}

if ($Action -eq 'Create') {
    if (Test-Path -LiteralPath $Work) { throw "Work already exists: $Work" }
    if (-not $Package -or -not $OfficialSdk) { throw 'Create requires -Package and -OfficialSdk' }
    if ((Test-Inside $Work @($Package, $OfficialSdk)) -or (Test-Inside $Package @($Work)) -or (Test-Inside $OfficialSdk @($Work))) { throw 'Work, package and SDK must be separate directories' }
    if ($Index -lt 0 -or $Index -gt 9 -or $Index -eq 5) { throw 'Invalid instance index' }
    if ($PortBase -lt 21000 -or $PortBase -gt 60000 -or $PortBase % 100 -ne 0) { throw 'Choose an isolated portBase, a multiple of 100 in 21000..60000' }
    if ($AdbPort -eq $ScriptAdbPort -or $AdbPort -notin ($PortBase..($PortBase+99)) -or $ScriptAdbPort -notin ($PortBase..($PortBase+99))) { throw 'Choose two distinct adb ports in the isolated range' }
    $instancePorts = ($PortBase + 10*$Index)..($PortBase + 10*$Index + 2)
    if ($AdbPort -in $instancePorts -or $ScriptAdbPort -in $instancePorts) { throw 'adb port overlaps instance ports' }
    $busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in ($PortBase..($PortBase+99)))
    if ($busy) { throw "Port range in use: $(($busy.LocalPort | Sort-Object -Unique) -join ', ')" }
    foreach ($file in @('modavd-manifest.json','tools\modavd.exe','sdk\emulator\emulator.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Package $file) -PathType Leaf)) { throw "Missing package file: $file" }
    }
    foreach ($dir in @('platform-tools','system-images')) {
        if (-not (Test-Path -LiteralPath (Join-Path $OfficialSdk $dir) -PathType Container)) { throw "Missing SDK directory: $dir" }
        if (Test-Path -LiteralPath (Join-Path $Package "sdk\$dir")) { throw "Package already has sdk\$dir" }
    }
    New-Item -ItemType Directory -Path $Work | Out-Null
    & robocopy $Package $Root /E /COPY:DAT /R:2 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Package copy failed: $LASTEXITCODE" }
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $Root 'modavd-manifest.json') | ConvertFrom-Json
    if (-not $manifest.version -or -not $manifest.files) { throw 'Invalid package manifest' }
    foreach ($entry in $manifest.files.PSObject.Properties) {
        $file = Join-Path $Root $entry.Name
        if (-not (Test-Inside $file @($Root)) -or -not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file).Hash -ne $entry.Value.sha256) { throw "Package file missing or hash mismatch: $($entry.Name)" }
    }
    foreach ($dir in @('platform-tools','system-images')) {
        & robocopy (Join-Path $OfficialSdk $dir) (Join-Path $Root "sdk\$dir") /E /COPY:DAT /R:2 /W:1 /NFL /NDL /NP /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "SDK copy failed: $LASTEXITCODE" }
    }
    @{ adbServerPort=$AdbPort; scriptAdbServerPort=$ScriptAdbPort; portBase=$PortBase } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'mas-avd.json') -Encoding utf8
    $state = [pscustomobject]@{ root=$Root; index=$Index; portBase=$PortBase; adbPort=$AdbPort; scriptAdbPort=$ScriptAdbPort; version=$manifest.version; dataGB=$DataGB; memory='4G'; cpu=4; bridge='default'; serial=''; createStarted=(Get-Date).ToString('o'); samples=@() }
    Save-State
    if ((Get-PortBase $Root $exe) -ne $PortBase) { throw 'Package does not use the requested portBase' }
    $busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in ($PortBase..($PortBase+99)))
    if ($busy) { throw "Port range became busy while copying: $(($busy.LocalPort | Sort-Object -Unique) -join ', ')" }
    Run-Modavd @('create','--index',"$Index",'--title','disk usage','--memory','4G','--cpu','4','--data-gb',"$DataGB")
    $state | Add-Member -NotePropertyName createFinished -NotePropertyValue (Get-Date).ToString('o')
    $state.serial = (Assert-InstancePorts $Index $PortBase $Root $exe).Serial
    Save-State
    $image = Join-Path $Root "avd\mas_$Index.avd\userdata-qemu.img.qcow2"
    $info = & (Join-Path $Root 'sdk\emulator\qemu-img.exe') info --output=json $image | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'qemu-img info failed' }
    $state | Add-Member -NotePropertyName afterCreate -NotePropertyValue ([ordered]@{ time=(Get-Date).ToString('o'); fileLengthBytes=(Get-Item -LiteralPath $image).Length; allocatedBytes=(Get-AllocatedBytes $image); virtualBytes=$info.'virtual-size' })
    Save-State
    Run-Modavd @('start',"$Index",'--window')
    Save-Data 'before-install'
    if ($state.samples[-1].inodes.total -ne 1048576) { throw 'This instance does not have the expected inode cap' }
    Write-Host "Created isolated root. Continue with Install using -Work '$Work'."
} else {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'No measurement state in Work' }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($state.root -ne $Root -or -not $state.serial) { throw 'Measurement root or serial does not match' }
    $cfg = Get-RootConfig $Root
    if ($cfg.adbServerPort -ne $state.adbPort -or $cfg.scriptAdbServerPort -ne $state.scriptAdbPort -or $cfg.portBase -ne $state.portBase -or $state.adbPort -in 5037,20049,20050) { throw 'Measurement ports do not match' }
    if ((Get-InstancePorts $state.index $Root $exe).Serial -ne $state.serial) { throw 'Instance serial changed' }
    switch ($Action) {
        'Baseline' {
            if (-not $state.afterCreate -or $state.game.installed) { throw 'Baseline requires a completed create and no installed game' }
            Save-Data 'before-install'
            if ($state.samples[-1].inodes.total -ne 1048576) { throw 'This instance does not have the expected inode cap' }
        }
        'Resume' {
            if (-not $state.afterCreate -or $state.game.installed) { throw 'Resume requires a completed create and no installed game' }
            Run-Modavd @('start',"$($state.index)",'--window')
            Save-Data 'before-install'
            if ($state.samples[-1].inodes.total -ne 1048576) { throw 'This instance does not have the expected inode cap' }
        }
        'Install' {
            if (-not $Apk -or -not $Game -or $PackageId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' -or -not (Test-Path -LiteralPath $Apk -PathType Leaf)) { throw 'Install requires -Apk, -Game and a valid -PackageId' }
            $sha = (Get-FileHash -LiteralPath $Apk).Hash.ToLower()
            Assert-InstallState $state $sha $PackageId
            if (@(Run-Adb @('shell','pm','list','packages', $PackageId)) -contains "package:$PackageId") { throw 'Game was already installed before the measurement' }
            if (-not $state.game) { $state | Add-Member -NotePropertyName game -NotePropertyValue ([pscustomobject]@{ name=$Game; packageId=$PackageId; apkSha256=$sha; installStarted=(Get-Date).ToString('o'); installed=$false }) }
            $state.game | Add-Member -Force -NotePropertyName lastAttempt -NotePropertyValue (Get-Date).ToString('o')
            $state.game | Add-Member -Force -NotePropertyName lastInstallMode -NotePropertyValue $(if ($NoStreaming) { 'non-streaming' } else { 'streaming' })
            Save-State
            $installArgs = @('install')
            if ($NoStreaming) { $installArgs += '--no-streaming' }
            $installArgs += $Apk
            $output = @(Run-Adb $installArgs)
            if ($output -notcontains 'Success') { throw "adb install did not report success: $($output -join ' ')" }
            $paths = @(Run-Adb @('shell','pm','path',$PackageId))
            if (-not @($paths | Where-Object { $_ -match '^package:' }).Count) { throw "Installed package $PackageId not found" }
            $state.game.installed = $true
            $state.game | Add-Member -NotePropertyName installedAt -NotePropertyValue (Get-Date).ToString('o')
            Save-State
            Save-Data 'apk-installed'
        }
        'Sample' {
            if (-not $state.game.installed -or -not $Stage) { throw 'Sample requires an installed game and -Stage' }
            Save-Data $Stage
        }
        'Stop' { Run-Modavd @('stop',"$($state.index)") }
    }
}
