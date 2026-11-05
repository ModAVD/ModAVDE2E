# Measure a new data disk

This opt-in Windows measurement uses a fresh root and a local game APK. It is not part of the release suite. Use a verified release package, an SDK with `platform-tools` and `system-images`, and a new `Work` path. The script copies the package and SDK components into that path. Choose an unused port range; do not run other tests on the instance.

```powershell
pwsh -NoProfile -File items/created-disk-usage.ps1 -Action Create -Work <new-path> -Package <unpacked-release> -OfficialSdk <sdk> -PortBase 27300 -AdbPort 27383 -ScriptAdbPort 27384 -DataGB 64
pwsh -NoProfile -File items/created-disk-usage.ps1 -Action Install -Work <new-path> -Apk <game.apk> -Game <game-name> -PackageId <android-package-id>
```

`Create` records the qcow2 immediately after `modavd create` finishes its background initialization and shuts down. It then starts the instance with a window and records `/data` before installation. It requires 1,048,576 inodes before proceeding. `Install` records the APK hash, verifies that adb reports success and the specified package exists, then records the APK-only state.

If installation fails, keep the original output and take a fresh baseline with `-Action Baseline`. If the instance was stopped, use `-Action Resume` to restart it and take that baseline. Retry `Install` with the same APK and package ID. Add `-NoStreaming` to use adb's non-streaming installation. Report earlier failed attempts and use the last baseline for the comparison.

To measure downloaded resources, use the game window to download them and reach the intended screen without logging in. Then record the observed stage:

```powershell
pwsh -NoProfile -File items/created-disk-usage.ps1 -Action Sample -Work <new-path> -Stage 'resources downloaded, login page'
pwsh -NoProfile -File items/created-disk-usage.ps1 -Action Stop -Work <new-path>
```

`measurement.json` contains timestamps, package version, configured data disk size, qcow2 file length, Windows file allocation, virtual disk size, and each `/data` sample. `spaceKiB` is in 1,024-byte units; inode values are counts. Allocation can differ from file length for sparse or compressed files. Neither is the virtual capacity. Record the package archive checksum and the actual game version separately, and describe the observed resource-download stage rather than assuming that an APK includes all resources.

Keep the root and output for inspection. Stop only this instance and its private adb servers when finished. The script never deletes the root. Do not publish the APK, downloaded resources, or instance data.
