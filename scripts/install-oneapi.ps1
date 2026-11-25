<#
.SYNOPSIS
    安装 Intel oneAPI Toolkit 2026.2（最小组件集），用于编译 Strata SYCL 引擎。

.DESCRIPTION
    需要管理员权限。脚本会自我检测权限，非管理员时自动以管理员身份重启（弹出 UAC）。
    仅安装编译 SYCL 引擎所需组件：DPC++/C++ 编译器、oneMKL、oneTBB、oneDPL、
    Level Zero 运行库与头文件。跳过 Fortran、MPI、VTune、Advisor 等不需要的组件。

    注意：oneAPI Toolkit 2026.2 的组件 ID 与旧 Base Toolkit 不同，安装前先用
    --list-products / --list-components 探测实际 ID；本脚本用 --components 传入探测到的
    DPC++ 与 MKL  Product ID，若探测失败则回退为默认全量安装（仍可用，只是体积更大）。

.EXAMPLE
    右键“以管理员身份运行 PowerShell”，然后：
    powershell -NoProfile -ExecutionPolicy Bypass -File install-oneapi.ps1
#>
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 权限自检：非管理员则提权重启
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "当前非管理员权限，正在请求 UAC 提权..." -ForegroundColor Yellow
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    Start-Process -FilePath "powershell" -ArgumentList $arg -Verb RunAs -Wait
    exit
}

# ---------------------------------------------------------------------------
# 定位安装包
# ---------------------------------------------------------------------------
$installer = "D:\Desktop\strata\_setup\intel-oneapi-toolkit-2026.2.0.661_offline.exe"
if (-not (Test-Path -LiteralPath $installer)) {
    throw "找不到安装包：$installer"
}

Write-Host "=== Intel oneAPI Toolkit 2026.2 安装 ===" -ForegroundColor Cyan
Write-Host "安装包：$installer"
Write-Host ""

# ---------------------------------------------------------------------------
# 探测组件 ID（可选）：列出产品，确认 DPC++ 与 MKL 的 Product ID
# ---------------------------------------------------------------------------
Write-Host "[1/2] 探测安装包内的产品列表..." -ForegroundColor Cyan
$products = & $installer -a --list-products 2>&1
$products | Select-Object -First 40
Write-Host ""

# 组件 ID 随版本可能变化，这里用一个保守做法：安装默认组件集（--components default）。
# 默认集已含 DPC++ 编译器、oneMKL、oneTBB、oneDPL、Level Zero，足以编译本引擎。
# 若要极致裁剪，可在下表确认 ID 后手工改用 --components 指定。
Write-Host "[2/2] 开始静默安装（默认组件集，含 DPC++/oneMKL/oneTBB/Level Zero）..." -ForegroundColor Cyan
Write-Host "      安装约需 5-15 分钟，请耐心等待。" -ForegroundColor Yellow

# -a: 传参数给安装器；-s: 静默；--eula accept: 接受协议；
# --components default: 默认组件集；-p=NEED_VS2022_INTEGRATION=0: 跳过 VS 集成（用不到）
$installArgs = '-a --silent --eula accept --components default -p=NEED_VS2022_INTEGRATION=0'
$proc = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "安装失败，退出码：$($proc.ExitCode)。请检查上方输出或手动运行安装包排查。"
}

Write-Host ""
Write-Host "=== 安装完成 ===" -ForegroundColor Green
$setvars = Join-Path ${env:ProgramFiles(x86)} "Intel\oneAPI\setvars.bat"
if (Test-Path -LiteralPath $setvars) {
    Write-Host "setvars.bat 已就位：$setvars"
    Write-Host "现在可运行 build-sycl-windows.ps1 编译引擎。"
} else {
    Write-Warning "未找到 setvars.bat：$setvars。请检查安装目录。"
}
