# dataverify 项的主体（. "$PSScriptRoot\dataverify-lib.ps1"）：花样、写入计划、客体计划文件、核对。不依赖 common.ps1，
# 所有碰客体 / 模拟器的动作由调用方以脚本块传进来（Invoke-DataVerify 的 $Ops），tests\dataverify.ps1 换上假的测它。
#
# 花样：长 7 MiB 的"种子花样"（splitmix64 从种子算出，可重算）。文件偏移 o 处的字节 = 花样[o mod 7 MiB]。
# 写入计划：文件按 1 MiB 分段，每段随机对半劈成 4 KiB–1 MiB 的 2 的幂大小的块（块的偏移是自己大小的整数倍），
# 每块随机用普通写或 O_DIRECT 写。这样每块都正好是花样里的一段连续字节，客体小程序一次 pwrite 写一块。计划和花样只由种子（和总量、直写比例）决定，宿主可以重算。

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

public static class DataVerifyNative
{
    public const int PatternLength = 7 << 20;

    static ulong Mix(ulong x)
    {
        unchecked
        {
            x += 0x9e3779b97f4a7c15UL;
            x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9UL;
            x = (x ^ (x >> 27)) * 0x94d049bb133111ebUL;
            return x ^ (x >> 31);
        }
    }

    public static byte[] Pattern(ulong seed)
    {
        var p = new byte[PatternLength];
        ulong s = seed;
        for (int i = 0; i < p.Length; i += 8)
        {
            s = Mix(s);
            BitConverter.GetBytes(s).CopyTo(p, i);
        }
        return p;
    }

    class Rng
    {
        ulong s;
        public Rng(ulong seed) { s = seed; }
        public ulong Next() { s = Mix(s); return s; }
    }

    // 返回 (偏移, 大小, 是否直写) 三个一组的平铺数组
    public static long[] Plan(ulong seed, int mib, int directPercent)
    {
        var r = new Rng(seed ^ 0x77UL);
        var list = new List<long>();
        for (int m = 0; m < mib; m++) Split(r, list, (long)m << 20, 1 << 20, directPercent);
        return list.ToArray();
    }

    static void Split(Rng r, List<long> list, long off, int size, int directPercent)
    {
        if (size == 4096 || r.Next() % 100 < 40)
        {
            list.Add(off); list.Add(size); list.Add((long)(r.Next() % 100) < directPercent ? 1 : 0);
            return;
        }
        Split(r, list, off, size / 2, directPercent);
        Split(r, list, off + size / 2, size / 2, directPercent);
    }

    // 文件前 total 字节应有的 SHA-256（小写十六进制）
    public static string ExpectedSha256(byte[] pattern, long total)
    {
        using (var h = SHA256.Create())
        {
            long o = 0;
            while (o < total)
            {
                int start = (int)(o % pattern.Length);
                int n = (int)Math.Min(pattern.Length - start, total - o);
                h.TransformBlock(pattern, start, n, null, 0);
                o += n;
            }
            h.TransformFinalBlock(new byte[0], 0, 0);
            return BitConverter.ToString(h.Hash).Replace("-", "").ToLowerInvariant();
        }
    }

    // 逐字节比对：返回 {第一个不同的偏移（没有是 -1）, 错字节数, 文件实际大小}。比期望短的部分算全错，多出来的部分也算错。
    public static long[] Diff(byte[] pattern, string path, long total)
    {
        long first = -1, bad = 0, size;
        using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20))
        {
            size = f.Length;
            var buf = new byte[1 << 20];
            long o = 0;
            while (o < Math.Max(size, total))
            {
                int k = o < size ? f.Read(buf, 0, buf.Length) : 0;
                if (k == 0 && o < size) break;
                int n = k > 0 ? k : (int)Math.Min(buf.Length, total - o);
                for (int i = 0; i < n; i++)
                {
                    long pos = o + i;
                    bool ok = k > 0 && pos < total && buf[i] == pattern[(int)(pos % pattern.Length)];
                    if (!ok) { if (first < 0) first = pos; bad++; }
                }
                o += n;
            }
        }
        return new long[] { first, bad, size };
    }
}
'@

function New-DataPattern([uint64]$Seed) { , [DataVerifyNative]::Pattern($Seed) }

# 写入计划：[pscustomobject]@{ Offset; Size; Direct } 的数组
function New-WritePlan([uint64]$Seed, [int]$SizeMiB, [int]$DirectPercent = 50) {
    if ($SizeMiB -lt 1) { throw "总量要至少 1 MiB（$SizeMiB）" }
    $flat = [DataVerifyNative]::Plan($Seed, $SizeMiB, $DirectPercent)
    for ($i = 0; $i -lt $flat.Length; $i += 3) {
        [pscustomobject]@{ Offset = $flat[$i]; Size = [int]$flat[$i + 1]; Direct = ($flat[$i + 2] -eq 1) }
    }
}

function Get-ExpectedSha256([byte[]]$Pattern, [int64]$Bytes) { [DataVerifyNative]::ExpectedSha256($Pattern, $Bytes) }

# 交给客体小程序（dataverify-guest.go）的计划文件：每块一行 `<偏移> <大小> <0|1>`（1 = O_DIRECT 写）
function New-GuestPlanText($Plan) {
    (@($Plan | ForEach-Object { "$($_.Offset) $($_.Size) $(if ($_.Direct) { 1 } else { 0 })" }) -join "`n") + "`n"
}
# 核对：写 -> 重启前回读 -> sync、正常关机、冷启动 -> 回读 -> 删。
# $Ops（脚本块，调用方给）：
#   Prepare            建客体里的目录、把花样（Pattern）放进去
#   Write $PlanText    按计划文件的内容写数据文件，成功返回 $true
#   Hash               客体里数据文件的 SHA-256（小写十六进制），取不到返回 $null；这一步前面已经 sync 并清了页缓存
#   FreeBytes          /data 剩余字节
#   Pull $LocalPath    把客体里的数据文件拉到宿主（出错时定位第一个不同的偏移）
#   Reboot             sync、正常关机、冷启动，返回 $true
#   BootId             客体的 boot_id（核对真的重启过）
#   Remove             删掉客体里的数据文件、花样、计划、小程序
# 返回 [pscustomobject]@{ Problems; Notes }
function Invoke-DataVerify([int]$SizeMiB, [uint64]$Seed, [int]$DirectPercent, [hashtable]$Ops, [scriptblock]$Say = { param($m) }) {
    $problems = @(); $notes = @()
    $bytes = [int64]$SizeMiB * 1MB
    $pattern = New-DataPattern $Seed
    $plan = @(New-WritePlan $Seed $SizeMiB $DirectPercent)
    $direct = @($plan | Where-Object Direct)
    $sizeSet = @($plan.Size | Sort-Object -Unique)
    $expected = Get-ExpectedSha256 $pattern $bytes
    & $Say ("计划：{0} MiB，{1} 次写入（直写 {2} 次，普通写 {3} 次），单次 {4}–{5} KiB，期望 SHA-256 {6}" -f $SizeMiB, $plan.Count, $direct.Count, ($plan.Count - $direct.Count), ($sizeSet[0] / 1KB), ($sizeSet[-1] / 1KB), $expected.Substring(0, 12))
    $notes += "$SizeMiB MiB、$($plan.Count) 次写入（直写 $($direct.Count)）"
    try {
        $free = & $Ops.FreeBytes
        if ($null -ne $free -and $free -lt $bytes + 256MB) { throw "客体 /data 只剩 $([math]::Round($free / 1MB)) MiB，写 $SizeMiB MiB 不够（要多留 256 MiB）" }
        & $Ops.Prepare $pattern
        $t0 = Get-Date
        if (-not (& $Ops.Write (New-GuestPlanText $plan))) { throw '客体里写花样文件失败' }
        $notes += ('写 {0:N0} s' -f ((Get-Date) - $t0).TotalSeconds)
        $bootBefore = & $Ops.BootId
        $h = & $Ops.Hash
        if ($h -ne $expected) { $problems += "重启前回读的哈希和期望的不一致（客体 $h，期望 $expected）" }
        else { & $Say '重启前回读：哈希一致' }
        $t0 = Get-Date
        if (-not (& $Ops.Reboot)) { throw '关机再冷启动失败' }
        $notes += ('关机加冷启动 {0:N0} s' -f ((Get-Date) - $t0).TotalSeconds)
        $bootAfter = & $Ops.BootId
        if ($bootBefore -and $bootBefore -eq $bootAfter) { $problems += "boot_id 没变（$bootAfter）：没有真的重启" }
        $h = & $Ops.Hash
        if ($h -eq $expected) {
            & $Say '冷启动后回读：哈希一致，0 个错字节'
            $notes += '冷启动后 0 个错字节'
        } else {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "dataverify-$PID.bin"
            try {
                & $Ops.Pull $tmp
                $d = [DataVerifyNative]::Diff($pattern, $tmp, $bytes)
                $where = if ($d[1] -gt 0) { "第一个不同的偏移 $($d[0])（$([math]::Floor($d[0] / 4096)) 号 4 KiB 块），共 $($d[1]) 个错字节，文件大小 $($d[2])（应为 $bytes）" } else { "拉回来逐字节比对没有差异，但客体算的哈希是 $h" }
                $problems += "冷启动后回读不一致：$where"
            } catch {
                $problems += "冷启动后回读的哈希不一致（客体 $h，期望 $expected），拉回来定位偏移也失败：$($_.Exception.Message)"
            } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
        }
    } catch {
        $problems += "出错：$($_.Exception.Message)"
    } finally {
        try { & $Ops.Remove } catch { $problems += "清理客体里的文件失败：$($_.Exception.Message)" }
    }
    [pscustomobject]@{ Problems = $problems; Notes = $notes }
}
