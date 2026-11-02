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
