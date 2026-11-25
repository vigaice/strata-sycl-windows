# ============================================================================
# 收集 strata.exe 运行所需的 SYCL/MKL 运行时到构建目录（app-local 部署）
#
# 背景：strata.exe 动态链接 sycl9.dll 与 mkl_sycl_blas.6.dll，Windows 上必须
#       把这些 DLL 放在 exe 同目录或 PATH 中。参考官方 0.1.57 分发包的布局：
#       核心 SYCL 运行时平铺在 exe 旁边，MKL/TBB/DNNL 放 oneapi\bin 子目录。
#
# 关键陷阱：libhwloc-15.dll 缺失时，UR 的 Level Zero 适配器会静默初始化失败，
#          表现为 sycl-ls 只能看到 opencl 设备、引擎退回 OpenCL 路径。
#          该文件不在 compiler\latest\bin 中，必须单独从 tcm 组件取。
#
# 说明：不需要复制 Intel 显卡的 Level Zero 厂商驱动（ze_intel_gpu64.dll）。
#      系统 System32 的 ze_loader.dll 会通过驱动注册信息找到 DriverStore 中的驱动。
# ============================================================================
param(
    [string]$BuildDir = '',
    # oneAPI 根目录（换版本编译时指向对应根，DLL 才不会混用另一版本）
    [string]$OneApiRoot = "",
    # 组件版本目录名（2026.1 / 2026.2 等）。指定后锁定该版本，不跟随 latest 链接。
    [string]$OneApiVersion = ""
)

$ErrorActionPreference = 'Stop'
if (-not $BuildDir) { $BuildDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'build-sycl-windows' }

$oa = if ($OneApiRoot) { $OneApiRoot } else { "${env:ProgramFiles(x86)}\Intel\oneAPI" }
if (-not (Test-Path -LiteralPath $oa)) { throw "找不到 oneAPI 安装目录：$oa" }

# 组件 bin 目录：指定了版本就锁定该版本；否则优先 latest，没有就取最高版本目录
function Resolve-Bin {
    param([string]$Name)
    $base = Join-Path $oa $Name
    if ($OneApiVersion) {
        $pinned = Join-Path $base "$OneApiVersion\bin"
        # tbb / dnnl 不按 oneAPI 年份编号（如 tbb 2023.1、dnnl 2026.0），
        # 这类组件没有对应版本目录时退回 latest
        if (Test-Path -LiteralPath $pinned) { return $pinned }
    }
    $latest = Join-Path $base 'latest\bin'
    if (Test-Path -LiteralPath $latest) { return $latest }
    $ver = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '^\d+\.\d+' } |
           Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } -Descending |
           Select-Object -First 1
    if ($ver) { return (Join-Path $ver.FullName 'bin') }
    return $null
}

$compilerBin = Resolve-Bin 'compiler'
$mklBin      = Resolve-Bin 'mkl'
$tbbBin      = Resolve-Bin 'tbb'
$dnnlBin     = Resolve-Bin 'dnnl'
if (-not $compilerBin) { throw "找不到 compiler 组件目录：$oa" }

# Intel oneAPI 的部分 bin 文件是符号链接，PowerShell 复制时需解引用真实内容
function Copy-Real {
    param([string]$Source, [string]$DestDir)
    if (-not (Test-Path -LiteralPath $Source)) { Write-Host "  [缺失] $Source"; return $false }
    $item = Get-Item -LiteralPath $Source -Force
    if ($item.LinkType) {
        $target = $item.Target
        if ($target -and -not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path $item.DirectoryName $target
        }
        $target = [System.IO.Path]::GetFullPath($target)
        Copy-Item -LiteralPath $target -Destination (Join-Path $DestDir $item.Name) -Force
    } else {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $DestDir $item.Name) -Force
    }
    return $true
}

New-Item -ItemType Directory -Path (Join-Path $BuildDir 'oneapi\bin') -Force | Out-Null

# ---------------------------------------------------------------------------
# 1) exe 同目录：SYCL 运行时 + 数学库 + VC 运行库
# ---------------------------------------------------------------------------
Write-Host '[1/3] 复制 SYCL 运行时到 exe 目录...'
# ur_loader_shared.dll 是 2026.2 的命名，2026.1 及更早叫 ur_loader.dll（官方 0.1.57 包里就是后者）。
# 两者都试，缺的那一项静默跳过即可，但至少要有一个，否则 SYCL 起不来。
$rootDlls = @(
    'sycl9.dll',
    'sycl-jit.dll',
    'ur_loader_shared.dll',
    'ur_loader.dll',
    'ur_win_proxy_loader.dll',
    'ur_adapter_level_zero.dll',
    'ur_adapter_level_zero_v2.dll',
    'umf.dll',
    'libmmd.dll',
    'svml_dispmd.dll'
)
$haveLoader = $false
foreach ($d in $rootDlls) {
    if ($d -like 'ur_loader*') {
        if (Copy-Real -Source (Join-Path $compilerBin $d) -DestDir $BuildDir) { Write-Host "  OK $d"; $haveLoader = $true }
        continue
    }
    if (Copy-Real -Source (Join-Path $compilerBin $d) -DestDir $BuildDir) { Write-Host "  OK $d" }
}
if (-not $haveLoader) { Write-Host '  [警告] 没找到 ur_loader.dll / ur_loader_shared.dll，SYCL 运行时可能无法加载' }

# libhwloc-15.dll：UR Level Zero 适配器的拓扑依赖，缺失会导致 L0 静默不可用
# tcm 组件的版本号随 oneAPI 版本变化（2026.1 与 2026.2 不同），因此用通配匹配
$hwlocCandidates = @(
    (Join-Path $oa 'tcm\1.6\bin\libhwloc-15.dll'),
    (Join-Path $oa '2026.2\bin\libhwloc-15.dll')
)
$hwlocCandidates += Get-ChildItem -LiteralPath (Join-Path $oa 'tcm') -Directory -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending |
                    ForEach-Object { Join-Path $_.FullName 'bin\libhwloc-15.dll' }
$hwloc = $hwlocCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($hwloc) {
    Copy-Real -Source $hwloc -DestDir $BuildDir | Out-Null
    Write-Host "  OK libhwloc-15.dll"
} else {
    Write-Host '  [警告] 找不到 libhwloc-15.dll，Level Zero 将不可用！'
}

# ---------------------------------------------------------------------------
# 2) exe 同目录：VC++ 运行库（/MD 动态 CRT）
# ---------------------------------------------------------------------------
Write-Host '[2/3] 复制 VC++ 运行库...'
$vcRedistBase = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Redist\MSVC"
$vcDirs = @()
if (Test-Path -LiteralPath $vcRedistBase) {
    $vcDirs = Get-ChildItem -LiteralPath $vcRedistBase -Directory |
              Sort-Object Name -Descending |
              ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' }
}
$vcCopied = $false
foreach ($dir in $vcDirs) {
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
            $src = Join-Path $dir $f
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $BuildDir -Force; $vcCopied = $true }
        }
        if ($vcCopied) { break }
    }
}
if ($vcCopied) { Write-Host '  OK msvcp140 / vcruntime140 / vcruntime140_1' }
else { Write-Host '  [警告] 未找到 VC 运行库，目标机需自行安装 VC++ 2015-2022 运行库' }

# ---------------------------------------------------------------------------
# 3) oneapi\bin：MKL / TBB / DNNL（体积大，单独放子目录）
# ---------------------------------------------------------------------------
Write-Host '[3/3] 复制 MKL / TBB / DNNL 到 oneapi\bin...'
$subDir = Join-Path $BuildDir 'oneapi\bin'
$count = 0
foreach ($bin in @($mklBin, $tbbBin, $dnnlBin)) {
    if (-not (Test-Path -LiteralPath $bin)) { continue }
    Get-ChildItem -LiteralPath $bin -Filter '*.dll' -File -Force | ForEach-Object {
        if (Copy-Real -Source $_.FullName -DestDir $subDir) { $count++ }
    }
}
Write-Host "  OK $count 个 DLL"

Write-Host ''
Write-Host '运行时收集完成。'
Write-Host "  exe 目录 DLL：$((Get-ChildItem -LiteralPath $BuildDir -Filter '*.dll').Count) 个"
Write-Host "  oneapi\bin DLL：$((Get-ChildItem -LiteralPath $subDir -Filter '*.dll').Count) 个"
Write-Host ''
Write-Host '运行方式：把 exe 目录与 oneapi\bin 加入 PATH，或用 run-strata.ps1 启动。'
