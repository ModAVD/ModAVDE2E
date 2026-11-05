# 本机配置：和这台测试机有关的路径（临时目录、管理器、测试根、测试实例、各游戏的自动化驱动）都从这里取，仓库里不写死。
# 读环境变量 MODAVD_E2E_CONFIG 指的文件；没设就读本目录的 local.psd1（不进 git，照 local.example.psd1 写）。
# 两处都没有就是空配置：参数没给、配置里也没有的路径直接报错，不猜。
#
# 用法（脚本的 param 之后）：
#   . (Join-Path $PSScriptRoot '..\local.ps1')
#   $Root = Use-Local TestRoot $Root '-Root'
$script:ModAVDLocalFile = if ($env:MODAVD_E2E_CONFIG) { $env:MODAVD_E2E_CONFIG } else { Join-Path $PSScriptRoot 'local.psd1' }
$script:ModAVDLocal = $null

function Get-Local {
    if ($null -eq $script:ModAVDLocal) {
        if (Test-Path -LiteralPath $script:ModAVDLocalFile -PathType Leaf) {
            $script:ModAVDLocal = Import-PowerShellDataFile -LiteralPath $script:ModAVDLocalFile
        } elseif ($env:MODAVD_E2E_CONFIG) {
            throw "MODAVD_E2E_CONFIG 指的本机配置不存在：$($env:MODAVD_E2E_CONFIG)"
        } else {
            $script:ModAVDLocal = @{}
        }
    }
    $script:ModAVDLocal
}

# 参数给了就用参数；否则取本机配置里的 $Key。都没有时 -Optional 返回 $null，否则报错。数组照原样返回，调用方用 @(...) 接。
function Use-Local([string]$Key, $Value, [string]$Param, [switch]$Optional) {
    if ($null -ne $Value -and "$Value" -ne '') { return $Value }
    $v = Get-Local
    foreach ($k in $Key.Split('.')) {
        if ($v -is [System.Collections.IDictionary] -and $v.Contains($k)) { $v = $v[$k] } else { $v = $null; break }
    }
    if ($null -ne $v -and "$v" -ne '') { return $v }
    if ($Optional) { return $null }
    throw "没有 $Key：给 $Param，或者写进本机配置 $($script:ModAVDLocalFile)（照 local.example.psd1）"
}

# $Path 是 $Roots 里某一个本身或在它下面时返回那一个（不分大小写，不解析链接），否则返回 $null
function Test-Inside([string]$Path, [string[]]$Roots) {
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    foreach ($r in $Roots) {
        if (-not $r) { continue }
        $f = [IO.Path]::GetFullPath($r).TrimEnd('\', '/')
        if ($p -eq $f -or $p.StartsWith($f + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $r }
    }
    return $null
}

# 生产：AUTO-MAS 在用的 ModAVD 根目录（本机配置 ProductionRoots，默认 D:\ModAVD）和它占着的 adb server 端口。
# 测试只读不写：测试根、回归输出、工作目录落在生产根目录下面，或者用到这几个端口，就停。
# 测试数据都在别的盘（E:\testbed 等），不再用「只许某个目录」的白名单，而是明确拒绝生产。
$script:ProductionAdbPorts = @(5037, 20049, 20050)
function Get-ProductionRoots {
    $v = @(Use-Local ProductionRoots $null '' -Optional | Where-Object { $_ })
    if ($v.Count) { $v } else { @('D:\ModAVD') }
}
# 不分大小写，\ 和 / 都算分隔符（CI 在 Linux 上跑测试，D:\ 写法的路径也要比得出来）
function Test-UnderPath([string]$Path, [string]$Root) {
    $norm = { param($x) ([IO.Path]::GetFullPath($x) -replace '[\\/]+', '/').TrimEnd('/').ToLowerInvariant() }
    $p = & $norm $Path; $r = & $norm $Root
    $p -eq $r -or $p.StartsWith($r + '/')
}
function Assert-NotProduction([string]$Path, [string]$What) {
    foreach ($r in Get-ProductionRoots) {
        if (Test-UnderPath $Path $r) { throw "$What 在生产根目录 $r 下（$Path）：测试不碰生产" }
    }
}
function Assert-NotProductionPort([int]$Port, [string]$What) {
    if ($Port -in $script:ProductionAdbPorts) { throw "$What 是 $Port，是生产在用的 adb 端口（$($script:ProductionAdbPorts -join '、')）" }
}
