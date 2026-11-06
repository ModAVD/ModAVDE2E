# 回归项：用组包目录新建实例，核对随包的宿主输入法（正式签名）开机自动装好、设为默认，跑通道 20 项，再核对开发签名换成正式签名。
# 在已有的测试根（本机配置 PackageRoot，没有就 TestRoot；E:\testbed 下的 flow-a / flow-b）上做，不新建根目录（11-05 用户定）：
# 先把组包目录装进这个根目录（按两边的包根清单换包，avd、logs、mas-avd.json 不动；组包目录原件不动），在里面建一台临时实例。
# 开关机一律用包里的 tools\modavd.exe（关机先正常关机、不成再 sync 后结束）。
#  a. modavd create 后第一次 modavd start（无头，和 AUTO-MAS 一样；首次初始化后自己装执行桥，中间关机再开机一两次）：
#     org.modavd.ime 装上了，base.apk 和包里 components\modavd-ime.apk 逐字节相同（也就是正式签名），已启用，
#     默认输入法是它，标记 /data/local/tmp/modavd-ime.autoselected 在；
#  b. 关机后带窗口开机（文字模式要窗口）：输入法一点没变、开机日志是「已是最新」；再用 ime-reg.ps1 -Attach 跑通道 20 项，
#     测试 APK 只在这一步装、跑完卸掉；
#  c. 换签名：卸掉 org.modavd.ime，装开发签名的同一个输入法（证书和正式的不同），启用、设为默认，标记留着；关机再开机：
#     应该换回正式签名的（base.apk 逐字节相同），默认是它，标记在。再关机开机一次：什么都不变（稳态）；
#     c 没换成正式签名时，稳态记成「在开发签名的那份上测的」，不算正式签名的稳态；
#  d. modavd stop，删掉这台临时实例（-Keep 留着）；测试根留着、停在这个包上。关机、删实例哪步不成都记进问题。
#     日志在 <Work>\logs-<时间>\，不删。开始前测试根下要没有在跑的模拟器，编号 -Index 要空着。
# 用法：pwsh -NoProfile -File items\ime-pkg.ps1 -Package <发版输出>\mas36\release\ModAVD-0.36.0-win-x64
# 没给的路径取本机配置（local.example.psd1）。
param(
    # 组包目录（release\ModAVD-<版本>-win-x64），只读
    [Parameter(Mandatory)][string]$Package,
    # 在哪个已有的测试根上测（本机配置 PackageRoot，没有就 TestRoot）。不能是生产根目录
    [string]$Root,
    # 日志目录的上一级（不是根目录）；默认 <TempRoot>\regress-ime-pkg
    [string]$Work,
    # 临时实例的编号，测试根里要空着
    [ValidateRange(0, 9)][int]$Index = 9,
    # 测试 APK（org.modavd.ime.testapp，ModAVDHostIME 编的，不随包发）和开发签名的同一个输入法
    # （ImeTestApk、DevImeApk）
    [string]$TestApk,
    [string]$DevImeApk,
    # Android SDK build-tools 36.1.0（apksigner 看证书；BuildTools）
    [string]$BuildTools,
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
[cultureinfo]::CurrentCulture = [cultureinfo]::InvariantCulture
. "$PSScriptRoot\common.ps1"
if (-not $Work) { $Work = Join-Path (Use-Local TempRoot $null '-Work') 'regress-ime-pkg' }
$Work = [IO.Path]::GetFullPath($Work)
Assert-NotProduction $Work '工作目录'
$rootArg = Use-Local PackageRoot $Root '' -Optional
if (-not $rootArg) { $rootArg = Use-Local TestRoot $null '' -Optional }
$Root = Resolve-TestRoot $rootArg '输入法回归用的测试根'
$rootCfg = Get-RootConfig $Root
$AdbPort = [int]$rootCfg.adbServerPort; $ScriptAdbPort = [int]$rootCfg.scriptAdbServerPort
$TestApk = Use-Local ImeTestApk $TestApk '-TestApk'
$DevImeApk = Use-Local DevImeApk $DevImeApk '-DevImeApk'
$BuildTools = Use-Local BuildTools $BuildTools '-BuildTools'
# 正式签名密钥的证书（ModAVD 的发布密钥；密钥一旦发出去就不能换）
$ReleaseCert = 'd18cca3c1982149349f164d28e02490b2eb694e44d56834fa02a1062eb42e823'
$ImeId = 'org.modavd.ime/.HostImeService'

$serial = ''   # 新建以后从 modavd 取
$runDir = Join-Path $Work "logs-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$cliExe = Join-Path $Root 'tools\modavd.exe'
$adbExe = Join-Path $Root 'sdk\platform-tools\adb.exe'
function Modavd { & $cliExe --root $Root @args 2>&1 | ForEach-Object { "$_" } }
function Adb { & $adbExe -P $AdbPort -s $serial @args 2>&1 | ForEach-Object { "$_" } }
function Log([string]$m) {
    $l = "$(Get-Date -Format 'HH:mm:ss') $m"
    if (Test-Path -LiteralPath $runDir) { Add-Content -LiteralPath (Join-Path $runDir 'ime-pkg.log') -Value $l -Encoding utf8 }
    Write-Host $l
}
# 推成文件再 sh（shell 用户就够），免得引号穿过 adb shell
function GuestSh([string]$Script) {
    $tmp = Join-Path $runDir "guest-$PID.sh"
    [IO.File]::WriteAllText($tmp, ($Script -replace "`r`n", "`n"))
    Adb push $tmp /data/local/tmp/ime-pkg.sh | Out-Null
    Remove-Item -LiteralPath $tmp -Force
    Adb shell 'sh /data/local/tmp/ime-pkg.sh; rm -f /data/local/tmp/ime-pkg.sh'
}
function CertOf([string]$Apk) {
    $hit = & (Join-Path $BuildTools 'apksigner.bat') verify --print-certs $Apk 2>&1 | ForEach-Object { "$_" } |
        Select-String -Pattern 'Signer #1 certificate SHA-256 digest: ([0-9a-f]{64})' | Select-Object -First 1
    if ($hit) { $hit.Matches[0].Groups[1].Value } else { '?' }
}
$stateScript = @'
p=$(pm path org.modavd.ime 2>/dev/null | head -n 1)
echo "path=${p#package:}"
echo "def=$(settings get secure default_input_method)"
if ime list -s 2>/dev/null | grep -qx 'org.modavd.ime/.HostImeService'; then echo enabled=1; else echo enabled=0; fi
if [ -e /data/local/tmp/modavd-ime.autoselected ]; then echo mark=1; else echo mark=0; fi
dumpsys package org.modavd.ime 2>/dev/null | grep -E 'versionCode=|firstInstallTime=|lastUpdateTime=' | head -n 3 | sed 's/^ *//; s/^/pkg=/'
'@
# 客体里输入法的现状；装着就把 base.apk 拉回来算 sha256、看证书
function Snapshot([string]$Tag) {
    $h = [ordered]@{ path = ''; def = ''; enabled = ''; mark = ''; versionCode = ''; firstInstallTime = ''; lastUpdateTime = ''; sha = ''; cert = '' }
    foreach ($l in (GuestSh $stateScript)) {
        if ($l -match '^(path|def|enabled|mark)=(.*)$') { $h[$matches[1]] = $matches[2].Trim() }
        elseif ($l -match '^pkg=(versionCode|firstInstallTime|lastUpdateTime)=(.*)$') { $h[$matches[1]] = $matches[2].Trim() }
    }
    if ($h.path) {
        $local = Join-Path $runDir "base-$Tag.apk"
        Adb pull $h.path $local | Out-Null
        if (Test-Path -LiteralPath $local) { $h.sha = (Get-FileHash -LiteralPath $local).Hash.ToLower(); $h.cert = CertOf $local }
    }
    $s = [pscustomobject]$h
    $s | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $runDir "state-$Tag.json") -Encoding utf8
    $s
}
function ShowState($s) { "base.apk sha256 $(if ($s.sha) { $s.sha.Substring(0, 12) } else { '-' })…（证书 $(if ($s.cert) { $s.cert.Substring(0, 8) } else { '-' })…），启用 $($s.enabled)，默认 $(if ($s.def) { $s.def } else { '没设' })，标记 $($s.mark)" }
# 正式签名的输入法就绪：没问题返回空
function ReadyProblems($s, [string]$WantSha) {
    $bad = @()
    if (-not $s.path) { $bad += 'org.modavd.ime 没装' }
    elseif ($s.sha -ne $WantSha) { $bad += "装着的 base.apk 和包里的不同（sha256 $($s.sha)，证书 $($s.cert)）" }
    if ($s.enabled -ne '1') { $bad += '没启用' }
    if ($s.def -ne $ImeId) { $bad += "默认输入法是 $(if ($s.def) { $s.def } else { '没设' })" }
    if ($s.mark -ne '1') { $bad += '没有标记' }
    $bad
}
$sameKeys = 'path', 'sha', 'def', 'enabled', 'mark', 'versionCode', 'firstInstallTime', 'lastUpdateTime'
function Changed($Before, $After) { @($sameKeys | Where-Object { "$($Before.$_)" -ne "$($After.$_)" } | ForEach-Object { "$_ $($Before.$_) -> $($After.$_)" }) }
# modavd start；输出存成 start-<tag>.txt，返回退出码、秒数和「宿主输入法」那几行
function Boot([string]$Tag, [switch]$Window) {
    $argv = @('start', "$Index") + @(if ($Window) { '--window' })
    $t0 = Get-Date
    $o = Modavd @argv
    $code = $LASTEXITCODE
    $o | Set-Content -LiteralPath (Join-Path $runDir "start-$Tag.txt") -Encoding utf8
    $ime = @($o | Where-Object { $_ -match '宿主输入法' } | ForEach-Object { ($_ -replace '^.*?(实例 \d+ 宿主输入法)', '$1').Trim() })
    [pscustomobject]@{ Code = $code; Sec = [int]((Get-Date) - $t0).TotalSeconds; Ime = $ime; Tail = (($o | Select-Object -Last 3) -join ' / ') }
}
function Halt([string]$Tag) {
    $o = Modavd stop $Index
    $code = $LASTEXITCODE
    $o | Set-Content -LiteralPath (Join-Path $runDir "stop-$Tag.txt") -Encoding utf8
    if ($code -ne 0) { throw "modavd stop 退出码 $code：$(($o | Select-Object -Last 2) -join ' / ')" }
    ($o | Select-Object -Last 1)
}
# 模拟器带窗口要等的进程、文件锁：根目录下还有进程（私有 adb server 除外）就等，最多 $Seconds 秒
function WaitRootIdle([int]$Seconds = 90) {
    $t0 = Get-Date
    $tools = Join-Path $Root 'sdk\platform-tools'
    while ($true) {
        $busy = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) -and
                -not $_.ExecutablePath.StartsWith($tools, [StringComparison]::OrdinalIgnoreCase) })
        if (-not $busy) { return $true }
        if (((Get-Date) - $t0).TotalSeconds -ge $Seconds) { Log "等了 $Seconds 秒，根目录下还有进程：$(($busy | ForEach-Object { "$($_.Name)($($_.ProcessId))" }) -join '、')"; return $false }
        Start-Sleep 2
    }
}

$problems = @(); $notes = @(); $made = $false; $created = $false; $swapped = $false
try {
    # ---- 前提：组包目录、两个 APK 的签名、端口
    # 测试根下不能有在跑的模拟器（别的会话可能正开着它的实例），临时实例的编号要空着
    if (-not (WaitRootIdle 5)) { throw "测试根 $Root 下还有模拟器在跑" }
    if ((Test-Path -LiteralPath (Join-Path $Root "avd\mas_$Index.avd")) -or ($rootCfg.instances.PSObject.Properties.Name -contains "$Index")) {
        throw "测试根 $Root 里已经有 $Index 号实例，换一个空着的 -Index"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Package 'sdk\emulator\emulator.exe'))) { throw "不是组包目录：$Package" }
    $pkgApk = Join-Path $Package 'components\modavd-ime.apk'
    foreach ($f in $pkgApk, (Join-Path $Package 'tools\modavd.exe'), $TestApk, $DevImeApk, (Join-Path $BuildTools 'apksigner.bat')) {
        if (-not (Test-Path -LiteralPath $f)) { throw "找不到 $f" }
    }
    foreach ($p in $AdbPort, $ScriptAdbPort) { Assert-NotProductionPort $p '测试根的 adb server 端口' }
    New-Item -ItemType Directory -Force $runDir | Out-Null
    $buildId = (Select-String -LiteralPath (Join-Path $Package 'sdk\emulator\source.properties') -Pattern '^Pkg\.BuildId=(.+)$').Matches[0].Groups[1].Value.Trim()
    $pkgSha = (Get-FileHash -LiteralPath $pkgApk).Hash.ToLower(); $pkgCert = CertOf $pkgApk
    $devSha = (Get-FileHash -LiteralPath $DevImeApk).Hash.ToLower(); $devCert = CertOf $DevImeApk
    Log "组包目录 $Package（$buildId）；modavd-ime.apk sha256 $pkgSha，证书 $pkgCert"
    Log "开发签名的 $DevImeApk sha256 $devSha，证书 $devCert；测试 APK $TestApk"
    if ($pkgCert -ne $ReleaseCert) { throw "包里的 modavd-ime.apk 不是正式签名（证书 $pkgCert）" }
    if ($devCert -eq '?' -or $devCert -eq $ReleaseCert -or $devSha -eq $pkgSha) { throw "$DevImeApk 不是另一把密钥签的（证书 $devCert）" }

    # ---- 测试根装上这个组包目录
    $made = $true
    $beforeVersion = (Get-Content -LiteralPath (Join-Path $Root 'modavd-manifest.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).version
    $removed = @(Install-Package $Package $Root)
    Log "测试根 $Root 装上 $Package（测之前是 $(if ($beforeVersion) { $beforeVersion } else { '没有清单' })；换包删掉 $($removed.Count) 个这个包没有的文件）"
    # 实例的端口按包里的 modavd 用的端口段算：新建时就要无头开一次机，开之前先看端口
    $base = Resolve-PortBase $Root $cliExe 0
    $consolePort = $base + 10 * $Index
    $mine = $consolePort..($consolePort + 2)
    foreach ($p in $AdbPort, $ScriptAdbPort) {
        if ($p -in $mine) { throw "adb server 端口 $p 和 $Index 号实例的控制台 / adb / gRPC 端口（$($mine -join '、')）撞了" }
    }
    # 测试根自己的 adb server 开着不算（前一项留下的，比如发版回归里先跑的 upgrade）；实例的端口、别的程序占着 adb 端口才停
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in (@($AdbPort, $ScriptAdbPort) + $mine) } |
        ForEach-Object { [pscustomobject]@{ LocalPort = [int]$_.LocalPort; Path = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Path } })
    $busyPorts = @(Get-PortConflicts $listeners $mine @($AdbPort, $ScriptAdbPort) $adbExe)
    if ($busyPorts) { throw "端口已被占用：$($busyPorts -join '、')（adb server 的端口只许测试根自己的 adb 占着）" }
    Log "根目录 $Root（adb server $AdbPort / $ScriptAdbPort，端口段 $base）"

    # ---- a. 新建、第一次开机
    $o = Modavd create --index $Index --title 输入法回归 --memory 4G --cpu 4 --data-gb 16
    if ($LASTEXITCODE -ne 0) { throw "新建失败：$($o -join ' ')" }
    $created = $true
    $serial = (Assert-InstancePorts $Index $base $Root $cliExe).Serial
    $b = Boot 'a-first'
    $b.Ime | ForEach-Object { Log "  a: $_" }
    if ($b.Code -ne 0) { throw "第一次开机失败（退出码 $($b.Code)）：$($b.Tail)" }
    $nb = ((Adb shell getprop ro.dalvik.vm.native.bridge) -join '').Trim()
    $sa = Snapshot 'a'
    Log "a: 第一次开机 $($b.Sec) 秒（native bridge $nb）；$(ShowState $sa)"
    $bad = @(ReadyProblems $sa $pkgSha)
    if ($bad) { $problems += "a 第一次开机后：$($bad -join '，')（$($b.Ime -join ' / ')）" }
    else { $notes += "a 第一次开机（$($b.Sec) 秒，含装桥）装上正式签名的输入法、已启用、设为默认、标记在" }

    # ---- b. 带窗口开机，通道 20 项
    Log "  $(Halt 'a')"
    $b = Boot 'b-window' -Window
    $b.Ime | ForEach-Object { Log "  b: $_" }
    if ($b.Code -ne 0) { throw "带窗口开机失败（退出码 $($b.Code)）：$($b.Tail)" }
    $sb = Snapshot 'b'
    $diff = Changed $sa $sb
    if ($diff -or -not ($b.Ime -match '已是最新')) { $problems += "b 再开机输入法变了：$($diff -join '；')（$($b.Ime -join ' / ')）" }
    $emuLog = Get-ChildItem -LiteralPath (Join-Path $Root 'logs') -File | Where-Object { $_.Name -match "^mas_$Index-\d{8}-\d{6}\.log$" } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $emuLog) { throw '找不到这次开机的模拟器日志' }
    $regOut = Join-Path $runDir 'ime-reg'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'ime-reg.ps1') -Attach -Sdk (Join-Path $Root 'sdk') -Out $regOut -AdbExe $adbExe `
        -AdbPort $AdbPort -Serial $serial -EmulatorLog $emuLog -TestApk $TestApk 2>&1 | ForEach-Object { Write-Host "  ime-reg: $_" }
    $regLog = @(Get-Content -LiteralPath (Join-Path $regOut 'ime-reg.log') -Encoding utf8 -ErrorAction SilentlyContinue)
    $sum = $regLog | Select-String -Pattern '汇总：PASS (\d+)，FAIL (\d+)' | Select-Object -Last 1
    $fails = @($regLog | Where-Object { $_ -match ' FAIL ' } | ForEach-Object { ($_ -replace '^\S+ FAIL ', '') })
    if ($sum -and [int]$sum.Matches[0].Groups[1].Value -eq 20 -and [int]$sum.Matches[0].Groups[2].Value -eq 0) { $notes += 'b 带窗口开机通道 PASS 20，FAIL 0' }
    else { $problems += "b 通道 $(if ($sum) { $sum.Matches[0].Value } else { '没有汇总行' })$(if ($fails) { "：$($fails -join '；')" })" }
    $left = ((Adb shell pm path org.modavd.ime.testapp) -join '').Trim()
    if ($left) { $problems += "测试 APK 没卸掉（$left）" }

    # ---- c. 开发签名换成正式签名
    $r = (Adb uninstall org.modavd.ime) -join ' '
    if ($r -notmatch '\bSuccess\b') { throw "卸载 org.modavd.ime 失败：$r" }
    $r = (Adb install $DevImeApk) -join ' '
    if ($r -notmatch '\bSuccess\b') { throw "装开发签名的输入法失败：$r" }
    GuestSh @'
i=0
while [ $i -lt 40 ]; do ime list -a -s | grep -qx 'org.modavd.ime/.HostImeService' && break; sleep 0.25; i=$((i+1)); done
ime enable org.modavd.ime/.HostImeService
ime set org.modavd.ime/.HostImeService
sync
'@ | ForEach-Object { Log "  c: $_" }
    $sd = Snapshot 'c-dev'
    Log "c: 换上开发签名的：$(ShowState $sd)"
    if ($sd.sha -ne $devSha -or $sd.def -ne $ImeId -or $sd.enabled -ne '1' -or $sd.mark -ne '1') { throw "开发签名的没摆好：$(ShowState $sd)" }
    Log "  $(Halt 'c-dev')"
    $b = Boot 'c-resign'
    $b.Ime | ForEach-Object { Log "  c: $_" }
    if ($b.Code -ne 0) { throw "换签名那次开机失败（退出码 $($b.Code)）：$($b.Tail)" }
    $sc = Snapshot 'c'
    Log "c: 开机后 $(ShowState $sc)"
    $bad = @(ReadyProblems $sc $pkgSha)
    $swapped = $bad.Count -eq 0
    if (-not $swapped) { $problems += "c 开发签名的开机后没换成正式签名：$($bad -join '，')（$($b.Ime -join ' / ')）" }
    else { $notes += "c 开发签名的开机后换回正式签名、默认和标记都在（$($b.Ime -join ' / '))" }

    # 稳态：再关机开机一次，什么都不变。c 没换成正式签名时测的是客体上留着的那份，照实写
    $on = if ($swapped) { '' } elseif ($sc.sha -eq $devSha) { '开发签名的那份上' } else { "没换成正式签名的状态上（$(ShowState $sc)）" }
    Log "  $(Halt 'c')"
    $b = Boot 'c-steady'
    $b.Ime | ForEach-Object { Log "  c2: $_" }
    if ($b.Code -ne 0) { throw "稳态那次开机失败（退出码 $($b.Code)）：$($b.Tail)" }
    $s2 = Snapshot 'c2'
    $diff = Changed $sc $s2
    if ($diff -or -not ($b.Ime -match '已是最新')) { $problems += "c 稳态开机又变了$(if ($on) { "（在${on}）" })：$($diff -join '；')（$($b.Ime -join ' / ')）" }
    elseif ($swapped) { $notes += '再开机一次什么都没变（已是最新）' }
    else { $notes += "再开机一次什么都没变（已是最新），但这是在${on}测的，不算正式签名的稳态" }
} catch {
    $problems += "出错（第 $($_.InvocationInfo.ScriptLineNumber) 行）：$($_.Exception.Message)"
    Log $problems[-1]
} finally {
    # 收尾哪步不成都记进问题：留下的实例、进程、目录会挡下一次
    if ($created) {
        try { Log "  $(Halt 'end')" } catch { $problems += "收尾关机失败：$($_.Exception.Message)"; Log $problems[-1] }
        if (-not $Keep) {
            $code = -1
            for ($k = 0; $k -lt 30; $k++) { $o = Modavd delete $Index --yes; $code = $LASTEXITCODE; if ($code -eq 0) { break }; Start-Sleep 2 }
            Log "  删实例：$(($o | Select-Object -Last 1))"
            if ($code -ne 0) { $problems += "收尾删实例试了 30 次都没成（退出码 $code）：$(($o | Select-Object -Last 1))"; Log $problems[-1] }
        }
    }
    # 测试根是共用的：它的 adb server 和根目录都留着，停在这个包上
    if ($made) {
        $nowVersion = (Get-Content -LiteralPath (Join-Path $Root 'modavd-manifest.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).version
        $notes += "测试根 $Root 现在是 $nowVersion（测之前 $(if ($beforeVersion) { $beforeVersion } else { '没有清单' })）；日志在 $runDir"
    }
}$summary = $notes -join '；'
if ($problems) { $summary += "；问题：$($problems -join '；')" }
Result ($problems.Count -eq 0) $summary
exit 0
