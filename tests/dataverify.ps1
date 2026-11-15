# dataverify 项的测试：不开模拟器、不碰 adb 和 modavd。用宿主上的一个临时文件冒充客体里的数据文件，
# 假的 Write 把计划文件逐行"执行"到这个文件上（和客体小程序同样的算法：偏移 o 处写花样[o mod 长度]起的一段），所以同时核对了计划 -> 计划文件 -> 文件内容这条链。
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\items\dataverify-lib.ps1"
$count = 0
function Check([bool]$ok, [string]$message) {
    $script:count++
    if (-not $ok) { throw $message }
}

# 花样和计划可复现，换种子就不同
$a = New-DataPattern 42; $b = New-DataPattern 42; $c = New-DataPattern 43
Check ($a.Length -eq 7MB) 'pattern length'
Check ([Linq.Enumerable]::SequenceEqual([byte[]]$a, [byte[]]$b)) 'same seed, same pattern'
Check (-not [Linq.Enumerable]::SequenceEqual([byte[]]$a, [byte[]]$c)) 'different seed, different pattern'
$p1 = @(New-WritePlan 42 64); $p2 = @(New-WritePlan 42 64); $p3 = @(New-WritePlan 43 64)
Check (($p1 | ConvertTo-Json -Compress) -eq ($p2 | ConvertTo-Json -Compress)) 'same seed, same plan'
Check (($p1 | ConvertTo-Json -Compress) -ne ($p3 | ConvertTo-Json -Compress)) 'different seed, different plan'

# 计划：覆盖整个文件、不重叠、按偏移递增，大小在 4 KiB–1 MiB 之间且是自己偏移的约数，普通写和直写都有
$plan = @(New-WritePlan 7 256)
$pos = 0L; $ok = $true
foreach ($x in $plan) { if ($x.Offset -ne $pos -or $x.Size -lt 4096 -or $x.Size -gt 1MB -or $x.Offset % $x.Size -ne 0) { $ok = $false }; $pos += $x.Size }
Check ($ok -and $pos -eq 256MB) 'plan covers the file exactly with aligned 4 KiB-1 MiB chunks'
Check (@($plan | Where-Object Direct).Count -gt 0 -and @($plan | Where-Object { -not $_.Direct }).Count -gt 0) 'plan mixes buffered and direct'
Check (@($plan.Size | Sort-Object -Unique).Count -ge 6) 'plan mixes many sizes'
Check (@(New-WritePlan 7 8 0 | Where-Object Direct).Count -eq 0 -and @(New-WritePlan 7 8 100 | Where-Object { -not $_.Direct }).Count -eq 0) 'direct percent 0 / 100'
$failed = $false; try { New-WritePlan 1 0 | Out-Null } catch { $failed = $true }
Check $failed 'size 0 must fail'

# 计划文件（交给客体小程序）：每块一行 `偏移 大小 0|1`，直写的行末尾是 1
$text = New-GuestPlanText $plan
$lines = @($text -split "`n" | Where-Object { $_ })
Check ($lines.Count -eq $plan.Count -and $lines[0] -match '^0 \d+ [01]$') 'one plan line per chunk'
Check (@($lines | Where-Object { $_ -match ' 1$' }).Count -eq @($plan | Where-Object Direct).Count) 'direct lines end with 1'
# 假客体：一个宿主上的文件
$dir = Join-Path ([IO.Path]::GetTempPath()) ("dataverify-test-" + [guid]::NewGuid())
New-Item -ItemType Directory $dir | Out-Null
try {
    function New-FakeOps([string]$Dir, [hashtable]$State) {
        $file = Join-Path $Dir 'guest-dv.bin'
        $ops = @{}
        $ops.FreeBytes = { if ($null -ne $State.Free) { $State.Free } else { 100GB } }.GetNewClosure()
        $ops.Prepare = { param($pattern) $State.Pattern = $pattern; $State.Prepared = $true }.GetNewClosure()
        $ops.Write = {
            param($text)
            $pattern = $State.Pattern
            $fs = [IO.File]::Open($file, 'Create', 'ReadWrite')
            try {
                foreach ($l in ($text -split "`n")) {
                    if ($l -notmatch '^(\d+) (\d+) ([01])$') { continue }
                    $off = [int64]$Matches[1]; $size = [int]$Matches[2]
                    $fs.Position = $off
                    $fs.Write($pattern, [int]($off % $pattern.Length), $size)
                    if ($Matches[3] -eq '1') { $State.Direct++ } else { $State.Buffered++ }
                }
            } finally { $fs.Dispose() }
            $true
        }.GetNewClosure()
        $ops.BootId = { "boot-$($State.Boots)" }.GetNewClosure()
        $ops.Hash = {
            if (-not (Test-Path -LiteralPath $file)) { return $null }
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        }.GetNewClosure()
        $ops.Pull = { param($local) Copy-Item -LiteralPath $file -Destination $local -Force }.GetNewClosure()
        $ops.Reboot = {
            $State.Boots++
            if ($State.Corrupt -is [scriptblock]) { & $State.Corrupt $file }
            -not $State.RebootFails
        }.GetNewClosure()
        $ops.Remove = { $State.Removed = $true; if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }.GetNewClosure()
        $ops
    }
    function New-State { @{ Boots = 1; Direct = 0; Buffered = 0; Removed = $false } }

    # 1. 正常：通过，写了直写和普通写，删干净
    $s = New-State
    $r = Invoke-DataVerify 8 99 50 (New-FakeOps $dir $s)
    Check ($r.Problems.Count -eq 0) "clean run must pass: $($r.Problems -join '; ')"
    Check ($s.Direct -gt 0 -and $s.Buffered -gt 0 -and $s.Removed -and -not (Test-Path (Join-Path $dir 'guest-dv.bin'))) 'both write kinds issued and cleaned up'
    Check (($r.Notes -join ' ') -match '0 个错字节') 'notes report zero bad bytes'

    # 2. 冷启动后翻一个字节：失败，报偏移 1234567 和 1 个错字节，仍然清理
    $s = New-State
    $s.Corrupt = { param($f) $fs = [IO.File]::Open($f, 'Open', 'ReadWrite'); try { $fs.Position = 1234567; $b = $fs.ReadByte(); $fs.Position = 1234567; $fs.WriteByte(($b -bxor 0xff)) } finally { $fs.Dispose() } }
    $r = Invoke-DataVerify 8 99 50 (New-FakeOps $dir $s)
    Check ($r.Problems.Count -eq 1 -and $r.Problems[0] -match '第一个不同的偏移 1234567' -and $r.Problems[0] -match '共 1 个错字节') "one flipped byte must be located: $($r.Problems -join '; ')"
    Check $s.Removed 'cleanup after mismatch'

    # 3. 冷启动后少了尾巴（截短）：失败，错字节数 = 少的字节数
    $s = New-State
    $s.Corrupt = { param($f) $fs = [IO.File]::Open($f, 'Open', 'ReadWrite'); try { $fs.SetLength(8MB - 4096) } finally { $fs.Dispose() } }
    $r = Invoke-DataVerify 8 99 50 (New-FakeOps $dir $s)
    Check ($r.Problems.Count -eq 1 -and $r.Problems[0] -match '第一个不同的偏移 8384512' -and $r.Problems[0] -match '共 4096 个错字节') "truncation must be reported: $($r.Problems -join '; ')"

    # 4. 冷启动后文件没了（哈希取不到）：失败
    $s = New-State
    $s.Corrupt = { param($f) Remove-Item -LiteralPath $f -Force }
    $r = Invoke-DataVerify 8 99 50 (New-FakeOps $dir $s)
    Check ($r.Problems.Count -ge 1) 'missing file must fail'
    Check ($s.Removed) 'cleanup after missing file'

    # 5. 关机或冷启动失败：失败并清理；写入失败、剩余空间不够：失败并清理，且不写
    $s = New-State; $s.RebootFails = $true
    $r = Invoke-DataVerify 8 99 50 (New-FakeOps $dir $s)
    Check ($r.Problems.Count -ge 1 -and $r.Problems[0] -match '关机再冷启动失败' -and $s.Removed) 'reboot failure must fail and clean up'
    $s = New-State; $s.Free = 4MB
    $r = Invoke-DataVerify 8 99 50 (New-FakeOps $dir $s)
    Check ($r.Problems.Count -eq 1 -and $r.Problems[0] -match '不够' -and $s.Direct -eq 0 -and $s.Buffered -eq 0 -and $s.Removed) 'not enough free space: fail before writing'

    # 6. boot_id 没变：没有真的重启，失败
    $s = New-State
    $ops = New-FakeOps $dir $s
    $ops.BootId = { 'same' }
    $r = Invoke-DataVerify 8 99 50 $ops
    Check ($r.Problems.Count -eq 1 -and $r.Problems[0] -match 'boot_id 没变') 'unchanged boot_id must fail'

    # 7. 清理本身出错也要报
    $s = New-State
    $ops = New-FakeOps $dir $s
    $ops.Remove = { throw 'rm failed' }
    $r = Invoke-DataVerify 8 99 50 $ops
    Check ($r.Problems.Count -eq 1 -and $r.Problems[0] -match '清理客体里的文件失败') 'cleanup failure must be reported'
} finally { Remove-Item -LiteralPath $dir -Recurse -Force }
Write-Host "$count assertions passed"
