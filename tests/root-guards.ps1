# 测试根的守卫（11-05）：回归只用已有的测试根（E:\testbed 下的 flow-a / flow-b），不新建根目录；生产根目录 D:\ModAVD 和
# 生产占着的 adb 端口 5037 / 20049 / 20050 一律拒绝；本机配置 ProductionRoots 在 D:\ModAVD 之外再加（用户自己用的根），
# TestRoots（可选）写了就只认列出来的测试根。不开模拟器、不连 adb。
#   pwsh -NoProfile -File tests/root-guards.ps1
#
# 这个测试绝不碰真的生产根目录，被测代码的守卫就算坏了（变异检查会故意弄坏）也一样：
#  - 「默认是 D:\ModAVD」只在最前面用字符串比一比（GetFullPath 只算字符串，不读盘），不把它交给任何会读写文件的函数；
#  - 其余凡是「生产根目录」都是临时目录里造的假根，用本机配置 ProductionRoots 指过去；
#  - 管理器、随包脚本指到临时目录里不存在的路径：没有任何真程序可跑（也不造假 exe，会在桌面弹窗）。
# 11-05 22:07 的教训：上一版把真的 D:\ModAVD 传给了脚本，变异检查去掉守卫时脚本跑了生产里的 modavd.exe list，
# 碰了生产 avd 下的 5 个锁文件。
$ErrorActionPreference = 'Stop'
$script:count = 0
function Check([bool]$ok, [string]$message) { $script:count++; if (-not $ok) { throw $message } }
function Throws([scriptblock]$Block) { try { & $Block | Out-Null } catch { return "$($_.Exception.Message)" }; return $null }
# 目录里的每个文件（路径、长度、修改时间、内容哈希）。不比目录本身的修改时间：刚写完文件时系统会稍后再刷新它
# 子进程的输出拼成一行：报错按控制台宽度折行，续行带「     | 」前缀，长路径会把「在生产根目录 … 下」拆到两行
# （折行处的空格会被吃掉，所以下面的正则写「在生产根目录\s*」）
function Join-Output($Lines) { ((@($Lines) | ForEach-Object { "$_" }) -join "`n") -replace '\r?\n\s*\|\s?', '' }
function Snapshot([string]$Dir) { (Get-ChildItem -LiteralPath $Dir -Recurse -Force -File | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" } | Sort-Object) -join "`n" }

$temp = [IO.Path]::GetTempPath()
$work = Join-Path $temp "root-guards-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $work | Out-Null
$config = Join-Path $work 'local.psd1'
Set-Content -LiteralPath $config -Value '@{}' -Encoding utf8
$saved = @{}
foreach ($k in 'MODAVD_E2E_CONFIG', 'MODAVD_REGRESS_MANAGER', 'MODAVD_REGRESS_PACKAGE') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
$env:MODAVD_E2E_CONFIG = $config
$env:MODAVD_REGRESS_MANAGER = Join-Path $work 'no-manager'
$env:MODAVD_REGRESS_PACKAGE = Join-Path $work 'no-package'
try {
    . (Join-Path $PSScriptRoot '..\items\common.ps1')

    # ---- 默认的生产根目录 D:\ModAVD：只比字符串。不分大小写，\ 和 / 都认，下面的目录也算
    foreach ($bad in 'D:\ModAVD', 'd:\modavd\avd\mas_1.avd', 'D:/ModAVD/tools', 'D:\ModAVD\') {
        $m = Throws { Assert-NotProduction $bad '测试根' }
        Check ($m -and $m -match '在生产根目录 .+ 下') "生产根目录 $bad 应该被拒，得到：$m"
    }
    foreach ($ok in 'E:\testbed\flow-a', 'D:\ModAVD2', 'D:\Other\ModAVD', (Join-Path $work 'x')) {
        Check (-not (Throws { Assert-NotProduction $ok '测试根' })) "$ok 不是生产根目录，不该被拒"
    }

    # ---- 从这里起「生产根目录」都是这个假根（临时目录里），用本机配置 ProductionRoots 指过去
    $fakeProd = Join-Path $work 'prod'
    if (-not $fakeProd.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw "假的生产根目录要在临时目录里：$fakeProd" }
    New-Item -ItemType Directory -Force (Join-Path $fakeProd 'avd') | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeProd 'mas-avd.json') -Value '{"adbServerPort": 20049, "scriptAdbServerPort": 20050, "instances": {}}' -Encoding utf8
    @{ version = 'v0.38.0'; files = @{ 'tools/modavd-bridge.ps1' = @{ size = 1; sha256 = 'x' } } } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $fakeProd 'modavd-manifest.json') -Encoding utf8
    New-Item -ItemType Directory -Force (Join-Path $fakeProd 'tools') | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeProd 'tools\modavd-bridge.ps1') -Value '# fake' -Encoding utf8
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $baseConfig = "@{ ProductionRoots = @($(& $q $fakeProd)) }"
    function Use-Config([string]$Text) { Set-Content -LiteralPath $config -Value $Text -Encoding utf8; $script:ModAVDLocal = $null }
    Use-Config $baseConfig
    $prodBefore = Snapshot $fakeProd
    Check ([bool](Throws { Assert-NotProduction (Join-Path $fakeProd 'x') '测试根' })) 'ProductionRoots 配的根目录要被拒'
    # ProductionRoots 是在 D:\ModAVD 之外再加，不是替换（11-06 审查：只写 fsync-user 时生产反而没人拦了）。只比字符串
    foreach ($bad in 'D:\ModAVD', 'd:/modavd/avd') {
        Check ([bool](Throws { Assert-NotProduction $bad '测试根' })) "配了 ProductionRoots 以后 $bad 照样被拒"
    }
    # 用户自己用的根（维护者机器上的 fsync-user）写进 ProductionRoots 就被拒；只写一个字符串、不写成数组也认
    $userRoot = Join-Path $work 'user-root'
    Use-Config "@{ ProductionRoots = @($(& $q $fakeProd), $(& $q $userRoot)) }"
    Check ([bool](Throws { Assert-NotProduction (Join-Path $userRoot 'avd') '测试根' })) 'ProductionRoots 列的用户的根要被拒'
    Check ([bool](Throws { Assert-NotProduction (Join-Path $fakeProd 'avd') '测试根' })) '列了两个时第一个照样被拒'
    Check ([bool](Throws { Assert-NotProduction 'D:\ModAVD' '测试根' })) '列了两个时 D:\ModAVD 照样被拒'
    Use-Config "@{ ProductionRoots = $(& $q $userRoot) }"
    Check ([bool](Throws { Assert-NotProduction $userRoot '测试根' })) 'ProductionRoots 写成一个字符串也认'
    Check ([bool](Throws { Assert-NotProduction 'D:\ModAVD\tools' '测试根' })) 'ProductionRoots 写成一个字符串时 D:\ModAVD 照样被拒'
    Use-Config $baseConfig

    # ---- 生产的 adb 端口
    foreach ($p in 5037, 20049, 20050) { Check ([bool](Throws { Assert-NotProductionPort $p 'adb' })) "端口 $p 应该被拒" }
    foreach ($p in 20089, 31099, 21099) { Check (-not (Throws { Assert-NotProductionPort $p 'adb' })) "端口 $p 不该被拒" }

    # ---- Resolve-TestRoot：只认已有的根目录
    $m = Throws { Resolve-TestRoot $fakeProd }
    Check ($m -match '在生产根目录 .+ 下') "传生产根目录要被拒：$m"
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
    # 两个 adb server 端口都要写（没写时管理器用生产的 20050 / 20049）
    foreach ($case in @(@('no-script-port', '{"portBase": 31000, "adbServerPort": 31099}', 'scriptAdbServerPort'),
            @('no-adb-port', '{"portBase": 31000, "scriptAdbServerPort": 31098}', 'adbServerPort'),
            @('zero-adb-port', '{"portBase": 31000, "adbServerPort": 0, "scriptAdbServerPort": 31098}', 'adbServerPort'))) {
        $r = Join-Path $work $case[0]
        New-Item -ItemType Directory -Force $r | Out-Null
        Set-Content -LiteralPath (Join-Path $r 'mas-avd.json') -Value $case[1] -Encoding utf8
        $m = Throws { Resolve-TestRoot $r }
        Check ($m -match "没写 $($case[2])") "测试根的 mas-avd.json 没写 $($case[2]) 要被拒：$m"
    }

    # ---- 换包：只删上一个包里有、新包里没有的文件，不碰实例和配置
    Check (@(Get-StalePackageFiles @('a', 'b', 'sub/c') @('a', 'sub/d')) -join ',' -eq 'b,sub/c') '要删的是旧清单有、新清单没有的'
    Check (@(Get-StalePackageFiles $null @('a')).Count -eq 0) '根目录没有清单时什么都不删'
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
    # 不往生产根目录装包（这一步在复制之前就停；robocopy 只在 Windows 上有，所以放在 Windows 判断外面，先测拒绝）
    $m = Throws { Install-Package $pkgA $fakeProd }
    Check ($m -match '在生产根目录 .+ 下') "不往生产根目录装包：$m"
    if ($IsWindows) {
        Set-Content -LiteralPath (Join-Path $flow 'avd\mas_1.ini') -Value 'keep' -Encoding utf8
        Install-Package $pkgA $flow | Out-Null
        Check (Test-Path (Join-Path $flow 'tools\old.ps1')) '装上旧包后 tools\old.ps1 在'
        $removed = @(Install-Package $pkgB $flow)
        Check (($removed -join ',') -eq 'tools/old.ps1') "换成新包要删掉旧包独有的 tools/old.ps1，实际删了：$($removed -join ',')"
        Check (-not (Test-Path (Join-Path $flow 'tools\old.ps1'))) '旧包独有的文件删掉了'
        Check ((Get-Content -LiteralPath (Join-Path $flow 'a.txt') -Raw) -eq 'A2') '两个包都有的文件换成新包的'
        Check (Test-Path (Join-Path $flow 'tools\new.ps1')) '新包的文件装上了'
        Check ((Test-Path (Join-Path $flow 'avd\mas_1.ini')) -and (Test-Path (Join-Path $flow 'mas-avd.json'))) '实例和 mas-avd.json 不动'
    }
    # 根目录的清单写错了（带 ..、绝对路径、列了实例 / 日志 / 配置）：一个文件都不删就停（在复制之前，所以不分平台）
    $badRoot = Join-Path $work 'bad-manifest'
    New-Item -ItemType Directory -Force (Join-Path $badRoot 'tools') | Out-Null
    Set-Content -LiteralPath (Join-Path $badRoot 'mas-avd.json') -Value '{"portBase": 31000, "adbServerPort": 31099, "scriptAdbServerPort": 31098}' -Encoding utf8
    foreach ($badRel in '../evil.txt', 'tools/../../evil.txt', '/abs/evil.txt', 'avd/mas_1.avd/config.ini', 'AVD\mas_1.ini', 'logs/x.log', 'mas-avd.json', 'Mas-Avd.json') {
        Set-Content -LiteralPath (Join-Path $badRoot 'tools\stale.ps1') -Value 'stale' -Encoding utf8
        $list = [ordered]@{ 'tools/stale.ps1' = @{ size = 1; sha256 = 'x' }; $badRel = @{ size = 1; sha256 = 'x' } }
        @{ version = 'v0.0.0'; files = $list } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $badRoot 'modavd-manifest.json') -Encoding utf8
        $m = Throws { Install-Package $pkgA $badRoot }
        Check ($m -match '清单里的路径不对|清单里列了实例、日志或配置') "根目录清单里有 $badRel 时要停：$m"
        Check (Test-Path (Join-Path $badRoot 'tools\stale.ps1')) "根目录清单里有 $badRel 时一个文件都不该删"
    }
    # 测试根白名单（本机配置 TestRoots，可选）：列了就只认列出来的根目录本身
    $other = Join-Path $work 'flow-y'
    New-Item -ItemType Directory -Force $other | Out-Null
    Set-Content -LiteralPath (Join-Path $other 'mas-avd.json') -Value '{"portBase": 31100, "adbServerPort": 31199, "scriptAdbServerPort": 31198}' -Encoding utf8
    Check ((Resolve-TestRoot $other) -eq [IO.Path]::GetFullPath($other)) '没配 TestRoots 时已有的根都认'
    Use-Config "@{ ProductionRoots = @($(& $q $fakeProd)); TestRoots = @($(& $q $flow)) }"
    Check ((Resolve-TestRoot $flow) -eq [IO.Path]::GetFullPath($flow)) 'TestRoots 列了的根照常'
    Check (-not (Throws { Resolve-TestRoot "$flow/" })) 'TestRoots 列了的根带个分隔符也认'
    $m = Throws { Resolve-TestRoot $other }
    Check ($m -match 'TestRoots') "TestRoots 没列的根要被拒：$m"
    $m = Throws { Resolve-TestRoot (Join-Path $flow 'avd') }
    Check ($m -match 'TestRoots') "TestRoots 列的根下面的目录也不算：$m"
    $m = Throws { Install-Package $pkgA $other }
    Check ($m -match 'TestRoots') "不往 TestRoots 没列的根装包：$m"
    Use-Config "@{ ProductionRoots = @($(& $q $fakeProd)); TestRoots = $(& $q $flow) }"
    Check ((Throws { Resolve-TestRoot $other }) -match 'TestRoots') 'TestRoots 写成一个字符串也认'
    Use-Config $baseConfig

    # ---- 各项脚本拿（假的）生产根目录当测试根：一开始就停，什么都不做
    $items = Join-Path $PSScriptRoot '..\items'
    $runs = @(
        @{ Name = 'upgrade'; Args = @('-File', (Join-Path $items 'upgrade.ps1'), '-Next', $pkgB, '-Prev', $pkgA, '-Root', $fakeProd, '-Work', (Join-Path $work 'up')) }
        @{ Name = 'ime-pkg'; Args = @('-File', (Join-Path $items 'ime-pkg.ps1'), '-Package', $pkgB, '-Root', $fakeProd, '-Work', (Join-Path $work 'ime')) }
        @{ Name = 'created-disk-usage'; Args = @('-File', (Join-Path $items 'created-disk-usage.ps1'), '-Action', 'Create', '-Work', (Join-Path $work 'cdu'), '-Root', $fakeProd) }
        @{ Name = 'bridge'; Args = @('-File', (Join-Path $items 'bridge.ps1'), '-Sdk', $work, '-Root', $fakeProd) }
        @{ Name = 'datadisk'; Args = @('-File', (Join-Path $items 'datadisk.ps1'), '-Sdk', $work, '-Root', $fakeProd) }
        @{ Name = 'bridge-default'; Args = @('-File', (Join-Path $items 'bridge-default.ps1'), '-Sdk', $work, '-Root', $fakeProd) }
        @{ Name = 'yys'; Args = @('-File', (Join-Path $items 'yys.ps1'), '-Sdk', $work, '-Out', (Join-Path $work 'yys-out'), '-Root', $fakeProd) }
        @{ Name = 'upgrade（新建根目录）'; Args = @('-File', (Join-Path $items 'upgrade.ps1'), '-Next', $pkgB, '-Prev', $pkgA, '-Root', $bare, '-Work', (Join-Path $work 'up2')) }
        # 测试根是好的，工作目录 / 输出目录落在生产根目录下
        @{ Name = 'upgrade（-Work 在生产根目录下）'; Args = @('-File', (Join-Path $items 'upgrade.ps1'), '-Next', $pkgB, '-Prev', $pkgA, '-Root', $flow, '-Work', (Join-Path $fakeProd 'up')) }
        @{ Name = 'ime-pkg（-Work 在生产根目录下）'; Args = @('-File', (Join-Path $items 'ime-pkg.ps1'), '-Package', $pkgB, '-Root', $flow, '-Work', (Join-Path $fakeProd 'ime')) }
        @{ Name = 'fetch（-Work 在生产根目录下）'; Args = @('-File', (Join-Path $items 'fetch.ps1'), '-Package', $pkgB, '-Work', (Join-Path $fakeProd 'fetch')) }
        @{ Name = 'created-disk-usage（-Work 在生产根目录下）'; Args = @('-File', (Join-Path $items 'created-disk-usage.ps1'), '-Action', 'Create', '-Root', $flow, '-Work', (Join-Path $fakeProd 'cdu')) }
        @{ Name = 'ime-reg（-Out 在生产根目录下）'; Args = @('-File', (Join-Path $items 'ime-reg.ps1'), '-Sdk', $work, '-Out', (Join-Path $fakeProd 'ime-reg')) }
    )
    foreach ($r in $runs) {
        $out = Join-Output (& pwsh -NoProfile @($r.Args) 2>&1)
        # 只认守卫自己的报错（「… 在生产根目录 … 下」），别的地方碰巧带「生产」两个字的不算
        $want = if ($r.Name -like '*新建根目录*') { '不新建根目录' } else { '在生产根目录\s*.+下' }
        Check ($LASTEXITCODE -ne 0 -and $out -match $want) "$($r.Name) 拿 $($r.Args[-1]) 要停（$want），退出码 $LASTEXITCODE：$($out.Substring(0, [Math]::Min(300, $out.Length)))"
    }
    Check (-not (Test-Path (Join-Path $work 'up')) -and -not (Test-Path (Join-Path $work 'cdu')) -and -not (Test-Path (Join-Path $work 'yys-out'))) '被拒时没建工作目录'
    foreach ($d in 'up', 'ime', 'fetch', 'cdu', 'ime-reg') { Check (-not (Test-Path (Join-Path $fakeProd $d))) "被拒时没在生产根目录下建 $d" }

    # ime-reg 绕过管理器用启动器开机：实例目录（ImeAvdHome）在生产根目录下就停，不建输出目录
    $imeConfig = Join-Path $work 'ime.psd1'
    Set-Content -LiteralPath $imeConfig -Encoding utf8 -Value "@{ ProductionRoots = @($(& $q $fakeProd)); ImeAvdHome = $(& $q (Join-Path $fakeProd 'avd')); Launcher = $(& $q (Join-Path $work 'missing\Launcher')) }"
    $env:MODAVD_E2E_CONFIG = $imeConfig
    $imeOut = Join-Path $work 'ime-reg-out'
    $out = Join-Output (& pwsh -NoProfile -File (Join-Path $items 'ime-reg.ps1') -Sdk $work -Out $imeOut 2>&1)
    $env:MODAVD_E2E_CONFIG = $config
    Check ($LASTEXITCODE -ne 0 -and $out -match 'ImeAvdHome.*在生产根目录\s*.+下') "ime-reg 的 ImeAvdHome 在生产根目录下要停，退出码 $LASTEXITCODE：$($out.Substring(0, [Math]::Min(300, $out.Length)))"
    Check (-not (Test-Path $imeOut)) 'ime-reg 被拒时没建输出目录'

    # ---- game-real 绕过管理器用启动器开机：实例目录（GameAvdHome）在生产根目录下就停；GameAvds 的实例名要像个名字
    # 仓库外的东西都指到不存在的路径，没有真程序可跑
    $missing = Join-Path $work 'missing'
    $quote = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $externals = (('Launcher', 'Monitor', 'VulkanFixLib', 'PackageScripts', 'Kit') | ForEach-Object { "$_ = $(& $quote (Join-Path $missing $_))" }) -join '; '
    $gameRuns = @(
        @{ Name = 'game-real（实例目录在生产根目录下）'; Home = (Join-Path $fakeProd 'avd'); Avds = "@{ r1999 = 'mas_1' }"; Want = '在生产根目录\s*.+下' }
        @{ Name = 'game-real（GameAvds 的实例名带路径）'; Home = (Join-Path $work 'game-avd'); Avds = "@{ r1999 = '..\mas_1' }"; Want = 'GameAvds 里 r1999 的实例名不对' }
    )
    foreach ($g in $gameRuns) {
        $gameConfig = Join-Path $work 'game.psd1'
        Set-Content -LiteralPath $gameConfig -Encoding utf8 -Value "@{ ProductionRoots = @($(& $quote $fakeProd)); GameAvdHome = $(& $quote $g.Home); GameAvds = $($g.Avds); $externals }"
        $env:MODAVD_E2E_CONFIG = $gameConfig
        $gameOut = Join-Path $work 'game-out'
        $out = Join-Output (& pwsh -NoProfile -File (Join-Path $items 'game-real.ps1') -Game r1999 -Sdk $missing -Out $gameOut 2>&1)
        $env:MODAVD_E2E_CONFIG = $config
        Check ($LASTEXITCODE -ne 0 -and $out -match $g.Want) "$($g.Name) 要停（$($g.Want)），退出码 $LASTEXITCODE：$($out.Substring(0, [Math]::Min(300, $out.Length)))"
        Check (-not (Test-Path $gameOut)) "$($g.Name)：被拒时没建输出目录"
    }
    # 被拒的这一路上，（假的）生产根目录一个文件都没变
    Check ((Snapshot $fakeProd) -eq $prodBefore) '生产根目录里的文件被动过了'
    Write-Host "root guards: $script:count checks passed"
} finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
# 上面调过故意失败的子进程；CI 的 pwsh 步骤会把最后的 $LASTEXITCODE 当成退出码
exit 0
