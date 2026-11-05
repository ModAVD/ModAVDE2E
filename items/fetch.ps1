# 打完包补跑：用组包目录搭新的根目录，从空补全组件（adb 和系统镜像），命令行和「补全组件.bat」两条路各一遍。
# 0.37.0–0.38.0 的「补全组件.bat」装系统镜像必然失败，回归一直没测出来：别的项都把组件链到官方 SDK，不走补全组件。
#  - 命令行：tools\modavd.exe components fetch --accept-license --keep-downloads --json，两样都装好、都是这次下的。
#  - 批处理：另搭一个根目录，把上一步下好的两个 zip 放进 downloads\（不重下 1.5 GB），用重定向的输入跑「补全组件.bat」：
#    新的批处理（tools\ 里有 components-sources.txt，0.38.1 起）先问下载源，回车选自动；再同意许可协议，结尾 pause 也喂一个回车。
#    老的批处理（调 fetch-components.ps1）只问许可协议。退出码 0，下载源记成 auto（新的批处理才有）。
#  - 两个根目录最后都再跑一次 components fetch：两样都算齐全、跳过（「齐全」按 fetch 的严格规则，不是 status 的宽松规则）。
# 只有取许可协议清单要联网；-Cache 给了放着这两个 zip 的目录时，命令行那一步也不下载。
# 根目录只放补全组件用得到的：包根的批处理、tools\、sdk\emulator 里的 emulator.exe 和 source.properties。跑完删掉（-Keep 留着）。
# 不开模拟器，不起 adb server。
param(
    # 组包目录（release\ModAVD-<版本>-win-x64，只读）
    [Parameter(Mandatory)][string]$Package,
    # 放着 platform-tools_r37.0.1-win.zip、x86_64-34_r14.zip 的目录（本机配置 ComponentCache，可以没有）
    [string]$Cache,
    # 默认 <TempRoot>\regress-fetch
    [string]$Work,
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
[cultureinfo]::CurrentCulture = [cultureinfo]::InvariantCulture
. "$PSScriptRoot\common.ps1"
$Cache = Use-Local ComponentCache $Cache '-Cache' -Optional
if (-not $Work) { $Work = Join-Path (Use-Local TempRoot $null '-Work') 'regress-fetch' }
$Package = (Resolve-Path -LiteralPath $Package).Path
$fetchBat = Join-Path $Package '补全组件.bat'
if (-not (Test-Path -LiteralPath (Join-Path $Package 'tools\modavd.exe')) -or -not (Test-Path -LiteralPath $fetchBat)) {
    throw "不是组包目录（要有 tools\modavd.exe 和「补全组件.bat」）：$Package"
}
if (Test-Path -LiteralPath $Work) { throw "-Work 要是不存在的新目录：$Work" }
$zips = @('platform-tools_r37.0.1-win.zip', 'x86_64-34_r14.zip')
$problems = @()
$notes = @()

# 搭一个只够补全组件用的根目录
function New-FetchRoot([string]$Dir) {
    New-Item -ItemType Directory -Force (Join-Path $Dir 'sdk\emulator') | Out-Null
    Get-ChildItem -LiteralPath $Package -File | Where-Object { $_.Extension -eq '.bat' } | Copy-Item -Destination $Dir
    Copy-Item -LiteralPath (Join-Path $Package 'tools') -Destination $Dir -Recurse
    foreach ($n in 'emulator.exe', 'source.properties') {
        Copy-Item -LiteralPath (Join-Path $Package "sdk\emulator\$n") -Destination (Join-Path $Dir 'sdk\emulator')
    }
}

# 两样都装齐了：再跑一次 fetch，两样都是「跳过」，什么也不下
function Test-Complete([string]$Dir, [string]$Label) {
    $out = & (Join-Path $Dir 'tools\modavd.exe') --root $Dir --json components fetch --accept-license 2>$null
    $r = $null
    try { $r = ($out -join "`n") | ConvertFrom-Json } catch { }
    if ($LASTEXITCODE -ne 0 -or -not $r -or -not $r.ok) {
        $script:problems += "${Label}：再跑一次 fetch 失败（退出码 $LASTEXITCODE）"
        return
    }
    $bad = @($r.data.components | Where-Object { -not ($_.installed -and $_.skipped) })
    if ($bad) { $script:problems += "${Label}：再跑一次 fetch 时没算齐全：$(($bad | ForEach-Object { $_.id }) -join '、')" }
}

$made = $false
try {
    New-Item -ItemType Directory -Path $Work | Out-Null
    $made = $true

    # 1. 命令行
    $cliRoot = Join-Path $Work 'cli'
    New-FetchRoot $cliRoot
    if ($Cache) {
        New-Item -ItemType Directory -Force (Join-Path $cliRoot 'downloads') | Out-Null
        foreach ($z in $zips) { Copy-Item -LiteralPath (Join-Path $Cache $z) -Destination (Join-Path $cliRoot 'downloads') }
    }
    Say "命令行：components fetch（$(if ($Cache) { '用缓存的 zip' } else { '从网上下载' })）"
    $t0 = Get-Date
    $out = & (Join-Path $cliRoot 'tools\modavd.exe') --root $cliRoot --json components fetch --accept-license --keep-downloads 2>$null
    $code = $LASTEXITCODE
    $r = $null
    try { $r = ($out -join "`n") | ConvertFrom-Json } catch { }
    if ($code -ne 0 -or -not $r -or -not $r.ok) {
        $problems += "命令行补全组件失败（退出码 $code）：$(if ($r.error) { $r.error.message } else { 'JSON 读不出' })"
    } else {
        $notes += "命令行 $([int]((Get-Date) - $t0).TotalSeconds) 秒装好 $(@($r.data.components | Where-Object installed).Count) 样"
        foreach ($c in $r.data.components) {
            if (-not ($c.installed -and $c.downloaded)) { $problems += "命令行：$($c.id) 不是这次装好的" }
        }
        Test-Complete $cliRoot '命令行'
        Say "  $($notes[-1])"
    }

    # 2. 批处理：zip 用上一步留下的（或缓存的）
    $batRoot = Join-Path $Work 'bat'
    New-FetchRoot $batRoot
    $from = if ($Cache) { $Cache } else { Join-Path $cliRoot 'downloads' }
    $have = @($zips | Where-Object { Test-Path -LiteralPath (Join-Path $from $_) })
    if ($have.Count -eq $zips.Count) {
        New-Item -ItemType Directory -Force (Join-Path $batRoot 'downloads') | Out-Null
        foreach ($z in $zips) { Copy-Item -LiteralPath (Join-Path $from $z) -Destination (Join-Path $batRoot 'downloads') }
    } else {
        $notes += '批处理那遍要从网上下载（命令行那遍没留下 zip）'
    }
    $newBat = Test-Path -LiteralPath (Join-Path $batRoot 'tools\components-sources.txt')
    # 新的：下载源（回车 = 自动）、许可协议、pause；老的：许可协议、pause
    $answers = if ($newBat) { "`r`ny`r`n`r`n" } else { "y`r`n`r`n" }
    $inFile = Join-Path $Work 'bat-input.txt'
    [IO.File]::WriteAllText($inFile, $answers, [Text.Encoding]::ASCII)
    $batLog = Join-Path $Work 'bat-output.txt'
    Say "批处理：「补全组件.bat」（$(if ($newBat) { '调命令行的新版' } else { '调 PowerShell 脚本的老版' })）"
    $t0 = Get-Date
    $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList ('/d /c ""' + (Join-Path $batRoot '补全组件.bat') + '""') `
        -WorkingDirectory $batRoot -RedirectStandardInput $inFile -RedirectStandardOutput $batLog `
        -RedirectStandardError (Join-Path $Work 'bat-stderr.txt') -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(30 * 60 * 1000)) {
        # 只结束自己起的这个 cmd 和它的子进程
        & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        $problems += '批处理 30 分钟没结束，结束了它'
    } elseif ($p.ExitCode -ne 0) {
        $tail = @(Get-Content -LiteralPath $batLog -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '失败|原因|错误' } | Select-Object -Last 2) -join ' / '
        $problems += "批处理补全组件失败（退出码 $($p.ExitCode)）：$tail"
    } else {
        $notes += "批处理 $([int]((Get-Date) - $t0).TotalSeconds) 秒装好"
        Test-Complete $batRoot '批处理'
        if ($newBat) {
            $src = Join-Path $batRoot 'downloads\source.txt'
            $saved = if (Test-Path -LiteralPath $src) { (Get-Content -LiteralPath $src -Raw).Trim() } else { '' }
            if ($saved -ne 'auto') { $problems += "批处理：downloads\source.txt 是「$saved」，应当记成 auto" }
        }
    }
    if ($notes) { Say "  $($notes[-1])" }
} catch {
    $problems += "出错：$($_.Exception.Message)"
} finally {
    if ($made -and -not $Keep) {
        for ($k = 0; $k -lt 10 -and (Test-Path -LiteralPath $Work); $k++) {
            try { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction Stop } catch { Start-Sleep 2 }
        }
        if (Test-Path -LiteralPath $Work) { $problems += "收尾没删干净 $Work" } else { Say "删掉了 $Work" }
    }
}
$summary = $notes -join '；'
if ($problems) { $summary += "；问题：$($problems -join '；')" }
Result ($problems.Count -eq 0) $summary
exit 0
