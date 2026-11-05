# Opt-in measurement on a new instance in an existing test root (E:\testbed\flow-a / flow-b): no new roots outside
# the testbed (11-05). Never added to the release suite. -Work only holds the measurement state, it is not a root.
param(
    [Parameter(Mandatory)][ValidateSet('Create','Baseline','Resume','Install','Sample','Stop')][string]$Action,
    [Parameter(Mandatory)][string]$Work,
    # Create: the existing test root the instance goes into (local configuration TestRoot when not given); never the
    # production root. Later actions take it from the measurement state.
    [string]$Root,
    # Create: the package the root must already be on (its modavd-manifest.json version); not installed by this script
    [string]$Package,
    [int]$Index = 7,
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
Assert-NotProduction $Work 'Work'
$statePath = Join-Path $Work 'measurement.json'
if ($Action -eq 'Create') {
    $Root = Resolve-TestRoot (Use-Local TestRoot $Root '-Root') 'measurement root'
} else {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'No measurement state in Work' }
    $Root = Resolve-TestRoot (Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json).root 'measurement root'
}
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
    if ((Test-Inside $Work @($Root)) -or (Test-Inside $Root @($Work))) { throw 'Work and the test root must be separate directories' }
    if ($Index -lt 0 -or $Index -gt 9 -or $Index -eq 5) { throw 'Invalid instance index' }
    $cfg = Get-RootConfig $Root
    if ((Test-Path -LiteralPath (Join-Path $Root "avd\mas_$Index.avd")) -or ($cfg.instances.PSObject.Properties.Name -contains "$Index")) { throw "Instance $Index already exists in $Root; pick a free -Index" }
    $version = (Get-Content -Raw -LiteralPath (Join-Path $Root 'modavd-manifest.json') | ConvertFrom-Json).version
    if ($Package) {
        $want = (Get-Content -Raw -LiteralPath (Join-Path $Package 'modavd-manifest.json') | ConvertFrom-Json).version
        if ($want -ne $version) { throw "The test root is on $version, not on the package's ${want}: install the package into it first (upgrade / ime-pkg do it with Install-Package)" }
    }
    $PortBase = Assert-ManagerPortBase $Root $exe
    $AdbPort = [int]$cfg.adbServerPort; $ScriptAdbPort = [int]$cfg.scriptAdbServerPort
    foreach ($p in $AdbPort, $ScriptAdbPort) { Assert-NotProductionPort $p 'test root adb port' }
    $instancePorts = ($PortBase + 10*$Index)..($PortBase + 10*$Index + 2)
    $busy = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -in $instancePorts)
    if ($busy) { throw "Instance ports in use: $(($busy.LocalPort | Sort-Object -Unique) -join ', ')" }
    New-Item -ItemType Directory -Path $Work | Out-Null
    $state = [pscustomobject]@{ root=$Root; index=$Index; portBase=$PortBase; adbPort=$AdbPort; scriptAdbPort=$ScriptAdbPort; version=$version; dataGB=$DataGB; memory='4G'; cpu=4; bridge='default'; serial=''; createStarted=(Get-Date).ToString('o'); samples=@() }
    Save-State    Run-Modavd @('create','--index',"$Index",'--title','disk usage','--memory','4G','--cpu','4','--data-gb',"$DataGB")
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
    Write-Host "Created instance $Index in $Root. Continue with Install using -Work '$Work'; afterwards remove it with modavd delete $Index."
} else {
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
