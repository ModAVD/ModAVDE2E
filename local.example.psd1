# 本机配置示例（local.ps1 读它）。复制成同目录的 local.psd1 再填（local.psd1 不进 git），
# 或者放在仓库外、用环境变量 MODAVD_E2E_CONFIG 指过去。
# 留空就是没设：套件里用到它的项不跑（-DryRun 会列出来），单独跑某一项时要你在命令行上给对应参数。路径一律写绝对路径。
@{
    # 临时输出的根目录：回归输出默认在 <TempRoot>\regress-<构建>-<时间>
    TempRoot     = ''
    # 生产根目录（AUTO-MAS 在用的 ModAVD 根目录）：测试根、回归输出、工作目录落在它下面就停；不写就是 D:\ModAVD。
    # 生产占着的 adb 端口 5037、20049、20050 也一律拒绝
    ProductionRoots = @()

    # ---- 被测的东西
    # 管理器（放着 tools\modavd.exe 和 ModAVD.exe 的目录）不在这里配：regress.ps1 必须传 -Manager，单独跑某一项时设环境变量
    # MODAVD_REGRESS_MANAGER。本机留一份旧管理器在配置里，会让不认 portBase 的版本把测试根的实例开到生产的 20000 段上。
    # ModAVD 仓库的 package\（随包脚本，装桥脚本 modavd-bridge.ps1 在里面）；发版回归用发版克隆里的那份
    PackageScripts = ''
    # 上一个生产版的组包目录（升级项的起点，放一份固定副本）
    PrevPackage  = ''

    # ---- 测试机
    # 测试用的 ModAVD 根目录：E:\testbed 下已有的 flow-a / flow-b（11-05 起回归不新建根目录，实例都建在它们里面）。
    # mas-avd.json 要设 portBase 和私有 adb 端口；0 号已装桥、登着测试号，其余编号由各项临时建、跑完删
    TestRoot     = ''
    # 装包类的项（upgrade、ime-pkg）用的测试根：先把它装成要测的包（升级先装回上一版），在里面建临时实例，测完只删实例、
    # 根目录停在新包上。不写就用 TestRoot
    PackageRoot  = ''
    # 游戏实例 mas_6 / mas_7 / endfield、星铁实例 gfx_t2、输入法冒烟机 imesmoke 的 ANDROID_AVD_HOME
    # 游戏实例（game-real）的控制台端口，默认 ark 20072、r1999 20100、sr 20120、ef 20096；要改写成 @{ sr = 20130 } 这样，
    # 只写要改的游戏。端口和它 +1、+2（adb、gRPC）不能落在生产的 20000–20049 上，也不能是 5037、20049、20050，否则报错停下
    GamePorts    = @{}
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
