# ModAVDE2E

[简体中文](README.md) | **English**

<!-- README.md and README.en.md match section by section: if you change one, change the other in the same PR. -->

End-to-end tests for [ModAVD](https://github.com/ModAVD/ModAVD). They run the pre-release regression tests on an installed ModAVD package, and they test the path users actually take:
installing and uninstalling the arm64 execution bridge, creating and growing the data disk, upgrading from the previous version, the bundled host IME, and real runs of each game with its own automation scripts.
The result table `results.md` is pasted into the "pre-release regression" section of `tools/pubrel/config/changes.md` in the ModAVD repository, and goes out with the Release notes.

The items here span several repositories: the emulator ([ModAVDQemu](https://github.com/ModAVD/ModAVDQemu) and others), the manager and the CLI
([ModAVDManager](https://github.com/ModAVD/ModAVDManager)), the host IME ([ModAVDHostIME](https://github.com/ModAVD/ModAVDHostIME)),
and the bundled scripts in `package/` and the bridge in `bridge/` of the ModAVD repository. So it lives in a repository of its own and does not follow the release of any one of them.

## Read this first

- **Real runs work only on a test machine.** They need the emulator, a GPU, game instances logged in with test accounts, and each game's automation tool, and GitHub-hosted machines cannot run that.
  The CI of this repository does only static checks (syntax parsing, privacy scan).
- **The game items need their automation tools installed separately** (MAA, M9A, StarRailCopilot, MaaEnd, MaaYYs), and their locations go into the local configuration.
  There is no account information in the code; the test accounts exist only in the local test instances. **Please judge for yourself whether running games with an emulator and scripts complies with the game's terms of use.**
- **Use newly created test instances logged in with test accounts.** Do not run on an instance logged in with your main account: several items create instances, delete instances and force-stop the game.
- adb uses only private ports. It does not touch 5037, and it does not touch 20049 / 20050 of the production root folder. Every instance is shut down with `adb shell sync` first.

## How to run

PowerShell 7 (`pwsh`); the helper scripts use Python 3.12.

```powershell
pwsh -NoProfile -File regress.ps1 -Suite suites\release.psd1 -Scope emulator -Sdk <new SDK> -Baseline <SDK of the previous release>
pwsh -NoProfile -File regress.ps1 -Suite suites\release.psd1 -Scope manager,ime -Sdk <SDK>
pwsh -NoProfile -File regress.ps1 -Suite suites\release.psd1 -Sdk <SDK> -Only yys,datadisk
pwsh -NoProfile -File regress.ps1 -Suite suites\release.psd1 -Scope emulator -Sdk <SDK> -DryRun
```

**Run what you changed**: the `Scopes` list at the top of the suite names the scopes of a change (`emulator`, `bridge`, `manager`, `ime`,
`scripts`, `repack`), and each item's `Scopes` says which scopes it covers. `-Scope` runs the items that overlap with it. When the suite has scopes, you must give `-Scope` or `-Only`.
`PostPackage` lists the items to run after packaging, using the package staging folder (upgrade, `ime-pkg`), and at the end the runner reminds you of them according to the scopes. Run with `-DryRun` first to see which items will run and which local settings they use.

**Frame rate of the game items**: by default `items\game-real.ps1` runs only the round with the bridge installed, and the median frame rate is compared with `baselines\fps.json` (the numbers of the previous production version, with a tolerance for each game).
When the same machine runs more than 2 other emulators, it only records the number and does not judge it. After each release regression passes, write this version's numbers back to `fps.json`.

By default the output goes to `<TempRoot>\regress-<build>-<time>\` (when the local configuration has `TempRoot`, `-Out` must also be under it): the console output of each item `<item>.console.txt`,
the item's own output `<item>\`, the overall log `regress.log`, `results.json` and `results.md`. If any item is not "passed", the exit code is 1.
The start of the log records which build was tested: the hash of the manager's CLI, the commit of the repository that holds the bundled scripts, and the commit of this repository.

`-Manager` is the folder that holds `tools\modavd.exe` and `ModAVD.exe` (the `build.ps1 -Out` of ModAVDManager, or an unpacked release package). For the release regression, use the build that is going to ship in the package.
`-PackageScripts` is the `package\` of the ModAVD repository; for the release regression, use the one in the release clone. Both can go into the local configuration.

## Local configuration

The repository hard-codes no local paths. Local things such as the test machine and external tools go into the local configuration: copy [`local.example.psd1`](local.example.psd1) to `local.psd1` in the same folder
(`.gitignore` blocks it, so it is never committed) and fill it in following the comments, or keep it outside the repository and point to it with the environment variable `MODAVD_E2E_CONFIG`.
The reading rules are in [`local.ps1`](local.ps1): parameters take priority, then the local configuration; if neither has a value, it fails with an error and never guesses a default.
The suite refers to keys with `{Local:<key>}`, and the item scripts take their defaults from here when run on their own. For keys that are not set, `-DryRun` lists them, and in a real run an item that needs one is marked "skipped".

| Key | What it is | Used by |
| --- | --- | --- |
| `TempRoot` | The root folder for temporary output | runner, all items |
| `Manager` | The folder that holds `tools\modavd.exe` and `ModAVD.exe` | runner, all items |
| `PackageScripts` | The `package\` of the ModAVD repository (the bridge install script `modavd-bridge.ps1` is in it) | runner, bridge, upgrade, game-real |
| `TestRoot` | The ModAVD root folder used for testing (private adb port; instance 0 has the bridge installed and is logged in with the *Onmyoji* test account; the other numbers are created temporarily and deleted after the run) | bridge, bridge-default, datadisk, yys |
| `PrevPackage` | The package staging folder of the previous production version (a fixed copy) | upgrade |
| `OfficialSdk` | The official SDK (`platform-tools`, `system-images`); the newly built root folder links to it, in place of the download of "fetch the Google components" | upgrade, ime-pkg |
| `Launcher` | The launcher `avd-p0.ps1` (starts an AVD headless or windowed, with parameters such as `-AdbPort` and `-VulkanFix`) | game-real, ime |
| `Monitor` | The sampling script `emu_monitor.py` (one line every 30 s: frame rate, restarts, crashes, ANRs, Vulkan errors) | game-real |
| `VulkanFixLib` | The guest Vulkan fix library | game-real |
| `GameAvdHome` / `SrAvdHome` / `ImeAvdHome` | The `ANDROID_AVD_HOME` of the game instances `mas_6`, `mas_7` and `endfield`, of the *Honkai: Star Rail* instance `gfx_t2`, and of the IME smoke-test instance `imesmoke` | game-real, bench, ime |
| `Kit` | The driver folders for *Arknights* (MAA) and *Reverse: 1999* (M9A) | ark, r1999 |
| `SrcDir` / `SrcKit` | The folders that hold StarRailCopilot and its stress-test driver `stress.py` | sr |
| `MaaEndDir` | The folder that holds the MaaEnd driver `maaend-run.ps1` for *Arknights: Endfield* | ef |
| `MaaYYs` | The run folder of MaaYYs (`interface.json`, `maafw\`, `tasks\`) | yys |
| `Coldprof` | The cold-boot sampling script `coldprof.ps1` for *Arknights: Endfield* | ef-ab |
| `Bench` / `ShimDll` | The health-check bench `bench.ps1` and the screenshot shim dll it uses | bench |
| `ImeTestApk` / `DevImeApk` / `BuildTools` | The IME test APK, the same IME signed with the development key, and Android build-tools 36.1.0 (`apksigner`) | ime-pkg |

`suites\release.psd1` is the suite for the maintainer's Windows test machine. The owners of other platforms write their own suites after it (put them under `suites\`):
the runner (`regress.ps1`) and `items\common.ps1` are not tied to a platform, so write the item scripts and the test machine for your own environment, and likewise put local things into the local configuration.

## What the runner does

- It is single-threaded and runs the items one by one. Before each item starts, it waits until the host's free physical memory is ≥ `NeedFreeGB` (default 8) and the commit headroom is ≥ `NeedCommitGB` (default 12),
  checking once a minute, for at most `MaxWaitHours` (default 3) hours. The test machine may have other emulators running.
- Time windows in `Avoid` (`'HH:mm-HH:mm'`) are not run and are marked "skipped". For example, the test account is used elsewhere at a fixed time every day.
- Each item runs in a child process, with output forced to UTF-8. The time limit is `TimeoutMin` (default 40). On a timeout it stops right there and none of the later items run: the item that timed out may still be holding an instance.
- The count of GPU driver resets (nvlddmkm) in the system log during the run is recorded in the results. Whether it counts as a failure is for a person to judge.
- At the end, it checks whether any qemu is left on the test machines listed in the suite's `Avds`.

## Fields of each suite item

| Field | Meaning |
| --- | --- |
| `Id` / `Title` / `Criterion` | The number; the "item" and "criterion" columns of the table |
| `Script` / `Args` | The script to run and its arguments. Placeholders: `{Sdk}` `{Baseline}` `{Label}` `{Out}` `{ItemOut}` `{Repo}` (the root folder of this repository); `{Local:<key>}` takes the value from the local configuration |
| `TimeoutMin` `NeedFreeGB` `NeedCommitGB` `MaxWaitHours` `Avoid` | See above |
| `NeedsBaseline` | Needs a comparison build (A/B); skipped when `-Baseline` is not given |
| `ExitCode` | The expected exit code, 0 by default; `'any'` means ignore the exit code and look only at `Pass` / `Fail` |
| `Pass` / `Fail` | Regular expressions: every `Pass` pattern must appear in the output, and no `Fail` pattern may appear |
| `Summary` | A regular expression: the summary in the results column is the last match (the capture group, if there is one) |

## Writing a new item

If the script prints a result line at the end, the runner does not look at `Pass` / `Fail`:

```
REGRESS-RESULT {"pass":true,"summary":"reached the login page in 41 s; in game 52.7 fps / average 21.1 ms / slowest 33 ms"}
```

`items\common.ps1` is there for new items: `Set-RootSdk` temporarily points the test root's `mas-avd.json` at the SDK under test and switches it back when done; `M` calls the test root's `modavd.exe`,
with the same post-boot setup as the product, and shuts down cleanly first, falling back to sync if that does not work; `A` / `Su` use the test root's private adb; `Result` prints the result line; `Use-Local` reads the local configuration.
In the game UI, do only fixed operations such as "launch" and "tap Enter Game". When the screen has to be recognized, the script reads the pixels itself (`yys.ps1` recognizes the age-rating badge at the lower left of the login page, at both positions) and does not hand screenshots to a model to look at.

## Existing items (`suites\release.psd1`)

| Item | Script | Notes |
| --- | --- | --- |
| bench | The `Bench` key of the local configuration | Health check; an ERROR in net does not count when the host has no test server running |
| ime | `items\ime-reg.ps1` | The 20 checks of the host IME channel. The `-Attach` parameter set (`-AdbPort` `-Serial` `-EmulatorLog`, optionally `-AdbExe` `-TestApk`) lets ime-pkg run it against a running instance; without it, the item starts `imesmoke` and runs on its own |
| bridge-default | `items\bridge-default.ps1` | A new instance gets the bridge installed by default; uninstall / install with `modavd bridge`; it creates instance 7 and deletes it after the run |
| ark / r1999 / sr / ef | `items\game-real.ps1` | A 15-minute real run of each game with its own automation scripts (the round with the bridge installed), with the frame rate compared with `baselines\fps.json` |
| bridge | `items\bridge.ps1` | The whole flow of installing / uninstalling the bridge (Windows PowerShell 5.1); it creates instance 6 and deletes it after the run |
| datadisk | `items\datadisk.ps1` | The inode cap on a new disk and growing with `set --data-gb`; it creates instance 3 and deletes it after the run |
| upgrade | `items\upgrade.ps1` | Builds a root folder from the previous release package, creates an instance and writes data, overlays the new package following "How to update", then checks boot, data, growing the disk, and that a normal boot installs the bridge automatically. When `-Next` is a package staging folder (with `components\modavd-ime.apk`), it also checks that the host IME came with the package, that the installed one is the officially signed one, and that it is set as the default (not checked when `-Next` is an SDK). The root folder is deleted after the run |
| yys | `items\yys.ps1` | *Onmyoji* cold-boots into the game and the frame rate is measured (instance 0 of the test root, bridge installed, already logged in); then MaaYYs (`items\maayys_run.py`) really fights Mitama battles |
| ef-ab | `items\ef-ab.ps1` | *Arknights: Endfield* cold boots, alternating new and old builds; it measures only when the host is idle |

Not in the suite; run separately after packaging:

| Item | Script | Notes |
| --- | --- | --- |
| ime-pkg | `items\ime-pkg.ps1` | `-Package <package staging folder>` (`release\ModAVD-<version>-win-x64`, read-only): copies it as a root folder and creates instance 9, checks that the officially signed IME is installed automatically on boot and set as the default, runs the 20 channel checks windowed, then checks that a development-signed IME is replaced by the officially signed one and that the steady state does not change. The root folder is deleted after the run, and the log is kept under `-Work` |

## When there is a dedicated test machine

You can register it as a self-hosted runner of this repository, and trigger the whole regression suite on a schedule or by hand. The runner is attached only to this repository, not to the main ModAVD repository.
It is **not triggered by external PRs**; it runs only on a schedule, on a manual trigger by the maintainer (`workflow_dispatch`), and on pushes to protected branches. In the organization's runner group, it is limited to the workflows named for this repository.
That machine holds only test instances and test accounts: no production, and no personal accounts logged in.

## License

GNU Affero General Public License version 3 or later (AGPL-3.0-or-later); the full text is in [LICENSE](LICENSE). Copyright 2026 qiyinxi.
