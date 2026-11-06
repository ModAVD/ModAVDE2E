#requires -Version 7.0
# Set-RootSdk（items\common.ps1）的静态测试：测试根临时指到被测 SDK、跑完换回，mas-avd.json 一个字节都不能多改。
# testbed 的根是整包装出来的，mas-avd.json 里没有 sdkRoot；以前遇到这种根直接报错，bridge、bridge-default、datadisk、yys 都开不了。
# 不开模拟器、不调 modavd：同步工具和 port_base 核对换成空函数，测试根全在临时目录里。
# 跑法（Windows 和 Linux 都行）：pwsh -NoProfile -File tests/root-sdk.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) "modavd-rootsdk-$([guid]::NewGuid().ToString('N'))"
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
function Check([bool]$ok, [string]$message) {
    $script:checks++
    if (-not $ok) { $script:failures.Add($message); Write-Host "FAIL $message" }
}
$savedConfig = $env:MODAVD_E2E_CONFIG
try {
    $null = New-Item -ItemType Directory -Force $scratch
    $env:MODAVD_E2E_CONFIG = Join-Path $scratch 'empty.psd1'
    Set-Content -LiteralPath $env:MODAVD_E2E_CONFIG -Value '@{}'
    # common.ps1 只有函数定义和几个变量，dot-source 不跑别的
    . (Join-Path $repo 'items\common.ps1')
    $script:calls = [Collections.Generic.List[string]]::new()
    function Sync-RootTools([string]$Root) { $script:calls.Add("sync $Root") }
    function Assert-ManagerPortBase([string]$Root, [string]$Exe, [int]$Want = 0) { $script:calls.Add("portbase $Root"); 31000 }

    $n = 0
    function NewRoot([string]$Text) {
        $script:n++
        $r = Join-Path $scratch "root$script:n"
        $null = New-Item -ItemType Directory -Force $r
        [IO.File]::WriteAllText((Join-Path $r 'mas-avd.json'), $Text, [Text.UTF8Encoding]::new($false))
        $r
    }
    function Json([string]$Root) { [IO.File]::ReadAllText((Join-Path $Root 'mas-avd.json')) }
    # 管理器（Go 的 encoding/json）不认多余的逗号；ConvertFrom-Json 认，所以另用严格的 System.Text.Json 核
    function Strict([string]$Root) {
        try { [System.Text.Json.JsonDocument]::Parse((Json $Root)).Dispose(); $true } catch { $false }
    }
    $sdk = 'E:\aosp\sdk-mas39'

    # ---- 1. testbed 的根：没有 sdkRoot（LF、两格缩进，和整包装出来的一样）
    $plain = "{`n  `"portBase`": 31000,`n  `"adbServerPort`": 31099,`n  `"instances`": {`n    `"1`": {`n      `"initialized`": true`n    }`n  }`n}"
    $r = NewRoot $plain
    $script:calls.Clear()
    $old = Set-RootSdk $r $sdk
    Check ($null -eq $old) "root without sdkRoot must return `$null, got: [$old]"
    $j = Json $r | ConvertFrom-Json
    Check ($j.sdkRoot -ceq $sdk) "sdkRoot must be the SDK under test, got: $($j.sdkRoot)"
    Check ($j.portBase -eq 31000 -and $j.adbServerPort -eq 31099 -and $j.instances.'1'.initialized) 'the other keys must stay'
    Check (Strict $r) 'with sdkRoot inserted the file must be strict JSON'
    Check ((Json $r) -ceq "{`n  `"sdkRoot`": `"E:\\aosp\\sdk-mas39`",$($plain.Substring(1))") "sdkRoot must be inserted as the first key with the file's own newline and indent, got: $(Json $r)"
    Check (($script:calls -join ',') -ceq "sync $r,portbase $r") "Set-RootSdk must sync the tools and check port_base first, got: $($script:calls -join ',')"
    Set-RootSdk $r $old | Out-Null
    Check ((Json $r) -ceq $plain) "switching back must remove the inserted key byte for byte, got: $(Json $r)"

    # CRLF
    $crlf = $plain -replace "`n", "`r`n"
    $r = NewRoot $crlf
    $old = Set-RootSdk $r $sdk
    Check ((Json $r).StartsWith("{`r`n  `"sdkRoot`": ")) 'CRLF file must get a CRLF line'
    Set-RootSdk $r $old | Out-Null
    Check ((Json $r) -ceq $crlf) 'CRLF root must come back byte for byte'

    # 管理器中途改写过 mas-avd.json，sdkRoot 成了最后一个键：换回时连同前面的逗号一起删
    $r = NewRoot $plain
    $old = Set-RootSdk $r $sdk
    $rewritten = "{`n  `"portBase`": 31000,`n  `"adbServerPort`": 31099,`n  `"instances`": {},`n  `"sdkRoot`": `"E:\\aosp\\sdk-mas39`"`n}"
    [IO.File]::WriteAllText((Join-Path $r 'mas-avd.json'), $rewritten, [Text.UTF8Encoding]::new($false))
    Set-RootSdk $r $old | Out-Null
    Check ((Json $r) -ceq "{`n  `"portBase`": 31000,`n  `"adbServerPort`": 31099,`n  `"instances`": {}`n}") "sdkRoot as the last key must be removed with the comma before it, got: $(Json $r)"
    Check (Strict $r) 'after removing the last key the file must be strict JSON'

    # 一行的、空对象的
    $r = NewRoot '{"portBase":31000}'
    $old = Set-RootSdk $r $sdk
    Check ((Json $r) -ceq '{"sdkRoot": "E:\\aosp\\sdk-mas39", "portBase":31000}') "one-line JSON must get sdkRoot first, got: $(Json $r)"
    Check (Strict $r) 'one-line JSON with sdkRoot must be strict JSON'
    Set-RootSdk $r $old | Out-Null
    Check ((Json $r) -ceq '{"portBase":31000}') "one-line JSON must come back byte for byte, got: $(Json $r)"
    $r = NewRoot '{}'
    $old = Set-RootSdk $r $sdk
    Check ((Json $r) -ceq '{"sdkRoot": "E:\\aosp\\sdk-mas39"}') "empty object must get sdkRoot without a trailing comma, got: $(Json $r)"
    Check (Strict $r) 'empty object with sdkRoot must be strict JSON'
    Set-RootSdk $r $old | Out-Null
    Check ((Json $r) -ceq '{}') "empty object must come back as {}, got: $(Json $r)"

    # 没有这个键时传 $null：什么都不改
    $r = NewRoot $plain
    Set-RootSdk $r $null | Out-Null
    Check ((Json $r) -ceq $plain) 'restoring $null on a root without sdkRoot must not touch it'

    # ---- 2. 原来就有 sdkRoot 的根（以前的 rel36 那种）：只换值，返回原值，换回后一字不差
    $dev = "{`n  `"sdkRoot`": `"E:\\aosp\\sdk-mas36`",`n  `"portBase`": 31000`n}"
    $r = NewRoot $dev
    $old = Set-RootSdk $r $sdk
    Check ($old -ceq 'E:\aosp\sdk-mas36') "existing sdkRoot must be returned unescaped, got: [$old]"
    Check ((Json $r | ConvertFrom-Json).sdkRoot -ceq $sdk) 'existing sdkRoot must be replaced'
    Set-RootSdk $r $old | Out-Null
    Check ((Json $r) -ceq $dev) "existing sdkRoot must come back byte for byte, got: $(Json $r)"

    # 原来是 ""（管理器当成没设）：换回 ""，不删键
    $blank = "{`n  `"portBase`": 31000,`n  `"sdkRoot`": `"`"`n}"
    $r = NewRoot $blank
    $old = Set-RootSdk $r $sdk
    Check ($old -ceq '') "blank sdkRoot must return '', got: [$old]"
    Set-RootSdk $r $old | Out-Null
    Check ((Json $r) -ceq $blank) "blank sdkRoot must come back as blank, got: $(Json $r)"

    # ---- 3. 用到 Set-RootSdk 的项都把原值原样传回去（不能先转成 [string]，那样 $null 会变成 ""，加的键就删不掉了）
    foreach ($item in 'bridge', 'bridge-default', 'datadisk', 'yys') {
        $itemText = Get-Content -LiteralPath (Join-Path $repo "items\$item.ps1") -Raw
        Check ($itemText -match '\$old = Set-RootSdk \$Root \$Sdk') "$item.ps1 must keep what Set-RootSdk returns"
        Check ($itemText -match 'Set-RootSdk \$Root \$old') "$item.ps1 must switch back with that value"
        Check ($itemText -notmatch '\[string\]\$old') "$item.ps1 must not turn the returned value into a string"
    }
} finally {
    $env:MODAVD_E2E_CONFIG = $savedConfig
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures.Count) { Write-Host "$($failures.Count) of $checks checks failed"; exit 1 }
Write-Host "root-sdk: all $checks checks passed"
exit 0
