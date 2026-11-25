# strata-sycl-windows

[English](README.md) | **简体中文**

Strata 在 Windows 上针对 Intel GPU 的推理引擎：用 MSVC / clang-cl 工具链构建的 SYCL 后端，按引擎组件格式打包，供桌面客户端加载。

> **这是派生分支，不是官方发布。**
> 本仓库只包含 [Niko1221/Strata](https://github.com/Niko1221/Strata) 在提交
> `2af30ccaa0729177c4725ee2073f72bf550e2f86` 上的引擎子树，以及叠在其上的 Windows 移植。与上游项目
> 无隶属关系，未获上游认可，也不由上游提供支持。移植引入的问题请提到本仓库，引擎本身的问题请提到上游。

## 为什么有这个分支

上游的 SYCL 后端在 Linux 上开发和验证。同一份源码在 Windows 上需要不同的工具链（MSVC 兼容模式下的
clang-cl、动态 CRT、没有 `sysfs`），上游有两处对驱动的假设在 Windows 上会静默失效。失效的结果不是编译
报错，而是显卡挂死，所以值得逐条写明：

- B580 接受了 `--pcie-frac 0.55`，GPU 去读可分页的宿主内存，第一个 verify 窗口在第 0 层挂住，显卡空转。
- 带 `--spec` 且存在 MTP 层时，解码窗口在 CPU 供专家的情况下仍沿用 20000 次读的等待上限，CPU 池一卡顿
  就丢弃窗口。

这两处在本分支已修。其余是机械性工作：POSIX 文件调用、`sal.h` 与 `rpcndr.h` 的宏、`/MT` 与 `-fsycl`
的冲突，以及三个 Intel 编译器选项在 clang-cl 下的写法。

## 基线

| | |
| --- | --- |
| 上游 | `https://github.com/Niko1221/Strata` |
| 提交 | `2af30ccaa0729177c4725ee2073f72bf550e2f86` |
| 上游日期 | 2026-11-24 |
| 上游版本 | Control 0.1.68 / Terminal 0.2.21.1 |
| 许可 | MIT（见 `LICENSE`） |

导入引擎的那个提交是上游原样的树，紧随其后的提交是移植，因此 `git diff 2af30ccaa..HEAD` 读出来只有
移植。仓库的第一个提交是 GitHub 建仓时自动生成的，其中留下的 LICENSE 模板已由导入提交替换。

## 仓库内容

| 路径 | 说明 |
| --- | --- |
| `engine/` | 引擎本体：全部后端、SYCL 内核、宿主运行时、测试 |
| `tools/packaging/` | 从二进制产物组装引擎组件的打包工具 |
| `scripts/` | Windows 辅助脚本：构建、运行时 DLL 收集、oneAPI 安装 |
| `patches/terminal-vision-crt-sse41.patch` | 影像工具所需的两处 `CMakeLists.txt` 改动。该工具位于 `terminal/`，本分支未收录 |

### 刻意未收录的部分

桌面客户端（`app/`）、终端（`terminal/`）、文档集（`docs/`）不在本分支内。动手构建前需要知道两点后果：

- `tools/packaging/` 从上游的 `terminal/` 里导入 `strata_control`，而本分支没有该目录。实际影响见下文
  「`strata_control` 依赖」一节。
- `engine/cmake/strata_gpu_engine.cmake` 中有少数测试 target 引用了 `terminal/tools/*`（IQ 夹具生成器、
  HIP 调优工具）。这些 target 只在对应后端与测试开启时才注册，SYCL 构建不需要它们。

## 移植改动，分五组

以下每处改动在源码中都带 `STRATA_WINDOWS_PATCH` 标记，`git grep STRATA_WINDOWS_PATCH` 可一次列出全部
改动及其原因。

### 一、工具链：MSVC、clang-cl、icx

| 改动 | 原因 |
| --- | --- |
| `CMAKE_MSVC_RUNTIME_LIBRARY = MultiThreadedDLL` | DPC++ 不接受 `/MT` 与 `-fsycl` 同时使用 |
| `NOMINMAX`、`WIN32_LEAN_AND_MEAN`、`_CRT_SECURE_NO_WARNINGS` | `windows.h` 的 min/max 宏会破坏 `std::numeric_limits<>::min()` |
| 前端为 MSVC 时用 `/fp:precise`、`/Qmkl=sequential` | 这是 `-fp-model=precise` 与 `-qmkl=sequential` 在 clang-cl 下的写法 |
| `quant.cmake` 的 `Clang` 判断加入 `IntelLLVM` | AVX-512 目标需要 `/clang:-mavx512vnni`，而 icx 报的是 `IntelLLVM`，不是 `Clang` |
| `s2_expert_grouped.dp.cpp` 加 `-ffp-contract=off` | 乘加分别舍入，与其他后端保持一致 |
| `strata.exe` 链接 `strata-utf8.manifest` | 在非 UTF-8 代码页下仍能输出 UTF-8 控制台文本 |
| `quant/internal.hpp` 用按位构造的 2 的幂替换 `std::ldexp` | icx 2026.1 会把静态初始化器留成运行期的 `ldexpf` 调用，链接报 `LNK2019: __imp_ldexpf` |
| `verify_kernels.dp.cpp` 中 `#undef OUT` | `sal.h` 定义了 `OUT`，与 `template <bool OUT>` 冲突 |
| `generate.cpp` 中 `#undef small` | `rpcndr.h` 定义了 `small`，与局部变量冲突 |
| `generate.cpp` 中补 `memmem` | MSVC CRT 没有该函数 |
| `open`/`pread`/`close` 映射到 `_open`/`_lseeki64`+`_read`/`_close` | `gguf_expert_source.cpp` 原文是 POSIX 写法，MSVC 也没有 `ssize_t` |
| `mkdir` 映射到 `_mkdir` | 同上，位于 `prefill.cpp` |

### 二、两处只在 Windows 出现的挂死

**PCIe 份额的守卫从未生效。** 上游在驱动名为 `xe` 时拒绝把可分页的专家内存交给 GPU，因为 xe 读它会出错。
该判断读的是 `intel_gpu_driver()`，它解析 `sysfs`，在 Windows 上是空值。于是 B580 保留了默认的 0.55 份额，
GPU 读了可分页的区域，第一个 verify 窗口在第 0 层挂住，显卡空转。

修法是问设备而不问驱动：`intel_gpu_pageable_host_faults()` 在没有驱动名时把 Battlemage 视同会出错。
Linux 行为不变。

**等待上限没有考虑 CPU 供专家的情况。** 在无 `sysfs` 的分支里，`spin_bound_for()` 只看 `long_drafts`。
因此带 MTP 层的 `--spec` 运行在 CPU 供专家时仍保持 20000 次读的上限，CPU 池一卡顿就丢弃窗口（报
`the CPU took 30 ms, longer than the GPU's wait`）。现在与 `xe` 分支一致，按
`host_waits || long_drafts` 取值。

### 三、CUDA 构建掩盖的一个缺口

`pinned.dp.cpp` 的 `sliced_pin_limit()` 通过 `cudaGetDeviceProperties()` 和 DXGI 适配器 LUID 查询 GPU 的
共享内存预算，SYCL 两者都没有。现在改用 `RAM / 2 - 8 GiB` 这一退路——CUDA 构建在查询失败时本就用它——
而不是把 CUDA 运行时调用编进 SYCL 二进制。

### 四、Windows 安装流程所需的设备枚举

`strata-device`（`engine/sycl/src/core/device_info_main.cpp`，新增）回答的是 CUDA 和 HIP 构建从未需要回答
的问题：每个 `ONEAPI_DEVICE_SELECTOR` 序号对应哪块卡、显存多大、专家池所需的 USM 能力是否具备——以 JSON
形式给出，且在加载模型之前。上游的 `device_main.cpp` 打印的是内存规划，而规划只有打开模型之后才存在。
Windows 安装流程会拒绝缺少此程序的引擎组件，所以它与 `strata.exe`、`strata-vision.exe` 同目录发布。

### 五、打包

`tools/packaging/binary_deps.py` 的 Windows 系统 DLL 白名单加入 `wintrust.dll` 与 `imagehlp.dll`。两者都是
Windows 10/11 的 System32 库，分别被随包的 `tbb12.dll` 与 `libiomp5md.dll` 导入；不加这两条，依赖检查会把
一个正确的包判为不完整，`--verify` 拒绝通过。

## 构建

所需环境：Visual Studio 2022（含 C++ 桌面开发负载）、Windows SDK、Intel oneAPI 2026.2（DPC++ 与 oneMKL）、
CMake 3.24+、Ninja。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-sycl-windows.ps1
```

脚本自行设置 `INCLUDE`/`LIB`/`PATH`，不调用 `setvars.bat` 或 `vcvars64.bat`。这是有意为之：两者都会通过
`reg.exe` 定位 Visual Studio，而在 `reg.exe` 被策略拦截的机器上，拼出的 `INCLUDE` 不完整，构建会在
`crtdbg.h` 上失败。手工拼路径产出的二进制相同。

常用开关：

```powershell
# 针对特定型号做 AOT，替代 JIT SPIR-V（bmg-g21：B580/B570/Pro B60；bmg-g31：Pro B70）
... -File scripts\build-sycl-windows.ps1 -Aot bmg-g21

# 固定 oneAPI 版本，并让它使用独立的构建目录
... -File scripts\build-sycl-windows.ps1 -OneApiVersion "2026.2" -BuildDir "build-sycl-2026.2"
```

默认值：`STRATA_PORTABLE=ON`、`STRATA_SYCL_PARITY=OFF`、JIT、四路并行。

## 打包

```powershell
# 1. 把 SYCL / MKL 运行时收集到可执行文件旁（app-local 方式）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package-runtime.ps1

# 2. 组装为引擎组件
python tools\packaging\package_engine.py --src build-sycl-windows `
    --backend sycl --version 0.1.68 --platform windows-x86_64 --arch spir64 `
    --out out\engine --include strata-device.exe `
    --search "C:\Program Files (x86)\Intel\oneAPI\2026.2\bin"

# 3. 校验：应输出 "ok (N files, manifest sha256 ...)"
python tools\packaging\package_engine.py --verify out\engine\0.1.68-windows-x86_64-sycl
```

有三个参数不能省：`--arch spir64`（SYCL 包不给 arch 会被拒）、`--include strata-device.exe`（影像程序会
自动带入，设备程序不会）、`--search`（MKL 与 oneAPI 运行时 DLL 不在默认搜索路径上）。

一个引擎组件必须同时具备 `strata.exe`、`strata-device.exe`、`strata-vision.exe`，缺任一个客户端都不收。

### `strata_control` 依赖

`package_engine.py` 与 `feed_tool.py` 都导入 `strata_control`，该包位于上游的 `terminal/`，不在本分支内。
把它加入 `PYTHONPATH`：

```powershell
$env:PYTHONPATH = "C:\path\to\upstream\Strata\terminal"
```

已安装客户端的 Control 目录也带同一个包，但只有该安装的版本。版本偏旧的 Control 缺 `shape_engine`，
`package_engine.py` 会在导入阶段失败；与本分支基线同版本的上游 `terminal/` 才是匹配的。

## 实测配置

只有一台机器，列出配置是为了不让下面的数字被当成普遍结论：

| | |
| --- | --- |
| 显卡 | Intel Arc B580（Xe2 / Battlemage），WDDM |
| 系统 | Windows 11 |
| 工具链 | oneAPI 2026.2、MSVC 14.44、Ninja |
| 模型 | Qwen3.8-Flash-Next 的一个微调版（Swift 1.5），IQ3_S |

- 连续 18 轮多轮对话：峰值 RSS 48.9 GB，各轮极差 47 MB，无丢弃窗口，无 `did not finish within` 超时。
- 解码吞吐 17.5–42.4 tok/s，随草稿接受率（0.232–0.703）变化，不是缺陷。
- 影像：同图 GPU 与 CPU 的 RMS 为 4.8e-4；两张不同图片的 GPU 间 RMS 为 3.4e-2，相差 71 倍。
- 三个可执行程序在 14 个环境变量、三项目录的 `PATH`（`组件目录;System32;Windows`）下可运行，即 oneAPI
  已卸载的状态。

## 跟进上游新版本

本分支从快照起步，不带上游历史，因此 `git subtree pull` 与 `git merge` 都没有共同祖先可用，会把整个引擎
当作新文件重放一遍。更新的方式是重放补丁，这也是每处移植改动都带 `STRATA_WINDOWS_PATCH` 标记的原因：
更新之后，靠这个标记才能把补丁认出来。

```bash
# Windows 上用 Git Bash；同样的命令在 Linux 与 macOS 上可用
git remote add upstream https://github.com/Niko1221/Strata.git
git fetch upstream

# 1. 把移植保存为相对当前基线的补丁（基线即第一个提交的 SHA）
BASELINE=2af30ccaa0729177c4725ee2073f72bf550e2f86
git diff $BASELINE..HEAD -- engine tools/packaging > ../port.patch
test -s ../port.patch || { echo "port.patch is empty, stop"; exit 1; }

# 2. 用新上游的树整棵替换
git worktree add ../upstream upstream/main
rm -rf engine tools/packaging
cp -r ../upstream/engine .
mkdir -p tools && cp -r ../upstream/tools/packaging tools/packaging
cp ../upstream/LICENSE ../upstream/.gitattributes .
git add -A && git commit -m "Re-import engine from upstream <new-sha>"

# 3. 重放移植，在带标记的文件里解决冲突
git apply --3way ../port.patch
git add -A && git commit -m "Replay the Windows SYCL port onto <new-sha>"
```

第 2 步会先删工作树再复制，所以第 1 步要检查补丁非空。`device_info_main.cpp` 是新增文件，会留在
`port.patch` 里，第 3 步随之恢复。

第 3 步之后要核对两处，因为上游最可能在这两处底下做了改动：

- `intel_gpu_pageable_host_faults()` 与 `spin_bound_for()` 上游可能也修了 Windows 的情况。若已修，删掉本地
  版本，不要对同一个问题留两套答案。
- `strata-device` 目标：若上游提供了可用于 Windows 的设备程序，用它替换 `device_info_main.cpp`。

## 已知限制

- **仅 Windows。** 在别处能编译只是巧合；兼容层都在 `_WIN32` 之下，但 Linux 未做任何验证。
- **未做 AOT 对照。** 曾尝试 `-Aot bmg-g21`，编译器卡住；交付配置是 JIT SPIR-V。
- **组件未签名。** 本地构建的引擎组件无法用上游密钥签名，客户端的 `install-file` 会拒绝。改为把目录复制到
  `%LOCALAPPDATA%\Strata\components\engine\`。
- **图片对话未做端到端验证。** 只单独测了影像程序，未通过客户端发起带图对话。
- 「实测配置」中的数字来自一台机器、一个模型，不构成基准测试。

## 许可

MIT，与上游相同。`LICENSE` 是上游文件的原样复制（sha256
`949b9b0aada7476006469e58ee4ffb0e0f68c2d9137e90a356757b61a09d37f0`），不是追加过内容的副本。基线、上游
版权与本分支移植的版权记录在 `NOTICE`，这也是 MIT 对派生作品的要求。「Strata」及上游代码版权归 Niko1221
与 Strata 贡献者所有。
