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

# 把测试根 mas-avd.json 的 sdkRoot 换成 $Sdk，返回原值（跑完把原值传回来换回去）。只动这一个键，其余字节不动。顺带同步测试根的工具。
# testbed 的根是整包装出来的，mas-avd.json 里没有 sdkRoot（用根目录下的 sdk\）：这时在开头的「{」后面加上这个键，返回 $null；
# 换回去时传 $null，把这个键整行删掉（管理器中途改写过 mas-avd.json、把它挪到最后一个也认）。原来就是 "" 的照样换回 ""。
function Set-RootSdk([string]$Root, $Sdk) {
    Sync-RootTools $Root
    Assert-ManagerPortBase $Root (Join-Path $Root 'tools\modavd.exe') | Out-Null
    $p = Join-Path $Root 'mas-avd.json'
    $t = [IO.File]::ReadAllText($p)
    $keyPattern = '"sdkRoot"\s*:\s*"((?:[^"\\]|\\.)*)"'
    $m = [regex]::Match($t, $keyPattern)
    $old = if ($m.Success) { $m.Groups[1].Value -replace '\\\\', '\' } else { $null }
    if ($null -eq $Sdk) {
        if (-not $m.Success) { return $null }
        # 后面跟着逗号的（在前面或中间）连同它前面的换行、缩进一起删；是最后一个键的，连同它前面的逗号一起删
        $cut = [regex]::Match($t, '(\r?\n[ \t]*)?' + $keyPattern + '\s*,[ \t]*')
        if (-not $cut.Success) { $cut = [regex]::Match($t, ',\s*' + $keyPattern) }
        if (-not $cut.Success) { $cut = $m }
        $new = $t.Remove($cut.Index, $cut.Length)
    } elseif ($m.Success) {
        $g = $m.Groups[1]
        $new = $t.Substring(0, $g.Index) + ([string]$Sdk -replace '\\', '\\' -replace '"', '\"') + $t.Substring($g.Index + $g.Length)
    } else {
        $brace = $t.IndexOf('{')
        if ($brace -lt 0) { throw "$p 不是 JSON 对象" }
        $value = [string]$Sdk -replace '\\', '\\' -replace '"', '\"'
        $rest = $t.Substring($brace + 1)
        # 换行和缩进跟着第一个键；空对象就不加逗号
        $first = [regex]::Match($rest, '^(\r?\n)([ \t]*)"')
        $entry = if ($first.Success) { "$($first.Groups[1].Value)$($first.Groups[2].Value)`"sdkRoot`": `"$value`"," }
        elseif ($rest -match '^\s*}') { "`"sdkRoot`": `"$value`"" }
        else { "`"sdkRoot`": `"$value`", " }
        $new = $t.Substring(0, $brace + 1) + $entry + $rest
    }
    [IO.File]::WriteAllText($p, $new, [Text.UTF8Encoding]::new($false))
    return $old
}

function Get-RootConfig([string]$Root) { Get-Content -LiteralPath (Join-Path $Root 'mas-avd.json') -Raw | ConvertFrom-Json }

# 测试根：已有的 ModAVD 根目录（E:\testbed 下的 flow-a / flow-b），回归只在里面建临时实例，不新建根目录（11-05 用户定：
# testbed 里只有三组模拟器，不可以去别的地方新建）。生产根目录（含 ProductionRoots 列的用户的根）一律拒绝；本机配置列了
# TestRoots 时只认列出来的。两个 adb server 端口都要写在 mas-avd.json 里、不是生产的（没写时管理器用生产的 20050 / 20049）。
# 返回完整路径。
function Resolve-TestRoot([string]$Root, [string]$What = '测试根') {
    if (-not $Root) { throw "没有$What：给 -Root，或者写进本机配置 TestRoot / PackageRoot（E:\testbed 下已有的根目录）" }
    $full = [IO.Path]::GetFullPath($Root)
    Assert-NotProduction $full $What
    Assert-ListedTestRoot $full $What
    if (-not (Test-Path -LiteralPath (Join-Path $full 'mas-avd.json') -PathType Leaf)) {
        throw "$What $full 没有 mas-avd.json：回归只用已有的测试根（E:\testbed 下的 flow-a / flow-b），不新建根目录"
    }
    $cfg = Get-RootConfig $full
    foreach ($k in 'adbServerPort', 'scriptAdbServerPort') {
        if (-not ($cfg.PSObject.Properties.Name -contains $k -and $cfg.$k)) {
            throw "$What $full 的 mas-avd.json 没写 $k：没写时管理器用生产的 adb 端口（20050 / 20049），测试根要写自己的"
        }
        Assert-NotProductionPort ([int]$cfg.$k) "$What 的 $k"
    }
    $full
}

# 包根清单（modavd-manifest.json）列的文件，相对路径；没有清单、读不出、没有 files 时返回 $null（不知道包里有哪些文件）
function Get-ManifestFiles([string]$Dir) {
    $m = Join-Path $Dir 'modavd-manifest.json'
    if (-not (Test-Path -LiteralPath $m -PathType Leaf)) { return $null }
    try { $files = (Get-Content -LiteralPath $m -Raw | ConvertFrom-Json -ErrorAction Stop).files } catch { return $null }
    if ($null -eq $files) { return $null }
    @($files.PSObject.Properties.Name)
}

# 换包时要先删的：$Current（根目录现在的清单）有、$Next（要装的包的清单）没有的文件。只会是包里的文件，不会是实例、日志这些。
function Get-StalePackageFiles($Current, $Next) {
    @(@($Current) | Where-Object { $_ -and @($Next) -notcontains $_ })
}

# 把组包目录 $From 装进测试根 $Root（「怎么更新」那样整个覆盖），装哪一版都行（升级测试先装回上一版）：
# 先删掉根目录现在的包里有、$From 里没有的文件（按两边的 modavd-manifest.json），再整个覆盖。avd、logs、mas-avd.json 这些
# 不在清单里的不动。$From 的清单认不出（早年的包没有清单）时不知道该删哪些，只覆盖。返回删掉的文件。
# 清单写错、列了绝对路径、带 ..、或者列了 avd\、logs\、mas-avd.json（实例、日志、配置）时，一个文件都不删就停。
function Install-Package([string]$From, [string]$Root) {
    Assert-NotProduction $Root '要换包的根目录'
    Assert-ListedTestRoot $Root '要换包的根目录'
    $fromFiles = Get-ManifestFiles $From
    $stale = if ($null -ne $fromFiles) { Get-StalePackageFiles (Get-ManifestFiles $Root) $fromFiles } else { @() }
    foreach ($rel in $stale) {
        if ([IO.Path]::IsPathRooted($rel) -or $rel -match '(^|[\\/])\.\.([\\/]|$)') { throw "清单里的路径不对：$rel" }
        $top = ($rel -split '[\\/]')[0]
        if ($top -in 'avd', 'logs', 'mas-avd.json') { throw "清单里列了实例、日志或配置（$rel）：换包不删这些" }
    }
    foreach ($rel in $stale) {
        $p = Join-Path $Root $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force }
    }
    & robocopy $From $Root /E /COPY:DAT /R:5 /W:2 /NFL /NDL /NP /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $From -> $Root 失败（$LASTEXITCODE）" }
    $global:LASTEXITCODE = 0
    $stale
}

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
