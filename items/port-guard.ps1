# 端口守卫（纯函数，不依赖别的脚本；common.ps1 和 game-real.ps1 都引它）。

# 游戏实例的控制台端口（含 +1 的 adb、+2 的 gRPC）不能落在生产根目录的 20000–20049 段上，也不能碰 5037 和生产的 adb server
# 20049 / 20050。测试和生产共用一台电脑，开到生产的端口上会顶掉生产的实例。
function Assert-GameConsolePort([int]$Port, [string]$Name = '游戏实例') {
    foreach ($p in $Port, ($Port + 1), ($Port + 2)) {
        if ($p -ge 20000 -and $p -le 20049) { throw "$Name 的控制台端口 $Port（含 +1、+2 的 adb / gRPC 端口）落在生产的 20000–20049 段上，换一个：本机配置 GamePorts" }
        if ($p -in 5037, 20049, 20050) { throw "$Name 的控制台端口 $Port（含 +1、+2 的 adb / gRPC 端口）碰到生产在用的 $p，换一个：本机配置 GamePorts" }
    }
}

# 在已有的测试根里新建实例前，哪些端口被占着不能开（返回端口号，排好序、不重复）。
# $Listeners 是正在监听的端口，每个带 LocalPort 和占着它的程序路径 Path（取不到是空）。
# 实例自己的控制台 / adb / gRPC 端口要空着；测试根的两个 adb server 端口可以是这个测试根自己的 adb.exe 占着
# （前一项、前一次开机留下的，modavd 接着用），别的程序占着才算。
function Get-PortConflicts($Listeners, [int[]]$InstancePorts, [int[]]$AdbPorts, [string]$RootAdb) {
    $own = [IO.Path]::GetFullPath($RootAdb)
    @($Listeners | Where-Object {
            $_.LocalPort -in $InstancePorts -or
            ($_.LocalPort -in $AdbPorts -and -not ($_.Path -and [string]::Equals([IO.Path]::GetFullPath($_.Path), $own, [StringComparison]::OrdinalIgnoreCase)))
        } | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
}
