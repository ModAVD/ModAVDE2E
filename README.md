# ModAVDE2E

**简体中文** | [English](README.en.md)

<!-- README.md 和 README.en.md 逐节对应：改了其中一份，请在同一个 PR 里把另一份也改了。 -->

[ModAVD](https://github.com/ModAVD/ModAVD) 的端到端测试：在装好的整包上跑发版前回归，测的是用户真正用到的那条路：
执行桥装卸、新建和扩容数据盘、从上一版升级、随包的宿主输入法、各游戏用自己的自动化脚本实跑。
跑出来的结果表 `results.md` 贴进 ModAVD 仓库 `tools/pubrel/config/changes.md` 的「发布前回归」，跟着 Release 说明发出去。

这里的项跨好几个仓库：模拟器（[ModAVDQemu](https://github.com/ModAVD/ModAVDQemu) 等）、管理器和命令行
（[ModAVDManager](https://github.com/ModAVD/ModAVDManager)）、宿主输入法（[ModAVDHostIME](https://github.com/ModAVD/ModAVDHostIME)）、
ModAVD 仓库里的随包脚本 `package/` 和执行桥 `bridge/`，所以单独放一个仓库，不跟着哪一个发版。

## 先说清楚

- **只能在测试机上实跑。** 要模拟器、显卡、登着测试号的游戏实例和各游戏的自动化工具，GitHub 的托管机器跑不了。
  本仓库的 CI 只做静态检查（语法解析、隐私扫描）。
- **各游戏的项要另装它们的自动化工具**（MAA、M9A、StarRailCopilot、MaaEnd、MaaYYs），位置写进本机配置。
  代码里没有账号信息，测试号只在本机的测试实例里。**用模拟器和脚本运行游戏是否符合游戏的用户协议，请自行判断。**
- **测试实例用新建的、登测试号的**，不要拿登着主力账号的实例来跑：有几项会建实例、删实例、强停游戏。
- adb 只用私有端口，不碰 5037，也不碰生产根目录的 20049 / 20050；关实例一律先 `adb shell sync` 再关。
- 测试机上同时有生产根目录时，测试根要在 `mas-avd.json` 里设 `portBase`（比如 21000，要管理器带 ModAVD/ModAVD#75），
  实例的端口就不和生产的同编号实例撞；`upgrade`、`ime-pkg` 自己搭的根目录默认写 23000。各项的 serial 和端口都从
  `modavd info --json` 取，不自己按 `20000 + 10 × 编号` 算。
- 问题和建议到 ModAVD 仓库的 [Issues](https://github.com/ModAVD/ModAVD/issues) 提，选上「发版前回归」；本仓库只收 PR。

## 怎么跑

PowerShell 7（`pwsh`），辅助脚本用 Python 3.12。

```powershell
pwsh -NoProfile -File regress.ps1 -Suite suites\release.psd1 -Scope emulator -Sdk <新 SDK> -Baseline <上一个发布版的 SDK>
pwsh -NoProfile -File regress.ps1 -Suite suites\release.psd1 -Scope manager,ime -Sdk <SDK>
pwsh -NoProfile -File regress.ps1 -Suite suites\release.psd1 -Sdk <SDK> -Only yys,datadisk
pwsh -NoProfile -File regress.ps1 -Suite suites\release.psd1 -Scope emulator -Sdk <SDK> -DryRun
```

**改了什么跑什么**：套件顶上的 `Scopes` 列出改动范围（`emulator`、`bridge`、`manager`、`ime`、
`scripts`、`repack`），每项的 `Scopes` 写它管哪些范围；`-Scope` 跑和它有交集的项。套件有范围时必须给 `-Scope` 或 `-Only`。
`PostPackage` 列打完包要用组包目录补跑的（升级、`ime-pkg`），运行器最后按范围提示。先 `-DryRun` 看会跑哪些项、用到哪些本机配置。

**游戏项帧率**：`items\game-real.ps1` 默认只跑装桥那一轮，帧率中位数和 `baselines\fps.json`（上一个生产版的数，每个游戏有容差）比；
`items\yys.ps1` 的庭院和每场战斗也和它比（`yys-courtyard`、`yys-battle`）。同机别的模拟器多于 2 个时只记录不判。
基准记着测的时候睿频开没开（`condition`）：测的时候按宿主 CPU 的「处理器性能」判（超过 101 % 就是开着）。这次条件比基准差（睿频关对睿频开的基准）或者判不出时只记录不判；比基准好照判，睿频只会让帧率更高。
每次发版回归通过后，把这一版的数和条件写回 `fps.json`。

输出默认在 `<TempRoot>\regress-<构建>-<时间>\`（本机配置有 `TempRoot` 时 `-Out` 也必须在它下面）：每项的控制台 `<项>.console.txt`、
项目自己的输出 `<项>\`、总日志 `regress.log`、`results.json` 和 `results.md`。有一项不是「通过」，退出码就是 1。
日志开头记下测的是哪一版：管理器命令行的哈希、随包脚本所在仓库的提交、本仓库的提交。

`-Manager` 是放着 `tools\modavd.exe` 和 `ModAVD.exe` 的目录（ModAVDManager 的 `build.ps1 -Out`，或解开的 Release 包），发版回归用要随包发的那一版；
`-PackageScripts` 是 ModAVD 仓库的 `package\`，发版回归用发版克隆里的那份。两个都能写进本机配置。

## 本机配置

仓库里不写死本机路径。测试机、外部工具这些本机的东西写进本机配置：把 [`local.example.psd1`](local.example.psd1) 复制成同目录的
`local.psd1`（`.gitignore` 挡着，不会提交）照注释填，或者放在仓库外、用环境变量 `MODAVD_E2E_CONFIG` 指过去。
读取规则在 [`local.ps1`](local.ps1)：参数优先，其次本机配置；两处都没有就报错，不猜默认值。
套件里用 `{Local:<键名>}` 引用，各项脚本单独跑时也从这里取默认值。没配的键：`-DryRun` 会列出来，真跑时用到它的项记「跳过」。

| 键 | 是什么 | 谁用 |
| --- | --- | --- |
| `TempRoot` | 临时输出的根目录 | 运行器、各项 |
| `Manager` | 放着 `tools\modavd.exe`、`ModAVD.exe` 的目录 | 运行器、各项 |
| `PackageScripts` | ModAVD 仓库的 `package\`（装桥脚本 `modavd-bridge.ps1` 在里面） | 运行器、bridge、upgrade、game-real |
| `TestRoot` | 测试用的 ModAVD 根目录（私有 adb 端口，同机有生产根目录时设 `portBase`；0 号已装桥、登着阴阳师测试号，其余编号临时建、跑完删） | bridge、bridge-default、datadisk、yys |
| `PrevPackage` | 上一个生产版的组包目录（固定副本） | upgrade |
| `OfficialSdk` | 官方 SDK（`platform-tools`、`system-images`），新搭的根目录链到它，代替「补全组件」的下载 | upgrade、ime-pkg |
| `Launcher` | 启动器 `avd-p0.ps1`（无头 / 带窗口开 AVD，带 `-AdbPort`、`-VulkanFix` 等参数） | game-real、ime |
| `Monitor` | 采样脚本 `emu_monitor.py`（30 秒一行：帧率、重启、崩溃、ANR、Vulkan 报错） | game-real |
| `VulkanFixLib` | 客体 Vulkan 修复库 | game-real |
| `GameAvdHome` / `SrAvdHome` / `ImeAvdHome` | 游戏实例 `mas_6`、`mas_7`、`endfield`，星铁实例 `gfx_t2`，输入法冒烟机 `imesmoke` 的 `ANDROID_AVD_HOME` | game-real、bench、ime |
| `Kit` | 明日方舟（MAA）、1999（M9A）的驱动目录 | ark、r1999 |
| `SrcDir` / `SrcKit` | StarRailCopilot 和它的压测驱动 `stress.py` 所在目录 | sr |
| `MaaEndDir` | 终末地 MaaEnd 驱动 `maaend-run.ps1` 所在目录 | ef |
| `MaaYYs` | MaaYYs 的运行目录（`interface.json`、`maafw\`、`tasks\`） | yys |
| `Coldprof` | 终末地冷启动采样脚本 `coldprof.ps1` | ef-ab |
| `Bench` / `ShimDll` | 体检台 `bench.ps1` 和它用的截图垫片 dll | bench |
| `ImeTestApk` / `DevImeApk` / `BuildTools` | 输入法测试 APK、开发签名的同一个输入法、Android build-tools 36.1.0（`apksigner`） | ime-pkg |

`suites\release.psd1` 是维护者 Windows 测试机上的套件。别的平台的负责人照它写自己的套件（放在 `suites\` 下）：
运行器（`regress.ps1`）和 `items\common.ps1` 不绑平台，项目脚本和测试机按自己的环境写，本机的东西同样放进本机配置。

## 运行器做什么

- 单线程，一项一项跑。每项开跑前等宿主空闲物理内存 ≥ `NeedFreeGB`（默认 8）、提交余量 ≥ `NeedCommitGB`（默认 12），
  每分钟查一次，最多等 `MaxWaitHours`（默认 3）小时。测试机上可能还有别的模拟器在跑。
- `Avoid` 里的时段（`'HH:mm-HH:mm'`）不跑，记「跳过」。例如测试号在别处每天固定时间在用。
- 每项在子进程里跑，输出强制 UTF-8。限时 `TimeoutMin`（默认 40）。超时就停在这里，后面的项都不跑：超时的那项可能还占着实例。
- 跑期间系统日志里的显卡驱动重置（nvlddmkm）计数记进结果，算不算失败由人看。
- 最后看套件 `Avds` 里列的测试机有没有 qemu 留着。

## 套件里每项的字段

| 字段 | 意思 |
| --- | --- |
| `Id` / `Title` / `Criterion` | 编号；表格里的「项目」和「判据」两列 |
| `Script` / `Args` | 要跑的脚本和参数。占位符 `{Sdk}` `{Baseline}` `{Label}` `{Out}` `{ItemOut}` `{Repo}`（本仓库的根目录），`{Local:<键名>}` 取本机配置 |
| `TimeoutMin` `NeedFreeGB` `NeedCommitGB` `MaxWaitHours` `Avoid` | 见上 |
| `NeedsBaseline` | 要对照版（A/B），没给 `-Baseline` 就跳过 |
| `ExitCode` | 期望的退出码，默认 0；`'any'` 表示不看退出码、只看 `Pass` / `Fail` |
| `Pass` / `Fail` | 正则：`Pass` 每条都要在输出里出现，`Fail` 一条都不能出现 |
| `Summary` | 正则：结果栏的摘要取最后一次匹配（有分组就取分组） |

## 写一个新项

脚本最后打印一行结果，运行器就不看 `Pass` / `Fail`：

```
REGRESS-RESULT {"pass":true,"summary":"到登录页 41 秒；进游戏后 52.7 fps / 平均 21.1 ms / 最慢 33 ms"}
```

`items\common.ps1` 给新项用：`Set-RootSdk` 把测试根的 `mas-avd.json` 临时指到被测 SDK、跑完换回；`M` 调测试根的 `modavd.exe`，
开机后的设置和产品一样，关机先正常关机、不成再 sync；`A` / `Su` 走测试根的私有 adb；`Get-InstancePorts` 取 modavd 报的实例 serial 和端口；`Result` 打结果行；`Use-Local` 取本机配置。
游戏界面只做「拉起」和「点进入游戏」这类固定操作，需要认画面时由脚本自己读像素（`yys.ps1` 认登录页左下角的适龄角标，两个位置都认），不交给模型看图。

## 现有的项（`suites\release.psd1`）

| 项 | 脚本 | 说明 |
| --- | --- | --- |
| bench | 本机配置 `Bench` | 体检；宿主没开测试服务器时 net 的 ERROR 不算 |
| ime | `items\ime-reg.ps1` | 宿主输入法通道 20 项；`-Attach` 那组参数（`-AdbPort` `-Serial` `-EmulatorLog`，可选 `-AdbExe` `-TestApk`）给 ime-pkg 对开着的实例跑，不带时开 `imesmoke` 自己跑 |
| bridge-default | `items\bridge-default.ps1` | 新建实例默认装执行桥，`modavd bridge` 卸 / 装，新建 7 号实例跑完删掉 |
| ark / r1999 / sr / ef | `items\game-real.ps1` | 各游戏自己的自动化脚本实跑 15 分钟（装桥那轮），帧率和 `baselines\fps.json` 比 |
| bridge | `items\bridge.ps1` | 执行桥装 / 卸全流程（Windows PowerShell 5.1），新建 6 号实例跑完删掉 |
| datadisk | `items\datadisk.ps1` | 新盘 inode 封顶、`set --data-gb` 扩容，新建 3 号实例跑完删掉 |
| upgrade | `items\upgrade.ps1` | 用上一版正式包搭根目录、建实例写数据，照「怎么更新」覆盖新包后核对开机、数据、扩容、照常开机自动装桥；`-Next` 是组包目录（带 `components\modavd-ime.apk`）时还核对宿主输入法跟着包过来、装上的是正式签名那份并设为默认（`-Next` 是 SDK 时不查）；根目录跑完删掉 |
| yys | `items\yys.ps1` | 阴阳师冷启动进游戏测帧（测试根的 0 号，已装桥、已登录），再用 MaaYYs（`items\maayys_run.py`）真打御魂 |
| ef-ab | `items\ef-ab.ps1` | 终末地冷启动新旧交替，等宿主空闲才测 |

不在套件里、打完包再单独跑的：

新建数据盘占用及游戏安装前后的 inode 测量见 [独立测量方法](docs/created-disk-usage.md)。此项不属于默认发版回归。

| 项 | 脚本 | 说明 |
| --- | --- | --- |
| ime-pkg | `items\ime-pkg.ps1` | `-Package <组包目录>`（`release\ModAVD-<版本>-win-x64`，只读）：复制成根目录、新建 9 号实例，核对正式签名的输入法开机自动装好、设为默认，带窗口跑通道 20 项，再核对开发签名的换成正式签名、稳态不变；根目录跑完删掉，日志留在 `-Work` 下 |

## 以后有了专门跑测试的机器

可以把它挂成这个仓库的自托管 runner，定时或手动触发整套回归。runner 只挂在本仓库，不挂 ModAVD 主仓；
**不对外部 PR 触发**，只在定时、维护者手动触发（`workflow_dispatch`）和推到受保护分支时跑；在组织的 runner 组里限定只接本仓库指定的 workflow；
那台机器只放测试实例和测试号，不放生产、不登个人账号。

## 许可证

GNU Affero General Public License 第 3 版或更新版本（AGPL-3.0-or-later），全文见 [LICENSE](LICENSE)。Copyright 2026 qiyinxi。
