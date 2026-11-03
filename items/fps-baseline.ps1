# 帧率和上一个生产版的基准（baselines\fps.json）比。game-real.ps1、yys.ps1 共用（. "$PSScriptRoot\fps-baseline.ps1"）。
# 基准记着测的时候的条件（condition，可以每一项单独写），现在只分睿频开 / 关：11-02 晚上测试机关了睿频以后，0.36.0
# 那一版自己的星铁也从 53.4 掉到 49.3 fps、阴阳师庭院从 60 掉到 53。所以这次条件比基准差（睿频关对睿频开的基准）、
# 或者判不出时只记录、不判；这次条件比基准好（睿频开对睿频关的基准）照判：睿频只会让帧率更高，这时还低过容差就是真的变慢了。

# 宿主 CPU 现在的「处理器性能」（实际频率占标称频率的百分比）；读不到返回 $null。睿频开着时会超过 100，关了不会。
# 超过 101 才算睿频开，留 1 的余量（11-03 睿频关时一直是 94–98）。
function Get-CpuPerf {
    try {
        $v = [double](Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorPerformance
        if ($v -gt 0) { $v } else { $null }
    } catch { $null }
}

# 两次读数取大的（有一边是 $null 就取另一边）
function Get-PerfMax($a, $b) { if ($null -eq $a) { $b } elseif ($null -eq $b -or $a -ge $b) { $a } else { $b } }

# 测帧那段时间里「处理器性能」的最大值换成条件；一次都没读到返回空
function Get-FpsCondition($PerfMax) {
    if ($null -eq $PerfMax) { '' } elseif ($PerfMax -gt 101) { '睿频开' } else { '睿频关' }
}

# 说明里记一笔这次的条件
function Format-FpsCondition($PerfMax) {
    if ($null -eq $PerfMax) { '读不到处理器性能' } else { '处理器性能最高 {0:N0} %（{1}）' -f $PerfMax, (Get-FpsCondition $PerfMax) }
}

function Read-FpsBaseline([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

# 和基准里 $Key 那一项比。返回：
#   Note：一句说明；Problem：没过时的问题（过了、只记录或没有基准都是空）
#   Ref：「上一版（0.37.0，睿频关）48.2」，Ratio、Tol：这次占基准多少、容差（没有基准时 Ref 是空）
#   Skip：只记录的原因
# 参数：$Label 是说明里这个数叫什么（帧率、庭院、第 1 场）；$Cond 是这次的条件（Get-FpsCondition），基准写了条件而这次
# 比它差、判不出或者不认识时只记录；$Skip 是调用方要只记录的原因（例如同机别的模拟器多），空就是照常判。
# 条件从差到好排
$FpsConditionRank = @{ '睿频关' = 0; '睿频开' = 1 }
function Compare-FpsBaseline($Base, [string]$Key, [double]$Fps, [string]$Label, [string]$Cond, [string]$Skip = '', [double]$DefaultTol = 0.10) {
    $b = if ($Base) { $Base.games.$Key } else { $null }
    if (-not $b) {
        return [pscustomobject]@{ Note = ('{0} {1:N1}，没有 {2} 的基准，只记录' -f $Label, $Fps, $Key); Problem = ''; Ref = ''; Ratio = $null; Tol = $null; Skip = '没有基准' }
    }
    $tol = if ($null -ne $b.tol) { [double]$b.tol } else { $DefaultTol }
    $ver = if ($b.version) { $b.version } else { $Base.version }
    $bc = if ($b.condition) { $b.condition } else { $Base.condition }
    $ratio = $Fps / [double]$b.fps
    $ref = '上一版（{0}{1}）{2:N1}' -f $ver, $(if ($bc) { "，$bc" }), [double]$b.fps
    $note = '{0} {1:N1}，{2}（{3:P0}，容差 {4:P0}）' -f $Label, $Fps, $ref, $ratio, $tol
    $better = $false
    if (-not $Skip -and $bc -and $Cond -ne $bc) {
        $better = $Cond -and $FpsConditionRank.ContainsKey($Cond) -and $FpsConditionRank.ContainsKey($bc) -and $FpsConditionRank[$Cond] -gt $FpsConditionRank[$bc]
        if (-not $better) { $Skip = if ($Cond) { "这次是$Cond" } else { '这次判不出睿频开没开' } }
    }
    $p = ''
    if ($Skip) { $note += "；$Skip，只记录不判" }
    else {
        if ($better) { $note += "；这次是$Cond，条件比基准好，照判" }
        if ($ratio -lt 1 - $tol) { $p = '{0}比上一版低了 {1:P0}（容差 {2:P0}）' -f $Label, (1 - $ratio), $tol }
    }
    [pscustomobject]@{ Note = $note; Problem = $p; Ref = $ref; Ratio = $ratio; Tol = $tol; Skip = $Skip }
}
