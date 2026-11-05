# 测试根的守卫（11-05）：回归只用已有的测试根（E:\testbed 下的 flow-a / flow-b），不新建根目录；生产根目录 D:\ModAVD 和
# 生产占着的 adb 端口 5037 / 20049 / 20050 一律拒绝（不再用「只许某个目录」的白名单）。不开模拟器、不连 adb。
#   pwsh -NoProfile -File tests/root-guards.ps1
$ErrorActionPreference = 'Stop'
$script:count = 0
function Check([bool]$ok, [string]$message) { $script:count++; if (-not $ok) { throw $message } }
function Throws([scriptblock]$Block) { try { & $Block | Out-Null } catch { return "$($_.Exception.Message)" }; return $null }

$work = Join-Path ([IO.Path]::GetTempPath()) "root-guards-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $work | Out-Null
$emptyConfig = Join-Path $work 'local.psd1'
Set-Content -LiteralPath $emptyConfig -Value '@{}' -Encoding utf8
$savedConfig = $env:MODAVD_E2E_CONFIG
$env:MODAVD_E2E_CONFIG = $emptyConfig
try {
    . (Join-Path $PSScriptRoot '..\items\common.ps1')

    # ---- 生产根目录：默认 D:\ModAVD，不分大小写，\ 和 / 都认，下面的目录也算
    foreach ($bad in 'D:\ModAVD', 'd:\modavd\avd\mas_1.avd', 'D:/ModAVD/tools', 'D:\ModAVD\') {
        $m = Throws { Assert-NotProduction $bad '测试根' }
        Check ($m -and $m -match '生产根目录') "生产根目录 $bad 应该被拒，得到：$m"
    }
    foreach ($ok in 'E:\testbed\flow-a', 'D:\ModAVD2', 'D:\Other\ModAVD', (Join-Path $work 'x')) {
        Check (-not (Throws { Assert-NotProduction $ok '测试根' })) "$ok 不是生产根目录，不该被拒"
    }
    # 本机配置 ProductionRoots 可以改
    Set-Content -LiteralPath $emptyConfig -Value "@{ ProductionRoots = @('F:\Prod') }" -Encoding utf8
    $script:ModAVDLocal = $null
    Check ([bool](Throws { Assert-NotProduction 'F:\Prod\x' '测试根' })) 'ProductionRoots 配的根目录要被拒'
    Check (-not (Throws { Assert-NotProduction 'D:\ModAVD' '测试根' })) '配了 ProductionRoots 就按配的'
    Set-Content -LiteralPath $emptyConfig -Value '@{}' -Encoding utf8
    $script:ModAVDLocal = $null

    # ---- 生产的 adb 端口
    foreach ($p in 5037, 20049, 20050) { Check ([bool](Throws { Assert-NotProductionPort $p 'adb' })) "端口 $p 应该被拒" }
    foreach ($p in 20089, 31099, 21099) { Check (-not (Throws { Assert-NotProductionPort $p 'adb' })) "端口 $p 不该被拒" }

    # ---- Resolve-TestRoot：只认已有的根目录
    $m = Throws { Resolve-TestRoot 'D:\ModAVD' }
    Check ($m -match '生产根目录') "传生产根目录要被拒：$m"
    $m = Throws { Resolve-TestRoot '' }
    Check ($m -match '没有测试根') "没给测试根要报：$m"
    $bare = Join-Path $work 'not-a-root'
    New-Item -ItemType Directory -Force $bare | Out-Null
    $m = Throws { Resolve-TestRoot $bare }
    Check ($m -match '不新建根目录') "没有 mas-avd.json 的目录不能当测试根（回归不新建根目录）：$m"
    $prodPorts = Join-Path $work 'prod-ports'
    New-Item -ItemType Directory -Force $prodPorts | Out-Null
    Set-Content -LiteralPath (Join-Path $prodPorts 'mas-avd.json') -Value '{"portBase": 31000, "adbServerPort": 20049, "scriptAdbServerPort": 31098}' -Encoding utf8
    $m = Throws { Resolve-TestRoot $prodPorts }
    Check ($m -match '20049') "测试根的 adb 端口是生产的 20049 要被拒：$m"
    $flow = Join-Path $work 'flow-x'
    New-Item -ItemType Directory -Force (Join-Path $flow 'avd') | Out-Null
    Set-Content -LiteralPath (Join-Path $flow 'mas-avd.json') -Value '{"portBase": 31000, "adbServerPort": 31099, "scriptAdbServerPort": 31098}' -Encoding utf8
    Check ((Resolve-TestRoot $flow) -eq [IO.Path]::GetFullPath($flow)) '已有的测试根应该原样返回完整路径'

    # ---- 换包：只删上一个包里有、新包里没有的文件，不碰实例和配置
    Check (@(Get-StalePackageFiles @('a', 'b', 'sub/c') @('a', 'sub/d')) -join ',' -eq 'b,sub/c') '要删的是旧清单有、新清单没有的'
    Check (@(Get-StalePackageFiles $null @('a')).Count -eq 0) '根目录没有清单时什么都不删'
    if ($IsWindows) {
        $pkgA = Join-Path $work 'pkg-a'; $pkgB = Join-Path $work 'pkg-b'
        foreach ($x in @(@($pkgA, @{ 'a.txt' = 'A1'; 'tools/old.ps1' = 'old' }), @($pkgB, @{ 'a.txt' = 'A2'; 'tools/new.ps1' = 'new' }))) {
            $files = [ordered]@{}
            foreach ($kv in $x[1].GetEnumerator()) {
                $p = Join-Path $x[0] $kv.Key; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
                Set-Content -LiteralPath $p -Value $kv.Value -Encoding utf8 -NoNewline
                $files[$kv.Key] = @{ size = 1; sha256 = 'x' }
            }
            @{ version = 'v0.0.1'; files = $files } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $x[0] 'modavd-manifest.json') -Encoding utf8
        }
        Set-Content -LiteralPath (Join-Path $flow 'avd\mas_1.ini') -Value 'keep' -Encoding utf8
        Install-Package $pkgA $flow | Out-Null
        Check (Test-Path (Join-Path $flow 'tools\old.ps1')) '装上旧包后 tools\old.ps1 在'
        $removed = @(Install-Package $pkgB $flow)
        Check (($removed -join ',') -eq 'tools/old.ps1') "换成新包要删掉旧包独有的 tools/old.ps1，实际删了：$($removed -join ',')"
        Check (-not (Test-Path (Join-Path $flow 'tools\old.ps1'))) '旧包独有的文件删掉了'
        Check ((Get-Content -LiteralPath (Join-Path $flow 'a.txt') -Raw) -eq 'A2') '两个包都有的文件换成新包的'
        Check (Test-Path (Join-Path $flow 'tools\new.ps1')) '新包的文件装上了'
        Check ((Test-Path (Join-Path $flow 'avd\mas_1.ini')) -and (Test-Path (Join-Path $flow 'mas-avd.json'))) '实例和 mas-avd.json 不动'
        $m = Throws { Install-Package $pkgA 'D:\ModAVD' }
        Check ($m -match '生产根目录') "不往生产根目录装包：$m"
    }

    # ---- 各项脚本拿生产根目录当测试根：一开始就停，什么都不做。
    # 绝不把真的生产根目录传给脚本：守卫要是坏了（变异检查就会故意弄坏），脚本会接着往下真去碰它。这里造一个假的
    # 「生产根目录」，用本机配置 ProductionRoots 指过去，里面放一份像样的 mas-avd.json。
    $fakeProd = Join-Path $work 'prod'
    New-Item -ItemType Directory -Force (Join-Path $fakeProd 'avd') | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeProd 'mas-avd.json') -Value '{"adbServerPort": 20049, "scriptAdbServerPort": 20050, "instances": {}}' -Encoding utf8
    Set-Content -LiteralPath $emptyConfig -Value "@{ ProductionRoots = @('$($fakeProd -replace "'", "''")') }" -Encoding utf8
    $env:MODAVD_REGRESS_MANAGER = $work
    $items = Join-Path $PSScriptRoot '..\items'
    $runs = @(
        @{ Name = 'upgrade'; Args = @('-File', (Join-Path $items 'upgrade.ps1'), '-Next', $work, '-Prev', $work, '-Root', $fakeProd, '-Work', (Join-Path $work 'up')) }
        @{ Name = 'ime-pkg'; Args = @('-File', (Join-Path $items 'ime-pkg.ps1'), '-Package', $work, '-Root', $fakeProd, '-Work', (Join-Path $work 'ime')) }
        @{ Name = 'created-disk-usage'; Args = @('-File', (Join-Path $items 'created-disk-usage.ps1'), '-Action', 'Create', '-Work', (Join-Path $work 'cdu'), '-Root', $fakeProd) }
        @{ Name = 'bridge'; Args = @('-File', (Join-Path $items 'bridge.ps1'), '-Sdk', $work, '-Root', $fakeProd) }
        @{ Name = 'datadisk'; Args = @('-File', (Join-Path $items 'datadisk.ps1'), '-Sdk', $work, '-Root', $fakeProd) }
        @{ Name = 'upgrade（新建根目录）'; Args = @('-File', (Join-Path $items 'upgrade.ps1'), '-Next', $work, '-Prev', $work, '-Root', $bare, '-Work', (Join-Path $work 'up2')) }
    )
    foreach ($r in $runs) {
        $out = (& pwsh -NoProfile @($r.Args) 2>&1 | ForEach-Object { "$_" }) -join "`n"
        # 只认守卫自己的报错（「测试根 … 在生产根目录 … 下」），别的地方碰巧带「生产」两个字的不算
        $want = if ($r.Name -like '*新建根目录*') { '不新建根目录' } else { '在生产根目录 .+ 下' }
        Check ($LASTEXITCODE -ne 0 -and $out -match $want) "$($r.Name) 拿 $($r.Args[-1]) 当测试根要停（$want），退出码 $LASTEXITCODE：$($out.Substring(0, [Math]::Min(300, $out.Length)))"
    }
    Check (-not (Test-Path (Join-Path $work 'up')) -and -not (Test-Path (Join-Path $work 'cdu'))) '被拒时没建工作目录'
    Write-Host "root guards: $script:count checks passed"
} finally {
    $env:MODAVD_E2E_CONFIG = $savedConfig
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
# 上面调过故意失败的子进程；CI 的 pwsh 步骤会把最后的 $LASTEXITCODE 当成退出码
exit 0
