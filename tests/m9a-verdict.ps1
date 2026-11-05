# 1999 那一项（items\game-real.ps1 -Game r1999）怎么判驱动：用 -ReJudge 按造好的驱动输出重判，不开机、不连 adb。
# 11-05：M9A 4.11.1 的「智能均衡刷材料」什么都不打就「成功」退出，回归里 0.6 分钟就结束的那几次其实没打；
# 现在驱动打「常规作战」，不到 2 分钟就结束（又不是到时间停）算没打到战斗。
$ErrorActionPreference = 'Stop'
$count = 0
function Check([bool]$ok, [string]$message) {
    $script:count++
    if (-not $ok) { throw $message }
}
$work = Join-Path ([IO.Path]::GetTempPath()) "m9a-verdict-$([guid]::NewGuid().ToString('N'))"
$sdkDir = Join-Path $work 'sdk'
New-Item -ItemType Directory -Force $sdkDir | Out-Null
$runner = Join-Path $PSScriptRoot '..\items\game-real.ps1'
# 不读维护者的本机配置
$env:MODAVD_E2E_CONFIG = $null

function Verdict([string]$name, [string[]]$driver) {
    $out = Join-Path $work $name
    $round = Join-Path $out 'r1999-on'
    New-Item -ItemType Directory -Force $round | Out-Null
    Set-Content -LiteralPath (Join-Path $round 'driver.txt') -Value $driver -Encoding utf8
    [pscustomobject]@{ code = 0; timedOut = $false; alive = $true; newDumps = 0; abi = 'x86_64'; uninstall = $null; others = 0; perf = $null } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $round 'round.json') -Encoding utf8
    $lines = @(pwsh -NoProfile -File $runner -Game r1999 -Sdk $sdkDir -Out $out -ReJudge 2>&1 | ForEach-Object { "$_" })
    $result = $lines | Where-Object { $_.StartsWith('REGRESS-RESULT ') } | Select-Object -Last 1
    Check ([bool]$result) "$name：没有 REGRESS-RESULT 行：$($lines -join ' | ')"
    ($result.Substring('REGRESS-RESULT '.Length) | ConvertFrom-Json).summary
}

try {
    $start = '12:00:00 done  启动游戏: succeeded in 1.2 min'
    $s = Verdict 'no-stamina' @($start, '12:01:00 start 常规作战', '12:01:30 done  常规作战: succeeded in 0.6 min', '12:01:30 all finished in 1.8 min')
    Check ($s -match '0\.6 分钟就结束，没打到战斗') "一进去就「成功」退出的要判成没打：$s"
    Check ($s -match '问题：.*没打到战斗') "没打到战斗要算问题：$s"
    $s = Verdict 'fought' @($start, '12:01:00 start 常规作战', '12:04:24 done  常规作战: succeeded in 3.4 min', '12:04:24 all finished in 4.6 min')
    Check ($s -match 'M9A 常规作战 succeeded，3\.4 分钟' -and $s -notmatch '没打到') "打完 3.4 分钟的要算驱动过：$s"
    $s = Verdict 'budget' @($start, '12:01:00 start 常规作战', '12:16:00 budget 15 min reached, stopping', '12:16:01 done  常规作战: FAILED in 15.0 min', '12:16:01 all finished in 16.2 min (budget stop)')
    Check ($s -match 'M9A 常规作战 FAILED（到时间停），15\.0 分钟' -and $s -notmatch '没打到') "到时间停的要算驱动过：$s"
    $s = Verdict 'short-budget' @($start, '12:01:00 start 常规作战', '12:01:40 budget 1 min reached, stopping', '12:01:41 done  常规作战: FAILED in 0.7 min', '12:01:41 all finished in 1.9 min (budget stop)')
    Check ($s -notmatch '没打到') "到时间停的不按时长判：$s"
    $s = Verdict 'failed' @($start, '12:01:00 start 常规作战', '12:09:00 done  常规作战: FAILED in 8.0 min', '12:09:00 all finished in 9.2 min')
    Check ($s -match '问题：.*M9A 常规作战 FAILED') "常规作战失败要算问题：$s"
    $s = Verdict 'old-task' @($start, '12:01:00 start 智能均衡刷材料', '12:01:36 done  智能均衡刷材料: succeeded in 0.6 min')
    Check ($s -match 'M9A 常规作战没跑') "旧任务的输出不能当成打过：$s"
    $s = Verdict 'no-start' @('12:00:00 done  启动游戏: FAILED in 3.0 min')
    Check ($s -match 'M9A 启动游戏没成功') "启动游戏没成功要报：$s"
    # 吃糖次数是参数，不再写死
    $text = Get-Content -LiteralPath $runner -Raw
    Check ($text -match '\[ValidateRange\(0, 10\)\]\[int\]\$M9ACandy = 0') 'game-real.ps1 要有 -M9ACandy（0–10，默认 0）'
    Check ($text -match '\$env:M9A_CANDY = "\$M9ACandy"') 'r1999 驱动要拿到 M9A_CANDY'
    Check ($text -notmatch "done  智能均衡刷材料") '判法里不该还认智能均衡刷材料'
    Write-Host "m9a verdict: $count checks passed"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
