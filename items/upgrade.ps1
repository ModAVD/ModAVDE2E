# 回归项：从上一个发布版升级。
# 在已有的测试根（本机配置 PackageRoot，没有就 TestRoot；E:\testbed 下的 flow-a / flow-b）上做，不新建根目录（11-05 用户定）：
# 先把这个根目录装回上一版（按两边的包根清单换包，avd、logs、mas-avd.json 不动），用旧模拟器新建一台临时实例、开机、
# 写标记数据、关机。开关机用新编的 modavd（AUTO-MAS 开关机流程的移植；早年的旧包里没有 modavd）。再照「怎么更新」把新包
# 整个覆盖上去（avd 不动），然后核对：
#  - 组包目录按包根清单的版本号是否上升判，缺清单时按构建号判；SDK 构建号相同只记说明。包根的 ModAVD.exe / tools\modavd.exe / tools\modavd-bridge.ps1 都在
#  - 用包里的 tools\modavd.exe 开机，标记数据都在
#  - 旧模拟器建的 64 GB 盘：新包的 modavd 有「自动扩盘」（0.8.0 起）时，升级后已经扩到 256 GB；
#    没有时 set --data-gb 改大到 80 GB 后开机扩满
#  - 升级后第一次用 modavd（管理器同一套）照常开机，旧实例自己装上执行桥（10-30 起用户不用自己装）。
#    旧版建的实例没有开机标记、mas-avd.json 里也没有 bridge 一项：新建后删掉标记来模拟。升级前和查数据、扩盘那几次
#    开机带 --no-bridge（旧模拟器不认标记，也不让装桥打乱前面的核对）。
#  - 新包是组包目录、带 components\modavd-ime.apk 时（0.36.0 起），宿主输入法跟着包过来：包根的 APK 和新包的一样，
#    客体装上的 org.modavd.ime 的 base.apk 与它逐字节相同（正式签名的那份），默认输入法是它，「已决定默认」的标记写了。
#    还记下升级前客体有没有它：上一版早于 0.36.0 时旧根目录没有这个 APK，升级前那次开机 modavd 不装，升级后有了才说明是
#    跟着新包来的；上一版是 0.36.0 及以后时，升级前那次开机已经装上旧包那份，这条记录只作参考。
#    -Next 是 SDK 目录时没有 components，不查。
# 跑完删掉这台临时实例（-Keep 留着），测试根留着、停在新包上（结论里写它测之前、测之后各是哪一版）。收尾的关机、删实例，
# 哪步不成都记进问题。开始前测试根下要没有在跑的模拟器，编号 -Index 要空着。
param(
    # 新包的组包目录（release\ModAVD-<版本>-win-x64）；或者 SDK 根目录（有 emulator\），这时包根文件取 -ModavdOut
    # 和随包脚本目录（common.ps1）
    [Parameter(Mandatory)][string]$Next,
    # 上一版的组包目录：只测生产现在跑的那一版（本机配置 PrevPackage）
    [string]$Prev,
    # 放着 tools\modavd.exe 和 ModAVD.exe 的目录；默认取 common.ps1 的管理器目录（环境变量 MODAVD_REGRESS_MANAGER）
    [string]$ModavdOut,
    # 在哪个已有的测试根上测（本机配置 PackageRoot，没有就 TestRoot）。不能是生产根目录
    [string]$Root,
    # 临时文件（新 modavd 的副本、单用的 netsim 发现目录、推进客体的脚本），跑完删；默认 <TempRoot>\regress-upgrade。不是根目录
    [string]$Work,
    # 临时实例的编号，测试根里要空着
    [ValidateRange(0, 9)][int]$Index = 8,
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
[cultureinfo]::CurrentCulture = [cultureinfo]::InvariantCulture
. "$PSScriptRoot\common.ps1"
$Prev = Use-Local PrevPackage $Prev '-Prev'
if (-not $ModavdOut) { $ModavdOut = Get-ManagerDir }
if (-not $Work) { $Work = Join-Path (Use-Local TempRoot $null '-Work') 'regress-upgrade' }
$Work = [IO.Path]::GetFullPath($Work)
Assert-NotProduction $Work '工作目录'
$rootArg = Use-Local PackageRoot $Root '' -Optional
if (-not $rootArg) { $rootArg = Use-Local TestRoot $null '' -Optional }
$Root = Resolve-TestRoot $rootArg '升级用的测试根'
$serial = ''   # 新建以后从 modavd 取
$script:CliExe = Join-Path $Work 'cli\modavd.exe'
function Modavd { & $script:CliExe --root $Root @args 2>&1 | ForEach-Object { "$_" } }
function Adb { & (Join-Path $Root 'sdk\platform-tools\adb.exe') -P $AdbPort -s $serial @args 2>&1 | ForEach-Object { "$_" } }
# 临时脚本写在 $Work 下，不放系统临时目录；$Work 由搭根目录那步建好，跑完整个删掉
function SuRun([string]$Script) {
    $tmp = Join-Path $Work "regress-up-$PID.sh"
    [IO.File]::WriteAllText($tmp, ($Script -replace "`r`n", "`n"))
    Adb push $tmp /data/local/tmp/regress.sh | Out-Null
    Remove-Item -LiteralPath $tmp -Force
    Adb shell 'su 0 sh /data/local/tmp/regress.sh; rm -f /data/local/tmp/regress.sh'
}
function BuildId([string]$sdkEmu) { (Select-String -LiteralPath (Join-Path $sdkEmu 'source.properties') -Pattern '^Pkg\.BuildId=(.+)$').Matches[0].Groups[1].Value.Trim() }
function PackageVersion([string]$Package) {
    $manifest = Join-Path $Package 'modavd-manifest.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    try {
        $text = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).version
        if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text)) { throw 'version 必须是非空字符串' }
        [pscustomobject]@{ Text = $text; Value = [semver]($text -creplace '^v', '') }
    } catch { throw "包清单版本无效（${manifest}）：$($_.Exception.Message)" }
}
function Overlay([string]$from, [string]$to) {
    & robocopy $from $to /E /COPY:DAT /R:5 /W:2 /NFL /NDL /NP /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $from -> $to 失败（$LASTEXITCODE）" }
}
# 关机后模拟器的附属进程（crashpad_handler、netsimd 等）可能还从 sdk\emulator 跑着、占着文件：覆盖前等它们退出。
# 根目录自己的 adb server（sdk\platform-tools）一直开着，包里没有 platform-tools、覆盖碰不到它，不等。
function WaitRootIdle([int]$seconds = 90) {
    $t0 = Get-Date
    $tools = Join-Path $Root 'sdk\platform-tools'
    while ($true) {
        $busy = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) -and
                -not $_.ExecutablePath.StartsWith($tools, [StringComparison]::OrdinalIgnoreCase) })
        if (-not $busy) { return }
        if (((Get-Date) - $t0).TotalSeconds -ge $seconds) { throw "等了 $seconds 秒，根目录下还有进程在跑：$(($busy | ForEach-Object { "$($_.Name)($($_.ProcessId))" }) -join '、')" }
        Start-Sleep 2
    }
}

$problems = @(); $notes = @(); $created = $false; $made = $false
$tag = "upgrade-$(Get-Date -Format 'yyyyMMddHHmmss')"
$AdbPort = [int](Get-RootConfig $Root).adbServerPort
try {
    if (Test-Path -LiteralPath $Work) { throw "$Work 已存在（上次留下的？删掉或换 -Work）" }
    if (-not (Test-Path (Join-Path $Prev 'sdk\emulator\emulator.exe'))) { throw "上一版的组包目录不对：$Prev" }
    Assert-NotProductionPort $AdbPort '测试根的 adbServerPort'
    # 测试根下不能有在跑的模拟器（别的会话可能正开着它的实例），临时实例的编号要空着
    WaitRootIdle 5
    if ((Test-Path -LiteralPath (Join-Path $Root "avd\mas_$Index.avd")) -or ((Get-RootConfig $Root).instances.PSObject.Properties.Name -contains "$Index")) {
        throw "测试根 $Root 里已经有 $Index 号实例，换一个空着的 -Index"
    }
    $nextIsTree = Test-Path (Join-Path $Next 'sdk\emulator\emulator.exe')
    if (-not $nextIsTree -and -not (Test-Path (Join-Path $Next 'emulator\emulator.exe'))) { throw "新包既不是组包目录也不是 SDK：$Next" }
    $nextHasManifest = $nextIsTree -and (Test-Path -LiteralPath (Join-Path $Next 'modavd-manifest.json'))
    $newCli = if ($nextIsTree) { Join-Path $Next 'tools\modavd.exe' } else { Join-Path $ModavdOut 'tools\modavd.exe' }
    if (-not (Test-Path $newCli)) { throw "找不到新的 modavd.exe：$newCli" }
    $imeApk = if ($nextIsTree) { Join-Path $Next 'components\modavd-ime.apk' } else { '' }
    $checkIme = $imeApk -and (Test-Path -LiteralPath $imeApk)
    $imeSkip = if (-not $nextIsTree) { '新包是 SDK 目录、没有 components，不查宿主输入法' } elseif (-not $checkIme) { '新包里没有 components\modavd-ime.apk，不查宿主输入法' }

    # ---- 测试根装回上一版
    New-Item -ItemType Directory -Path $Work | Out-Null
    $made = $true
    $beforeVersion = PackageVersion $Root
    # 模拟器按发现目录里的 netsim.ini 找 netsimd（模拟器和 netsimd 都先认 TMPDIR，没设时是 %LOCALAPPDATA%\Temp），
    # 同一用户的模拟器不管来自哪个 SDK 都共用一个。10-30 并行跑别的测试时，别处的模拟器连上了这个根目录起的 netsimd，
    # 这边关机后它一直不退，覆盖前和收尾都等不到。这里的模拟器单用一个发现目录：别人连不上它的，它也不去连别人的
    $netsimDir = Join-Path $Work 'netsim'
    New-Item -ItemType Directory -Force $netsimDir | Out-Null
    $env:TMPDIR = $netsimDir
    $removed = @(Install-Package $Prev $Root)
    New-Item -ItemType Directory -Force (Split-Path $script:CliExe) | Out-Null
    Copy-Item -LiteralPath $newCli -Destination $script:CliExe
    $oldId = BuildId (Join-Path $Root 'sdk\emulator')
    $oldVersion = PackageVersion $Root
    $base = Resolve-PortBase $Root $script:CliExe 0
    Say "测试根 $Root 装回上一版：$(if ($oldVersion) { $oldVersion.Text } else { $oldId })（测之前是 $(if ($beforeVersion) { $beforeVersion.Text } else { '没有清单' })；换包删掉 $($removed.Count) 个上一版没有的文件；端口段 $base）"

    $o = Modavd create --index $Index --title 升级测试 --memory 4G --cpu 4
    if ($LASTEXITCODE -ne 0) { throw "旧版里新建失败：$($o -join ' ')" }
    $created = $true
    $serial = (Assert-InstancePorts $Index $base $Root $script:CliExe).Serial
    Remove-Item -LiteralPath (Join-Path $Root "avd\mas_$Index.avd\modavd-writable-system") -ErrorAction SilentlyContinue   # 旧版建的没有
    Modavd start $Index --no-bridge | Select-Object -Last 1 | ForEach-Object { Say "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "旧版开机失败（退出码 $LASTEXITCODE）" }
    # /sdcard 要等 sys.boot_completed 之后才开始挂（emulated;0，正常约 2 秒，宿主忙时更久），modavd start 和 AUTO-MAS 一样
    # 只等到 sys.boot_completed，返回时不一定挂好。
    # 没挂上时写进去的只落在 /storage 的 tmpfs 里，挂上后被盖住、关机就没了（10-30 并行跑时标记丢过一次）：
    # 写完核对 /data/media/0 里那份，不对就隔一秒重写，最多 90 秒
    $w = SuRun (@'
echo @TAG@ > /data/local/tmp/upgrade-marker
i=0
while [ $i -lt 90 ]; do
  mkdir -p /sdcard/Download 2>/dev/null && echo @TAG@ > /sdcard/Download/upgrade-marker.txt 2>/dev/null
  sync
  [ "$(cat /data/media/0/Download/upgrade-marker.txt 2>/dev/null)" = @TAG@ ] && break
  sleep 1; i=$((i+1))
done
echo "sdwait=$i"
'@).Replace('@TAG@', $tag)
    $sdWait = -1
    foreach ($l in $w) { if ("$l".Trim() -match '^sdwait=(\d+)$') { $sdWait = [int]$Matches[1] } }
    if ($sdWait -lt 0 -or $sdWait -ge 90) { throw "升级前写 /sdcard 的标记没落到 /data/media/0：$($w -join ' / ')" }
    if ($sdWait -gt 0) { $notes += "升级前开机后 /sdcard 等了约 $sdWait 秒才挂好" }
    if ($checkIme) {
        # 上一版早于 0.36.0 时旧根目录没有 components\modavd-ime.apk，这时客体应该还没有它：升级后有了，才说明是跟着新包来的。
        # 上一版是 0.36.0 及以后时，这次开机 modavd 已经装上了旧包那份，这条只作参考
        $prevIme = Test-Path -LiteralPath (Join-Path $Root 'components\modavd-ime.apk')
        $pre = (SuRun 'pm path org.modavd.ime 2>/dev/null' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
        $preNote = if ($pre) { "升级前客体已有 org.modavd.ime（$pre）" } else { '升级前客体没有 org.modavd.ime' }
        if ($prevIme) { $preNote += '（上一版包里就带 components\modavd-ime.apk，只作参考）' }
        $notes += $preNote
    }
    Modavd stop $Index | Select-Object -Last 1 | ForEach-Object { Say "  $_" }

    # ---- 照「怎么更新」：关掉所有实例，新包整个覆盖上去
    $t1 = Get-Date
    WaitRootIdle
    Say ("关机后等根目录下的进程退出用了 {0:N0} 秒" -f ((Get-Date) - $t1).TotalSeconds)
    if ($nextIsTree) { Install-Package $Next $Root | Out-Null }
    else {
        Overlay (Join-Path $Next 'emulator') (Join-Path $Root 'sdk\emulator')
        Copy-Item -LiteralPath (Join-Path $ModavdOut 'tools\modavd.exe') -Destination (Join-Path $Root 'tools\modavd.exe') -Force
        Copy-Item -LiteralPath (Join-Path $ModavdOut 'ModAVD.exe') -Destination (Join-Path $Root 'ModAVD.exe') -Force
        Copy-Item -LiteralPath (Join-Path (Get-PackageScripts) 'modavd-bridge.ps1') -Destination (Join-Path $Root 'tools\modavd-bridge.ps1') -Force
    }
    $newId = BuildId (Join-Path $Root 'sdk\emulator')
    $missing = @('ModAVD.exe', 'tools\modavd.exe', 'tools\modavd-bridge.ps1') | Where-Object { -not (Test-Path (Join-Path $Root $_)) }
    if ($missing) { $problems += "覆盖后缺：$($missing -join '、')" }
    # SDK 覆盖和不带清单的旧包会留下原清单，不能把它当成新包的版本。
    $newVersion = if ($nextHasManifest) { PackageVersion $Root } else { $null }
    if ($nextHasManifest -and -not $newVersion) { throw '覆盖后缺 modavd-manifest.json' }
    if (-not $nextIsTree) {
        if ($newId -eq $oldId) { $notes += 'SDK 模式，构建号没变，补丁版只换管理器时正常' }
    } elseif ($oldVersion -and $newVersion) {
        $notes += "清单版本 $($oldVersion.Text) -> $($newVersion.Text)"
        if ($newVersion.Value -le $oldVersion.Value) { $problems += "覆盖后清单版本没有上升：$($oldVersion.Text) -> $($newVersion.Text)" }
    } else {
        $notes += '缺包清单，按构建号判定'
        if ($newId -eq $oldId) { $problems += "覆盖后构建号还是 $oldId" }
    }
    $notes += "构建号 $oldId -> $newId"
    $script:CliExe = Join-Path $Root 'tools\modavd.exe'

    # ---- 升级后（modavd 自己的宿主输入法那行日志留下来，看是哪次开机装上的）
    $o = Modavd start $Index --no-bridge; $o | Select-Object -Last 1 | ForEach-Object { Say "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "升级后开机失败（退出码 $LASTEXITCODE）" }
    $o | Where-Object { $_ -match '宿主输入法' } | ForEach-Object { Say "  升级后第一次开机：$_" }
    # 读 /sdcard 也一样要等它挂上（最多 60 秒）；最后一行带上 /data/media/0 里那份，丢了时分得清是没挂上还是真没了
    $m = SuRun (@'
cat /data/local/tmp/upgrade-marker
i=0
while [ $i -lt 60 ] && [ "$(cat /sdcard/Download/upgrade-marker.txt 2>/dev/null)" != @TAG@ ]; do sleep 1; i=$((i+1)); done
cat /sdcard/Download/upgrade-marker.txt
echo "sdwait=$i lower=$(cat /data/media/0/Download/upgrade-marker.txt 2>&1)"
'@).Replace('@TAG@', $tag)
    if (@($m | Where-Object { $_.Trim() -eq $tag }).Count -ne 2) { $problems += "标记数据不对：$($m -join ' / ')" } else { $notes += '旧实例照常开机、数据都在' }

    # 管理器 0.8.0 起（ModAVDManager#132，ModAVD/ModAVD#153）数据盘分「自动扩盘 / 指定大小」：没写模式的旧实例算自动扩盘，
    # 下次开机前就扩到 256 GB（这一项升级前后都用新包的 modavd 开机，所以多半在升级前那次就扩了），这时再改成 80 GB
    # 会被拒（只能改大），所以改为核对升级后已经扩满。
    # 新包的 modavd 还没有这两种模式（info 里没有 data_disk_mode）时照旧 set --data-gb 80。
    $info = Modavd --json info $Index | Where-Object { $_ -like '{"ok"*' } | Select-Object -Last 1
    $cfg = if ($info) { ($info | ConvertFrom-Json).data.config } else { $null }
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'data_disk_mode') {
        $gb = [math]::Round([int64](((SuRun 'df -k /data | tail -n 1') -join ' ') -split '\s+')[1] / 1MB, 1)
        if ($cfg.data_disk_mode -ne 'auto' -or $cfg.data_partition_gb -lt 256 -or $gb -lt 250) {
            $problems += "旧版建的 64 GB 盘升级后没有自动扩盘：模式 $($cfg.data_disk_mode)，配置 $($cfg.data_partition_gb) GB，/data $gb GB"
        } else { $notes += "旧版建的 64 GB 盘是自动扩盘，升级后 $($cfg.data_partition_gb) GB（/data $gb GB）" }
        Modavd stop $Index | Out-Null
    } else {
        Modavd stop $Index | Out-Null
        $o = Modavd set $Index --data-gb 80
        if ($LASTEXITCODE -ne 0) { $problems += "set --data-gb 80 失败：$($o -join ' ')" }
        $o = Modavd start $Index --no-bridge
        $gb = [math]::Round([int64](((SuRun 'df -k /data | tail -n 1') -join ' ') -split '\s+')[1] / 1MB, 1)
        if ($gb -lt 78 -or -not ($o -match '数据盘已扩到')) { $problems += "改大到 80 GB 后 /data $gb GB" } else { $notes += "旧版建的 64 GB 盘改大到 80 GB（/data $gb GB）" }
    }

    # 照常用 modavd 开机：旧实例自己装上执行桥（中间关机再开机一两次）
    Modavd stop $Index | Out-Null
    $o = Modavd start $Index; $o | Select-Object -Last 1 | ForEach-Object { Say "  $_" }
    $nb = ((SuRun 'getprop ro.dalvik.vm.native.bridge') -join '').Trim()
    if ($nb -eq 'libmodavd_bridge.so') { $notes += '升级后 modavd 照常开机就自动装好了执行桥' } else { $problems += "升级后 modavd 开机没装上执行桥（native bridge=$nb）" }
    $o | Where-Object { $_ -match '宿主输入法' } | ForEach-Object { Say "  装桥这次开机：$_" }

    # 宿主输入法跟着包过来：包根的 APK 是新包那份，客体装的就是它（逐字节相同，即正式签名的那份），默认是它，标记写了
    if (-not $checkIme) { $notes += $imeSkip; Say $imeSkip }
    else {
        $want = (Get-FileHash -LiteralPath $imeApk -Algorithm SHA256).Hash.ToLower()
        $rootApk = Join-Path $Root 'components\modavd-ime.apk'
        $have = if (Test-Path -LiteralPath $rootApk) { (Get-FileHash -LiteralPath $rootApk -Algorithm SHA256).Hash.ToLower() } else { '' }
        $g = SuRun @'
p=$(pm path org.modavd.ime 2>/dev/null | sed -n 's/^package://p' | grep '/base\.apk$' | head -n 1)
echo "apk=$p"
[ -n "$p" ] && echo "sha=$(sha256sum "$p" 2>/dev/null | cut -d ' ' -f 1)"
echo "def=$(settings get secure default_input_method 2>/dev/null)"
if [ -e /data/local/tmp/modavd-ime.autoselected ]; then echo mark=1; else echo mark=0; fi
'@
        $kv = @{}
        foreach ($l in $g) { if ("$l".Trim() -match '^(apk|sha|def|mark)=(.*)$') { $kv[$Matches[1]] = $Matches[2].Trim() } }
        # 客体里算不了 sha256 时拉回宿主算
        if ($kv.apk -and -not $kv.sha) {
            $pulled = Join-Path $Work 'ime-base.apk'
            Adb pull $kv.apk $pulled | Out-Null
            if (Test-Path -LiteralPath $pulled) { $kv.sha = (Get-FileHash -LiteralPath $pulled -Algorithm SHA256).Hash.ToLower() }
        }
        Say "宿主输入法：新包 $want；包根 $(if ($have) { $have } else { '没有' })；客体 $(if ($kv.apk) { "$($kv.apk) $($kv.sha)" } else { '没装' })；默认 $($kv.def)；标记 mark=$($kv.mark)"
        $ime = @()
        if (-not $have) { $problems += '覆盖后包根没有 components\modavd-ime.apk' }
        elseif ($have -ne $want) { $problems += "包根的 modavd-ime.apk（$have）不是新包那份（$want）" }
        else { $ime += "包根 components\modavd-ime.apk 与新包一致（sha256 $($want.Substring(0, 16))…）" }
        if (-not $kv.apk) { $problems += '客体没装上 org.modavd.ime（pm path 没有 base.apk）' }
        elseif ($kv.sha -ne $want) { $problems += "客体 org.modavd.ime 的 base.apk（$(if ($kv.sha) { $kv.sha } else { '算不出 sha256' })）不是包里那份" }
        else { $ime += '客体 org.modavd.ime 的 base.apk 与它逐字节相同' }
        if ($kv.def -ne 'org.modavd.ime/.HostImeService') { $problems += "默认输入法是 $(if ($kv.def) { $kv.def } else { '读不出' })，不是 org.modavd.ime/.HostImeService" }
        else { $ime += "默认输入法 $($kv.def)" }
        if ($kv.mark -ne '1') { $problems += '客体没有 /data/local/tmp/modavd-ime.autoselected 标记' }
        else { $ime += '标记 /data/local/tmp/modavd-ime.autoselected 在' }
        if ($ime) { $notes += "宿主输入法：$($ime -join '，')" }
    }
} catch {
    $problems += "出错（第 $($_.InvocationInfo.ScriptLineNumber) 行）：$($_.Exception.Message)"
    Say $problems[-1]
} finally {
    # 收尾哪步不成都记进问题：留下的实例、进程、目录会挡下一次
    if ($created) {
        $o = Modavd stop $Index; $code = $LASTEXITCODE
        $o | Select-Object -Last 1 | ForEach-Object { Say "  $_" }
        if ($code -ne 0) { $problems += "收尾关机失败（退出码 $code）：$(($o | Select-Object -Last 2) -join ' / ')"; Say $problems[-1] }
        if (-not $Keep) {
            $code = -1
            for ($k = 0; $k -lt 30; $k++) { $o = Modavd delete $Index --yes; $code = $LASTEXITCODE; if ($code -eq 0) { break }; Start-Sleep 2 }
            if ($code -ne 0) { $problems += "收尾删实例试了 30 次都没成（退出码 $code）：$(($o | Select-Object -Last 1))"; Say $problems[-1] }
        }
    }
    # 测试根是共用的：它的 adb server 和根目录都留着。只删这次的临时目录（新 modavd 的副本、netsim 发现目录）
    if ($made) {
        $nowVersion = try { PackageVersion $Root } catch { $null }
        $nowId = try { BuildId (Join-Path $Root 'sdk\emulator') } catch { '?' }
        $notes += "测试根 $Root 现在是 $(if ($nowVersion) { $nowVersion.Text } else { "构建 $nowId" })（测之前 $(if ($beforeVersion) { $beforeVersion.Text } else { '没有清单' })）"
        if (-not $Keep) {
            # netsimd 退出前可能还占着发现目录里的文件
            for ($k = 0; $k -lt 15 -and (Test-Path -LiteralPath $Work); $k++) {
                try { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction Stop } catch { Start-Sleep 2 }
            }
            if (Test-Path -LiteralPath $Work) { $problems += "收尾删了 15 次临时目录 $Work 还没删干净"; Say $problems[-1] }
        }
    }
}
$summary = $notes -join '；'
if ($problems) { $summary += "；问题：$($problems -join '；')" }
Result ($problems.Count -eq 0) $summary
exit 0
