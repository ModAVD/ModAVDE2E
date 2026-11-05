# Helpers for the opt-in disk usage measurement.
function Get-DataDevice([string[]]$Lines) {
    $rows = @($Lines | Where-Object { ($_ -split '\s+').Count -ge 3 -and ($_ -split '\s+')[1] -eq '/data' })
    if ($rows.Count -ne 1) { throw 'Expected one /data mount in /proc/mounts' }
    return ($rows[0] -split '\s+')[0]
}

function Convert-DataDf([string[]]$Lines, [string]$Device) {
    $rows = @($Lines | Where-Object { $_.Trim() })
    if ($rows.Count -ne 2) { throw "Unexpected df output: $($Lines -join ' | ')" }
    $parts = $rows[1].Trim() -split '\s+'
    if (-not $Device -or $parts.Count -lt 6 -or $parts[0] -ne $Device) { throw "Unexpected /data row: $($rows[1])" }
    $values = @()
    foreach ($x in $parts[1..3]) {
        $n = [long]0
        if (-not [long]::TryParse($x, [ref]$n) -or $n -lt 0) { throw "Invalid df value: $x" }
        $values += $n
    }
    [pscustomobject]@{ total = $values[0]; used = $values[1]; available = $values[2] }
}

function Assert-InstallState($State, [string]$Sha, [string]$PackageId) {
    if (@($State.samples).Count -eq 0 -or $State.samples[-1].stage -ne 'before-install') { throw 'Missing current before-install sample' }
    if ($State.samples[-1].inodes.total -ne 1048576) { throw 'The before-install sample does not have the expected inode cap' }
    if ($State.game -and ($State.game.installed -or $State.game.apkSha256 -ne $Sha -or $State.game.packageId -ne $PackageId)) { throw 'Only the same APK may be retried after a failed install' }
    if ($State.game.lastAttempt -and [datetimeoffset]$State.samples[-1].time -le [datetimeoffset]$State.game.lastAttempt) { throw 'Take a fresh baseline after the failed attempt' }
}

function Get-AllocatedBytes([string]$Path) {
    if (-not ('DiskUsage.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
namespace DiskUsage {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        struct StandardInfo {
            public long AllocationSize, EndOfFile;
            public uint NumberOfLinks;
            public byte DeletePending, Directory;
        }
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetFileInformationByHandleEx(Microsoft.Win32.SafeHandles.SafeFileHandle h, int kind, out StandardInfo info, uint size);
        public static long Allocated(string path) {
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                StandardInfo info;
                if (!GetFileInformationByHandleEx(file.SafeFileHandle, 1, out info, (uint)Marshal.SizeOf(typeof(StandardInfo))))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return info.AllocationSize;
            }
        }
    }
}
'@
    }
    [DiskUsage.Native]::Allocated($Path)
}
