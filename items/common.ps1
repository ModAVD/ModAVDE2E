# 各项脚本共用（. "$PSScriptRoot\common.ps1"）：测试根换 SDK、调 modavd、私有 adb、结果行、本机配置（local.ps1）。
# 开关机一律走测试根自己的 tools\modavd.exe：开机后的设置和产品一样，关机先正常关机、不成再 sync 后结束。
. (Join-Path $PSScriptRoot '..\local.ps1')
. (Join-Path $PSScriptRoot 'port-guard.ps1')

# 管理器和随包脚本：regress.ps1 的 -Manager / -PackageScripts 经环境变量传下来。随包脚本单独跑某一项时可以取本机配置的
# PackageScripts（ModAVD 仓库的 package\）；管理器（放着 tools\modavd.exe 和 ModAVD.exe 的目录）不取本机配置，只认
# MODAVD_REGRESS_MANAGER：本机留着的旧管理器不认 portBase，会把测试根的实例开到生产的端口段上。用到时还没有就报错，
# 不用管理器的项（比如不碰测试根的）不受影响。
$script:ManagerDir = $env:MODAVD_REGRESS_MANAGER
function Get-ManagerDir {
    if (-not $script:ManagerDir) {
        throw '没有管理器：单独跑某一项时，先把环境变量 MODAVD_REGRESS_MANAGER 设成发版用的那个管理器目录（放着 tools\modavd.exe 和 ModAVD.exe，即解开的 ModAVDManager Release 包或 build.ps1 -Out）。不从本机配置取，旧版管理器不认 portBase，会把测试根的实例开到生产的 20000 段上'
    }
    $script:ManagerDir
}
$script:PackageScripts = Use-Local PackageScripts $env:MODAVD_REGRESS_PACKAGE '-PackageScripts（regress.ps1）' -Optional
function Get-PackageScripts { Use-Local PackageScripts $script:PackageScripts '-PackageScripts（regress.ps1）' }

# 测试根的 tools\modavd.exe、ModAVD.exe、tools\modavd-bridge.ps1 换成上面这一版的：测试根是很早以前建的，不同步就一直在测
# 旧的命令行。内容一样就不动。
function Sync-RootTools([string]$Root) {
    # 一行一对（前面的逗号让每对保持成一个数组，不被拆开）
    $manager = Get-ManagerDir
    $pairs = @(
        , @((Join-Path $manager 'tools\modavd.exe'), (Join-Path $Root 'tools\modavd.exe'))
        , @((Join-Path $manager 'ModAVD.exe'), (Join-Path $Root 'ModAVD.exe'))
        , @((Join-Path (Get-PackageScripts) 'modavd-bridge.ps1'), (Join-Path $Root 'tools\modavd-bridge.ps1')))
    foreach ($p in $pairs) {
        if (-not (Test-Path -LiteralPath $p[0])) { continue }
        if ((Test-Path -LiteralPath $p[1]) -and (Get-FileHash -LiteralPath $p[0]).Hash -eq (Get-FileHash -LiteralPath $p[1]).Hash) { continue }
        New-Item -ItemType Directory -Force (Split-Path $p[1]) | Out-Null
        Copy-Item -LiteralPath $p[0] -Destination $p[1] -Force
    }
}

# 把测试根 mas-avd.json 的 sdkRoot 换成 $Sdk，返回原值（跑完换回去）。只改这一个值，其余字节不动。顺带同步测试根的工具。
function Set-RootSdk([string]$Root, [string]$Sdk) {
    Sync-RootTools $Root
    Assert-ManagerPortBase $Root (Join-Path $Root 'tools\modavd.exe') | Out-Null
    $p = Join-Path $Root 'mas-avd.json'
    $t = [IO.File]::ReadAllText($p)
    $m = [regex]::Match($t, '"sdkRoot":\s*"((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) { throw "$p 里没有 sdkRoot" }
    $g = $m.Groups[1]
    $new = $t.Substring(0, $g.Index) + ($Sdk -replace '\\', '\\') + $t.Substring($g.Index + $g.Length)
    [IO.File]::WriteAllText($p, $new, [Text.UTF8Encoding]::new($false))
    return ($g.Value -replace '\\\\', '\')
}

function Get-RootConfig([string]$Root) { Get-Content -LiteralPath (Join-Path $Root 'mas-avd.json') -Raw | ConvertFrom-Json }

# modavd <参数...>，输出逐行返回，退出码在 $LASTEXITCODE
function M { & (Join-Path $script:Root 'tools\modavd.exe') --root $script:Root @args 2>&1 | ForEach-Object { "$_" } }

# modavd --json <参数...> 的 data；失败就报错。只读 stdout：--json 时进度日志写在 stderr，不能并进来。
# $Exe 默认是根目录自己的 tools\modavd.exe。
function Invoke-ModavdJson([string]$Root, [string]$Exe, [string[]]$Argv) {
    if (-not $Exe) { $Exe = Join-Path $Root 'tools\modavd.exe' }
    $out = & $Exe --root $Root --json @Argv 2>$null
    $code = $LASTEXITCODE
    $r = $null
    try { $r = ($out -join "`n") | ConvertFrom-Json } catch { }
    if ($code -ne 0 -or -not $r -or -not $r.ok) {
        throw "modavd $($Argv -join ' ') 失败（退出码 $code）：$(if ($r.error) { $r.error.message } else { $out -join ' ' })"
    }
    $r.data
}

# 端口一律从 modavd 取，不自己按 20000 + 10 × 编号算：根目录在 mas-avd.json 里设了 portBase（开发、测试用的根目录，
# 免得和同机生产根目录的同编号实例抢端口）时，实例不在 20000 段上。
# 第 $i 台实例的 serial 和控制台 / adb / gRPC 端口（info --json）。实例要已经建好；同一个根目录的同一台只问一次。
$script:PortsCache = @{}
function Get-InstancePorts([int]$i, [string]$Root = $script:Root, [string]$Exe) {
    $key = "$Root|$i"
    if (-not $script:PortsCache.ContainsKey($key)) {
        $d = Invoke-ModavdJson $Root $Exe @('info', "$i")
        $script:PortsCache[$key] = [pscustomobject]@{ Serial = $d.serial; Console = [int]$d.ports.console; Adb = [int]$d.ports.adb; Grpc = [int]$d.ports.grpc }
    }
    $script:PortsCache[$key]
}

# 根目录的端口段（list --json 的 port_base）。还不认 portBase 的 modavd（ModAVD/ModAVD#75 以前）没有这一项，返回 $null，
# 它的实例都在 20000 段上。
function Get-PortBase([string]$Root = $script:Root, [string]$Exe) {
    $d = Invoke-ModavdJson $Root $Exe @('list')
    if ($d.PSObject.Properties.Name -contains 'port_base') { [int]$d.port_base } else { $null }
}

# 开测试根的实例之前核对 $Exe（管理器的 modavd.exe）认 portBase，返回它给这个根目录用的端口段。不满足就报错，不开机：
#  - list --json 没有 port_base：旧版（ModAVDManager 0.3.1 以前）不认 portBase，实例只会开在 20000 段上；
#  - 根目录的 mas-avd.json 写了 portBase（或 $Want 不是 0）而和 port_base 不一致；
#  - port_base 是 20000：那是生产根目录的段，测试根不许用。
# 报错里写管理器路径、版本和看到的 port_base。
function Assert-ManagerPortBase([string]$Root, [string]$Exe, [int]$Want = 0) {
    $d = Invoke-ModavdJson $Root $Exe @('list')
    $seen = if ($d.PSObject.Properties.Name -contains 'port_base') { [int]$d.port_base } else { $null }
    $cfgPath = Join-Path $Root 'mas-avd.json'
    $written = 0
    if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
        $c = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
        if ($c.PSObject.Properties.Name -contains 'portBase' -and $c.portBase) { $written = [int]$c.portBase }
    }
    $problem = if ($null -eq $seen) { 'list --json 没有 port_base，这版管理器不认 portBase，实例只会开在 20000 段（生产在用）上' }
        elseif ($seen -eq 20000) { "port_base 是 20000，那是生产根目录的端口段，测试根不许用（mas-avd.json 的 portBase 要写成别的段）" }
        elseif ($written -and $seen -ne $written) { "mas-avd.json 写了 portBase $written，管理器用的端口段却是 $seen" }
        elseif ($Want -and $seen -ne $Want) { "要求 portBase $Want，管理器用的端口段却是 $seen" }
    if ($problem) {
        $ver = try { (Invoke-ModavdJson $Root $Exe @('version')).version } catch { '查不到' }
        throw "管理器不能开测试根 $Root 的实例：$problem。管理器 $Exe（版本 $ver），看到的 port_base：$(if ($null -eq $seen) { '无' } else { $seen })"
    }
    $seen
}

# 自己搭的根目录（upgrade、ime-pkg）在 mas-avd.json 写了 portBase $Want（0 = 没写）以后，modavd 实际用的端口段；
# 核对见 Assert-ManagerPortBase（旧版不认 portBase、port_base 是 20000、和 $Want 不一致都报错）。
function Resolve-PortBase([string]$Root, [string]$Exe, [int]$Want) { Assert-ManagerPortBase $Root $Exe $Want }

# 新建以后核对第 $i 台的端口落在端口段 $Base 上（控制台 = $Base + 10 × 编号），返回 Get-InstancePorts 的结果
function Assert-InstancePorts([int]$i, [int]$Base, [string]$Root, [string]$Exe) {
    $p = Get-InstancePorts $i $Root $Exe
    if ($p.Console -ne $Base + 10 * $i) { throw "modavd 报的 $i 号控制台端口是 $($p.Console)，按端口段 $Base 应该是 $($Base + 10 * $i)" }
    $p
}

# 对第 $script:Index 台实例的 adb（测试根的私有 adb server 和同一个 SDK 的 adb）
function A {
    $cfg = Get-RootConfig $script:Root
    if ($cfg.adbServerPort -in 5037, 20049, 20050) { throw "测试根的 adb 端口是 $($cfg.adbServerPort)，不碰生产端口" }
    $serial = (Get-InstancePorts $script:Index).Serial
    & (Join-Path $cfg.sdkRoot 'platform-tools\adb.exe') -P $cfg.adbServerPort -s $serial @args 2>&1 | ForEach-Object { "$_" }
}

# 以 root 跑一段客体脚本：推成文件再 sh，免得引号穿过 adb shell / su 两层
function Su([string]$Script) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "regress-$PID.sh"
    [IO.File]::WriteAllText($tmp, ($Script -replace "`r`n", "`n"))
    A push $tmp /data/local/tmp/regress.sh | Out-Null
    Remove-Item -LiteralPath $tmp -Force
    A shell 'su 0 sh /data/local/tmp/regress.sh; rm -f /data/local/tmp/regress.sh'
}

function Say([string]$m) { Write-Output "$(Get-Date -Format 'HH:mm:ss') $m" }

# 删掉本项自己新建的测试实例。刚关机时 modavd 的开机看护进程可能还拿着启动锁（「正在启动，无法删除」），重试最多 60 秒。
function Remove-TestInstance([int]$i) {
    for ($k = 0; $k -lt 30; $k++) {
        $o = M delete $i --yes
        if ($LASTEXITCODE -eq 0) { $o | Select-Object -Last 1 | ForEach-Object { Say "  $_" }; return }
        Start-Sleep 2
    }
    Say "  实例 $i 没删掉：$(($o | Select-Object -Last 1))"
}

# 运行器认的结果行（最后一行为准）
function Result([bool]$Pass, [string]$Summary) {
    'REGRESS-RESULT ' + ([ordered]@{ pass = $Pass; summary = $Summary } | ConvertTo-Json -Compress)
}
