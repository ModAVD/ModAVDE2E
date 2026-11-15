# 回归项：磁盘读写数据核对（ModAVD/ModAVD#138，#126 的常驻回归）。用测试根的 modavd 新建一台临时实例，在客体 /data 里写一个
# 固定花样（由种子重新算得出来）的文件，总量默认 1 GiB（-SizeMiB 改小）：单次写入 4 KiB–1 MiB，普通写和 O_DIRECT 写各占一半左右。
# 写完 sync、清页缓存，回读一遍哈希；再 sync、正常关机、冷启动，回读哈希和宿主按种子算的比对；不一致就把文件拉回来，
# 报第一个不同的偏移和错字节数。最后删掉文件，再删掉这台实例（-Keep 留着实例）。
#
# 写在客体的 /data/unencrypted/ 下：/data/local/tmp、/sdcard 是文件级加密的目录，ext4 在那里会把 O_DIRECT 悄悄退回普通写，
# 测不到直写路径。客体自带的 toybox dd 没有 oflag=direct，所以写入用 items\dataverify-guest.go 这个小程序（宿主上 go build 成静态 linux/amd64，推进去跑；
# 要宿主有 go），花样文件和写入计划也从宿主推进去；哈希用客体的 sha256sum。
# 主体在 dataverify-lib.ps1（Invoke-DataVerify），tests\dataverify.ps1 换上假的客体测它。
param(
    [Parameter(Mandatory)][string]$Sdk,
    # 测试用的 ModAVD 根目录（本机配置 TestRoot）
    [string]$Root,
    # 临时实例的编号；测试根里已经有这个编号就停，换一个。5 号 modavd 不让用
    [int]$Index = 4,
    # 总量（MiB），默认 1024 = 1 GiB
    [ValidateRange(1, 65536)][int]$SizeMiB = 1024,
    # 花样的种子；同一个种子花样和写入计划都一样
    [uint64]$Seed = 0x4d4156444154,
    # 直写（O_DIRECT）占写入次数的百分比
    [ValidateRange(0, 100)][int]$DirectPercent = 50,
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
[cultureinfo]::CurrentCulture = [cultureinfo]::InvariantCulture
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\dataverify-lib.ps1"
$Root = Resolve-TestRoot (Use-Local TestRoot $Root '-Root')

$guestDir = '/data/unencrypted/e2e-dv'
$work = Join-Path ([IO.Path]::GetTempPath()) "dataverify-$PID"

$ops = @{
    FreeBytes = {
        $o = Su 'df -k /data | tail -n 1'
        $f = @("$($o | Select-Object -Last 1)".Trim() -split '\s+')
        if ($f.Count -ge 4) { [int64]$f[3] * 1KB } else { $null }
    }
    Prepare = {
        param($pattern)
        New-Item -ItemType Directory -Force $work | Out-Null
        $go = Get-Command go -ErrorAction SilentlyContinue
        if (-not $go) { throw '宿主上没有 go：客体里的写入小程序（items\dataverify-guest.go）要用它编（客体的 dd 没有 oflag=direct）' }
        $env:GOOS = 'linux'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
        try { $b = & $go.Source build -trimpath -o (Join-Path $work 'dvwrite') (Join-Path $PSScriptRoot 'dataverify-guest.go') 2>&1 }
        finally { Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue }
        if ($LASTEXITCODE -ne 0) { throw "编客体小程序失败：$($b -join ' ')" }
        [IO.File]::WriteAllBytes((Join-Path $work 'pattern.bin'), $pattern)
        A push (Join-Path $work 'pattern.bin') /data/local/tmp/dv-pattern.bin | Out-Null
        A push (Join-Path $work 'dvwrite') /data/local/tmp/dvwrite | Out-Null
        $o = Su "chmod 755 /data/local/tmp/dvwrite && mkdir -p $guestDir && cp /data/local/tmp/dv-pattern.bin $guestDir/pattern.bin && rm -f /data/local/tmp/dv-pattern.bin && echo DV-PREP-OK"
        if (-not ($o -match 'DV-PREP-OK')) { throw "客体里准备目录和花样失败：$($o -join ' ')" }
    }
    Write = {
        param($text)
        $f = Join-Path $work 'plan.txt'
        [IO.File]::WriteAllText($f, ($text -replace "`r`n", "`n"))
        A push $f /data/local/tmp/dv-plan.txt | Out-Null
        $o = Su "cp /data/local/tmp/dv-plan.txt $guestDir/plan.txt && rm -f /data/local/tmp/dv-plan.txt && /data/local/tmp/dvwrite $guestDir/pattern.bin $guestDir/dv.bin $guestDir/plan.txt"
        $o | Where-Object { $_ -match 'DV-WRITE' } | ForEach-Object { Write-Host "$(Get-Date -Format 'HH:mm:ss')   $_" }
        [bool]($o -match 'DV-WRITE-OK')
    }
    Hash = {
        $o = Su "sync; echo 3 > /proc/sys/vm/drop_caches; sha256sum $guestDir/dv.bin"
        $m = [regex]::Match(($o -join "`n"), '(?m)^([0-9a-f]{64})\s')
        if ($m.Success) { $m.Groups[1].Value } else { $null }
    }
    Pull = { param($local) A pull "$guestDir/dv.bin" $local | Out-Null }
    BootId = { "$(Su 'cat /proc/sys/kernel/random/boot_id' | Select-Object -Last 1)".Trim() }
    Reboot = {
        Su 'sync' | Out-Null
        M stop $Index | Select-Object -Last 1 | ForEach-Object { Write-Host "$(Get-Date -Format 'HH:mm:ss')   $_" }
        if ($LASTEXITCODE -ne 0) { return $false }
        M start $Index | Select-Object -Last 1 | ForEach-Object { Write-Host "$(Get-Date -Format 'HH:mm:ss')   $_" }
        $LASTEXITCODE -eq 0
    }
    Remove = { Su "rm -rf $guestDir /data/local/tmp/dvwrite /data/local/tmp/dv-plan.txt /data/local/tmp/dv-pattern.bin" | Out-Null }
}

$problems = @(); $notes = @(); $created = $false
$old = Set-RootSdk $Root $Sdk
try {
    M info $Index | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "测试根里已经有实例 $Index，换 -Index 或先删掉它" }
    $o = M create --index $Index --title 回归数据核对 --memory 4G --cpu 4 --data-gb 16 --no-bridge
    if ($LASTEXITCODE -ne 0) { throw "新建失败：$($o -join ' ')" }
    $created = $true
    M start $Index | Select-Object -Last 2 | ForEach-Object { Write-Host "$(Get-Date -Format 'HH:mm:ss')   $_" }
    if ($LASTEXITCODE -ne 0) { throw "首次开机失败（modavd 退出码 $LASTEXITCODE）" }
    $r = Invoke-DataVerify -SizeMiB $SizeMiB -Seed $Seed -DirectPercent $DirectPercent -Ops $ops -Say { param($m) Write-Host "$(Get-Date -Format 'HH:mm:ss') $m" }
    $problems += $r.Problems; $notes += $r.Notes
} catch {
    $problems += "出错：$($_.Exception.Message)"
} finally {
    M stop $Index | Select-Object -Last 1 | ForEach-Object { Write-Host "$(Get-Date -Format 'HH:mm:ss')   $_" }
    if ($created -and -not $Keep) { Remove-TestInstance $Index }
    Set-RootSdk $Root $old | Out-Null
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
$summary = $notes -join '；'
if ($problems) { $summary += "；问题：$($problems -join '；')" }
Result ($problems.Count -eq 0) $summary
exit 0
