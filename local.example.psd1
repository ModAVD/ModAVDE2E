# 本机配置示例（local.ps1 读它）。复制成同目录的 local.psd1 再填（local.psd1 不进 git），
# 或者放在仓库外、用环境变量 MODAVD_E2E_CONFIG 指过去。
# 留空就是没设：套件里用到它的项不跑（-DryRun 会列出来），单独跑某一项时要你在命令行上给对应参数。路径一律写绝对路径。
@{
    # 临时输出的根目录：回归输出默认在 <TempRoot>\regress-<构建>-<时间>，设了以后 -Out 也必须在它下面
    TempRoot     = ''

    # ---- 被测的东西
    # 放着 tools\modavd.exe 和 ModAVD.exe 的目录（ModAVDManager 的 build.ps1 -Out，或解开的 Release 包）
    Manager      = ''
    # ModAVD 仓库的 package\（随包脚本，装桥脚本 modavd-bridge.ps1 在里面）；发版回归用发版克隆里的那份
    PackageScripts = ''
    # 上一个生产版的组包目录（升级项的起点，放一份固定副本）
    PrevPackage  = ''
    # 官方 SDK（platform-tools、system-images），新搭的根目录链到它，代替「补全组件」的下载
    OfficialSdk  = ''

    # ---- 测试机
    # 测试用的 ModAVD 根目录（私有 adb 端口；0 号已装桥、登着测试号，其余编号由各项临时建、跑完删）
    TestRoot     = ''
    # 游戏实例 mas_6 / mas_7 / endfield、星铁实例 gfx_t2、输入法冒烟机 imesmoke 的 ANDROID_AVD_HOME
    GameAvdHome  = ''
    SrAvdHome    = ''
    ImeAvdHome   = ''

    # ---- 仓库外的工具
    # 启动器 avd-p0.ps1、采样脚本 emu_monitor.py、客体 Vulkan 修复库
    Launcher     = ''
    Monitor      = ''
    VulkanFixLib = ''
    # 体检台 bench.ps1 和它用的截图垫片 dll
    Bench        = ''
    ShimDll      = ''
    # 各游戏的自动化驱动：MAA / M9A 的驱动目录、StarRailCopilot 和它的压测驱动、MaaEnd、MaaYYs、终末地冷启动采样
    Kit          = ''
    SrcDir       = ''
    SrcKit       = ''
    MaaEndDir    = ''
    MaaYYs       = ''
    Coldprof     = ''
    # 输入法测试 APK（ModAVDHostIME 编的）、开发签名的同一个输入法、Android build-tools 36.1.0
    ImeTestApk   = ''
    DevImeApk    = ''
    BuildTools   = ''
}
