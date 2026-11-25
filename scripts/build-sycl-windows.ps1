<#
.SYNOPSIS
    在 Windows 上编译 Strata 官方最新版 SYCL 引擎（icx + Ninja）。

.DESCRIPTION
    依赖：Intel oneAPI Toolkit 2026.1+（含 DPC++/C++ 与 oneMKL）、CMake 3.24+、
    Ninja、Visual Studio C++ 桌面工具、Windows SDK。

    环境初始化采用“手动设置 INCLUDE/LIB/PATH”的方式，不调用 oneAPI 的 setvars.bat。
    原因：setvars.bat 内部会调用 reg.exe 探测 VS 路径，在受限环境中会被安全策略拦截；
    手动设置等效的环境变量可完全绕开，且编译产物一致。

    默认配置：
      - STRATA_PORTABLE=ON       便携式构建，AVX2 基线
      - STRATA_SYCL_PARITY=OFF   跳过内核自检测试（需显卡）
      - STRATA_SYCL_AOT 默认空    JIT 编译 SPIR-V；指定 bmg-g21 可为 B580 等做 AOT

.PARAMETER Aot
    AOT 目标，默认空（JIT）。B580/B570/Pro B60 用 bmg-g21；Pro B70 用 bmg-g31。

.PARAMETER Parity
    是否编译内核自检测试，默认关闭。

.PARAMETER Jobs
    并行编译线程数，默认 4。

.PARAMETER OneApiRoot
    oneAPI 根目录。留空用默认安装位置（Program Files (x86)\Intel\oneAPI）。

.PARAMETER OneApiVersion
    组件版本目录名，如 2026.1 / 2026.2。指定后直接用 <根>\compiler\<版本>，
    不再跟随 latest 链接 —— 多个版本并存时这是唯一可靠的方式（安装器会把
    latest 指向最后一次安装的版本）。留空则沿用 latest，没有 latest 取最高版本。

.PARAMETER BuildDir
    构建输出目录名，默认 build-sycl-windows。换编译器版本时用新目录，
    避免 CMake 缓存里记录的仍是旧编译器路径。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File build-sycl-windows.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File build-sycl-windows.ps1 -Aot bmg-g21
    powershell -NoProfile -ExecutionPolicy Bypass -File build-sycl-windows.ps1 `
        -OneApiVersion "2026.1" -BuildDir "build-sycl-2026.1"
#>
param(
    [string]$Aot = "",
    [switch]$Parity,
    [int]$Jobs = 4,
    # oneAPI 根目录。留空用默认安装位置。
    [string]$OneApiRoot = "",
    # 组件版本目录名（2026.1 / 2026.2 等）。指定后锁定该版本，不受 latest 链接影响。
    [string]$OneApiVersion = "",
    # 构建输出目录名（相对仓库根）。换编译器版本时用新目录，避免 CMake 缓存记录旧编译器。
    [string]$BuildDir = "build-sycl-windows"
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 路径定义
# ---------------------------------------------------------------------------
$repoRoot = Split-Path -Parent $PSScriptRoot
$engineDir = Join-Path $repoRoot "engine"
$syclDir = Join-Path $engineDir "sycl"
$buildDir = Join-Path $repoRoot $BuildDir
$oneApi = if ($OneApiRoot) { $OneApiRoot } else { Join-Path ${env:ProgramFiles(x86)} "Intel\oneAPI" }

# 解析组件版本目录：指定了 -OneApiVersion 就锁定该版本；否则优先 latest 链接，
# 没有 latest 就取最高版本号目录
function Resolve-Component {
    param([string]$Root, [string]$Name)
    $base = Join-Path $Root $Name
    if ($OneApiVersion) {
        $pinned = Join-Path $base $OneApiVersion
        # tbb / dnnl 不按 oneAPI 年份编号（如 tbb 2023.1、dnnl 2026.0），
        # 这类组件没有对应版本目录时退回 latest
        if (Test-Path -LiteralPath $pinned) { return $pinned }
    }
    $latest = Join-Path $base "latest"
    if (Test-Path -LiteralPath $latest) { return $latest }
    if (-not (Test-Path -LiteralPath $base)) { return $null }
    $ver = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '^\d+\.\d+' } |
           Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } -Descending |
           Select-Object -First 1
    if ($ver) { return $ver.FullName }
    return $null
}

# 探测 oneAPI 组件根目录
$cmpRoot = Resolve-Component $oneApi "compiler"
$mklRoot = Resolve-Component $oneApi "mkl"
$tbbRoot = Resolve-Component $oneApi "tbb"
$dnnlRoot = Resolve-Component $oneApi "dnnl"
$oclocRoot = Resolve-Component $oneApi "ocloc"
foreach ($p in @($cmpRoot, $mklRoot)) {
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { throw "缺少 oneAPI 组件目录（根：$oneApi）：$p" }
}
$icx = Join-Path $cmpRoot "bin\icx.exe"
if (-not (Test-Path -LiteralPath $icx)) { throw "找不到 icx：$icx" }

# 探测 Visual Studio MSVC 与 Windows SDK（用于 CRT 头文件与库）
$vsBase = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC"
$vsVer = (Get-ChildItem -LiteralPath $vsBase -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$msvc = Join-Path $vsVer "include"
$msvcLib = Join-Path $vsVer "lib\x64"
$sdkBase = "${env:ProgramFiles(x86)}\Windows Kits\10"
$sdkVer = (Get-ChildItem -LiteralPath (Join-Path $sdkBase "Include") -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$sdkInc = Join-Path $sdkBase "Include\$sdkVer"
$sdkLib = Join-Path $sdkBase "Lib\$sdkVer"
foreach ($p in @($msvc, $msvcLib, $sdkInc, $sdkLib)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "缺少编译依赖目录：$p" }
}
# oneAPI 的 SYCL STL wrapper 用 #include_next 找 crtdbg.h/stdio.h，必须让 ucrt 头文件进入搜索链
$ucrtInc = Join-Path $sdkInc "ucrt"
$sharedInc = Join-Path $sdkInc "shared"

# Level Zero 导入库
$zeLibCandidates = @(
    "C:\Program Files\LevelZeroSDK\1.32.0\lib\ze_loader.lib",
    (Join-Path $cmpRoot "lib\ze_loader.lib")
)
$zeLib = $null
foreach ($c in $zeLibCandidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { $zeLib = $c; break }
}
if (-not $zeLib) { throw "找不到 ze_loader.lib，无法链接 Level Zero。" }

# ---------------------------------------------------------------------------
# 设置环境变量（等效于 setvars + vcvars64，但绕开 reg.exe）
# ---------------------------------------------------------------------------
$incDirs = @(
    $msvc,
    $ucrtInc,
    $sharedInc,
    (Join-Path $sdkInc "um"),
    (Join-Path $cmpRoot "include"),
    (Join-Path $mklRoot "include"),
    (Join-Path $tbbRoot "include"),
    (Join-Path $dnnlRoot "include")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
$env:INCLUDE = ($incDirs -join ';')

$libDirs = @(
    $msvcLib,
    (Join-Path $sdkLib "ucrt\x64"),
    (Join-Path $sdkLib "um\x64"),
    (Join-Path $cmpRoot "lib"),
    (Join-Path $mklRoot "lib"),
    (Join-Path $tbbRoot "lib"),
    (Join-Path $dnnlRoot "lib")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
$env:LIB = ($libDirs -join ';')

# 探测 CMake / Ninja（本机经 WinGet / Python Scripts 安装，可能不在系统 PATH 中）
$cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCmd) {
    $cmakeExe = $cmakeCmd.Source
} else {
    $winget = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Kitware.CMake_*\cmake-*\bin\cmake.exe" -File -Recurse -ErrorAction SilentlyContinue |
              Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $winget) { throw "找不到 cmake，请确认已安装。" }
    $cmakeExe = $winget.FullName
}
$cmakeBin = Split-Path -Parent $cmakeExe
$ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
if ($ninjaCmd) {
    $ninjaExe = $ninjaCmd.Source
} else {
    $pyScripts = Join-Path $env:LOCALAPPDATA "Programs\Python\Python314\Scripts"
    $ninjaCandidate = Join-Path $pyScripts "ninja.exe"
    if (-not (Test-Path -LiteralPath $ninjaCandidate)) { throw "找不到 ninja，请确认已安装。" }
    $ninjaExe = $ninjaCandidate
}
$ninjaBin = Split-Path -Parent $ninjaExe

$pathDirs = @(
    (Join-Path $cmpRoot "bin"),
    (Join-Path $mklRoot "bin"),
    (Join-Path $tbbRoot "bin"),
    (Join-Path $dnnlRoot "bin"),
    $oclocRoot ? (Join-Path $oclocRoot "bin") : $null,
    (Join-Path $vsVer "bin\Hostx64\x64"),
    (Join-Path $sdkBase "bin\$sdkVer\x64"),   # rc.exe / mt.exe 资源编译器
    $cmakeBin,
    $ninjaBin,
    $env:PATH
) | Where-Object { $_ } | Select-Object -Unique
$env:PATH = ($pathDirs -join ';')
Write-Host "cmake: $cmakeBin"
Write-Host "ninja: $ninjaBin"

$env:ONEAPI_ROOT = $oneApi
$env:CMPLR_ROOT = $cmpRoot
$env:MKLROOT = $mklRoot
$env:TBBROOT = $tbbRoot
$env:DNNLROOT = $dnnlRoot

Write-Host "icx: $icx"
Write-Host "oneAPI 组件（$($OneApiVersion ? "锁定 $OneApiVersion" : 'latest')）："
Write-Host "  compiler = $cmpRoot"
Write-Host "  mkl      = $mklRoot"
Write-Host "  tcm      = $(Resolve-Component $oneApi 'tcm')"
Write-Host "MSVC: $vsVer"
Write-Host "Windows SDK: $sdkVer"
Write-Host "Level Zero: $zeLib"

# ---------------------------------------------------------------------------
# CMake 配置
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[1/2] CMake 配置..."
$parityFlag = if ($Parity) { "ON" } else { "OFF" }
# CMake 配置文件里路径必须用正斜杠，否则反斜杠会被当成转义字符
$rcExe = (Join-Path $sdkBase "bin\$sdkVer\x64\rc.exe") -replace '\\', '/'
$mtExe = (Join-Path $sdkBase "bin\$sdkVer\x64\mt.exe") -replace '\\', '/'
$cmakeArgs = @(
    "-S", "$syclDir",
    "-B", "$buildDir",
    "-G", "Ninja",
    "-DCMAKE_MAKE_PROGRAM=$ninjaExe",
    "-DCMAKE_C_COMPILER=$icx",
    "-DCMAKE_CXX_COMPILER=$icx",
    "-DCMAKE_RC_COMPILER=$rcExe",
    "-DCMAKE_MT=$mtExe",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DSTRATA_PORTABLE=ON",
    "-DSTRATA_SYCL_PARITY=$parityFlag",
    "-DSTRATA_ZE_LOADER=$zeLib",
    "-DSTRATA_SYCL_AOT=$Aot"
)
& $cmakeExe @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "CMake 配置失败（退出码 $LASTEXITCODE）。" }

# ---------------------------------------------------------------------------
# 编译
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/2] 编译 strata（Jobs=$Jobs）..."
# 官方最新版只有 strata 目标；strata-device 是 fork 独有，不构建。
& $cmakeExe --build $buildDir --target strata --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw "编译失败（退出码 $LASTEXITCODE）。" }

Write-Host ""
Write-Host "=== 编译完成 ==="
Get-ChildItem -LiteralPath $buildDir -Filter "strata*.exe" | ForEach-Object {
    Write-Host ("{0}  ({1:N1} MB)" -f $_.FullName, ($_.Length / 1MB))
}

# ---------------------------------------------------------------------------
# 收集运行时（app-local 部署）
#   strata.exe 依赖 sycl9.dll / mkl_sycl_blas.6.dll 等，必须与 exe 放在一起。
#   注意 libhwloc-15.dll 缺失会导致 Level Zero 适配器静默失效、退回 OpenCL。
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/3] 收集 SYCL/MKL 运行时到产物目录..."
$packScript = Join-Path $PSScriptRoot "package-runtime.ps1"
if (Test-Path -LiteralPath $packScript) {
    & $packScript -BuildDir $buildDir -OneApiRoot $oneApi -OneApiVersion $OneApiVersion
} else {
    Write-Host "  [警告] 未找到 package-runtime.ps1，跳过运行时收集。"
}

Write-Host ""
Write-Host "=== 下一步 ==="
Write-Host "  运行验证： .\build-sycl-windows\run-strata.ps1 --version"
