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

# 不碰的根目录：AUTO-MAS 在用的生产根目录 D:\ModAVD，加上本机配置 ProductionRoots 里列的（用户自己用的根，比如
# E:\testbed\fsync-user，也写进去）；还有生产占着的 adb server 端口。ProductionRoots 是在 D:\ModAVD 之外再加，不是替换它。
# 测试只读不写：测试根、回归输出、工作目录、实例目录落在这些根目录下面，或者用到这几个端口，就停。
$script:DefaultProductionRoot = 'D:\ModAVD'
$script:ProductionAdbPorts = @(5037, 20049, 20050)
function Get-ProductionRoots {
    @(@($script:DefaultProductionRoot) + @(Use-Local ProductionRoots $null '' -Optional | Where-Object { $_ }))
}
# 比路径用：不分大小写，\ 和 / 都算分隔符（CI 在 Linux 上跑测试，D:\ 写法的路径也要比得出来）。只算字符串，不读盘
function Get-NormalPath([string]$Path) { ([IO.Path]::GetFullPath($Path) -replace '[\\/]+', '/').TrimEnd('/').ToLowerInvariant() }
function Test-UnderPath([string]$Path, [string]$Root) {
    $p = Get-NormalPath $Path; $r = Get-NormalPath $Root
    $p -eq $r -or $p.StartsWith($r + '/')
}
function Assert-NotProduction([string]$Path, [string]$What) {
    foreach ($r in Get-ProductionRoots) {
        if (Test-UnderPath $Path $r) { throw "$What 在生产根目录 $r 下（$Path）：测试不碰生产" }
    }
}
# 测试根白名单（可选）：本机配置 TestRoots 列了，回归就只用列出来的根目录本身（维护者的机器上是 E:\testbed\flow-a、flow-b）；
# 没列就不限，只拒绝上面那些。
function Assert-ListedTestRoot([string]$Root, [string]$What) {
    $listed = @(Use-Local TestRoots $null '' -Optional | Where-Object { $_ })
    if (-not $listed.Count) { return }
    $p = Get-NormalPath $Root
    foreach ($r in $listed) { if ((Get-NormalPath $r) -eq $p) { return } }
    throw "$What $Root 不在本机配置 TestRoots 里（$($listed -join '、')）：回归只用列出来的测试根"
}
function Assert-NotProductionPort([int]$Port, [string]$What) {
    if ($Port -in $script:ProductionAdbPorts) { throw "$What 是 $Port，是生产在用的 adb 端口（$($script:ProductionAdbPorts -join '、')）" }
}
