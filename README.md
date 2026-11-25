# strata-sycl-windows

**English** | [简体中文](README.zh-CN.md)

Strata's inference engine for Intel GPUs on Windows: the SYCL backend built with the MSVC / clang-cl
toolchain, packaged as an engine component the desktop client can load.

> **This is a derived branch, not an official release.**
> It carries only the engine subtree of [Niko1221/Strata](https://github.com/Niko1221/Strata) at commit
> `2af30ccaa0729177c4725ee2073f72bf550e2f86`, plus the Windows port on top. It is not affiliated with,
> endorsed by, or supported by the upstream project. Bug reports about the port belong here; bugs in the
> engine itself belong upstream.

## Why this exists

The upstream SYCL backend is developed and tested on Linux. On Windows the same source needs a different
toolchain (clang-cl in MSVC compatibility mode, a dynamic CRT, no `sysfs`), and two upstream assumptions
about the driver silently break. The result of those breaks was not a build error but a hung card, so
they are worth stating plainly:

- A B580 accepted `--pcie-frac 0.55`, the GPU read pageable host memory, and the first verify window
  hung at layer 0 with the card idle.
- With `--spec` and the MTP layer present, the decode window kept a 20,000-read host bound while the CPU
  served experts, and windows were discarded whenever the CPU pool stalled.

Both are fixed here. The rest is mechanical: POSIX file calls, `sal.h` and `rpcndr.h` macros, the
`/MT` versus `-fsycl` conflict, and the clang-cl spellings of three Intel compiler flags.

## Baseline

| | |
| --- | --- |
| Upstream | `https://github.com/Niko1221/Strata` |
| Commit | `2af30ccaa0729177c4725ee2073f72bf550e2f86` |
| Upstream date | 2026-11-24 |
| Upstream version | Control 0.1.68 / Terminal 0.2.21.1 |
| License | MIT (see `LICENSE`) |

The commit that imports the engine is upstream's tree unmodified, and the one after it is the port, so
`git diff 2af30ccaa..HEAD` reads as the port and nothing else. The repository's first commit is the one
GitHub writes when a repository is created; the import replaces the LICENSE template it leaves behind.

## What is here

| Path | |
| --- | --- |
| `engine/` | the engine: all backends, the SYCL kernels, the host runtime, the tests |
| `tools/packaging/` | the packaging tools that build an engine component from the binaries |
| `scripts/` | Windows helper scripts: build, runtime DLL collection, oneAPI install |
| `patches/terminal-vision-crt-sse41.patch` | the two `CMakeLists.txt` edits the vision tool needs; that tool lives in `terminal/`, which this branch does not carry |

### What is deliberately not here

The desktop client (`app/`), the terminal (`terminal/`), and the documentation set (`docs/`) are not
part of this branch. Two consequences worth knowing before you build:

- `tools/packaging/` imports `strata_control` from upstream's `terminal/`, which this branch does not
  carry. See [The `strata_control` dependency](#the-strata_control-dependency) below for what that
  means in practice.
- A few test targets in `engine/cmake/strata_gpu_engine.cmake` reference `terminal/tools/*` (the IQ
  fixture generator, the HIP tuning tools). Those targets only register when the matching backend and
  tests are enabled; the SYCL build does not need them.

## The port, in five groups

Every change below is marked `STRATA_WINDOWS_PATCH` in the source, so `git grep STRATA_WINDOWS_PATCH`
lists the whole port with its reasoning inline.

### 1. Toolchain: MSVC, clang-cl, icx

| Change | Why |
| --- | --- |
| `CMAKE_MSVC_RUNTIME_LIBRARY = MultiThreadedDLL` | DPC++ rejects `/MT` together with `-fsycl` |
| `NOMINMAX`, `WIN32_LEAN_AND_MEAN`, `_CRT_SECURE_NO_WARNINGS` | `windows.h` min/max macros break `std::numeric_limits<>::min()` |
| `/fp:precise`, `/Qmkl=sequential` when the frontend is MSVC | clang-cl spellings of `-fp-model=precise` and `-qmkl=sequential` |
| `IntelLLVM` added to the `Clang` checks in `quant.cmake` | the AVX-512 objects need `/clang:-mavx512vnni`; icx reports as `IntelLLVM`, not `Clang` |
| `-ffp-contract=off` on `s2_expert_grouped.dp.cpp` | keep multiply and add rounding separate, as the other backends do |
| `strata-utf8.manifest` linked into `strata.exe` | UTF-8 console output on a non-UTF-8 code page |
| `std::ldexp` replaced by bit-built powers of two in `quant/internal.hpp` | icx 2026.1 leaves the static initializer as a runtime `ldexpf` call and the link fails with `LNK2019: __imp_ldexpf` |
| `#undef OUT` in `verify_kernels.dp.cpp` | `sal.h` defines `OUT`, which collides with `template <bool OUT>` |
| `#undef small` in `generate.cpp` | `rpcndr.h` defines `small`, which collides with a local variable |
| `memmem` shim in `generate.cpp` | not in the MSVC CRT |
| `open`/`pread`/`close` mapped to `_open`/`_lseeki64`+`_read`/`_close` | `gguf_expert_source.cpp` is POSIX-only as written; MSVC has no `ssize_t` |
| `mkdir` mapped to `_mkdir` | same reason, in `prefill.cpp` |

### 2. Two hangs that only appear on Windows

**The PCIe share guard never fired.** Upstream refuses to hand the GPU pageable expert memory when the
kernel driver is `xe`, because xe faults on it. The check reads `intel_gpu_driver()`, which parses
`sysfs` — empty on Windows. A B580 therefore kept the default 0.55 share, the GPU read the pageable
arena, and the first verify window hung at layer 0 with the card idle.

Fixed by asking the device instead of the driver: `intel_gpu_pageable_host_faults()` treats Battlemage
as faulting when no driver name is available. Linux behaviour is unchanged.

**The host wait bound ignored CPU-served experts.** In the no-`sysfs` branch, `spin_bound_for()` looked
only at `long_drafts`. A `--spec` run with the MTP layer present therefore held a 20,000-read bound while
the CPU was serving experts, and discarded the window (`the CPU took 30 ms, longer than the GPU's wait`)
whenever the CPU pool stalled. The bound now keys on `host_waits || long_drafts`, as the `xe` branch
already did.

### 3. A gap the CUDA build hid

`sliced_pin_limit()` in `pinned.dp.cpp` queried the GPU's shared-memory budget through
`cudaGetDeviceProperties()` and a DXGI adapter LUID. SYCL has neither. It now takes the `RAM / 2 - 8 GiB`
fallback that the CUDA build already uses when the budget query fails, rather than compiling a CUDA
runtime call into a SYCL binary.

### 4. Device enumeration for the Windows setup

`strata-device` (`engine/sycl/src/core/device_info_main.cpp`, new) answers a question the CUDA and HIP
builds never had to: which adapter each `ONEAPI_DEVICE_SELECTOR` ordinal names, its VRAM, and the USM
capabilities the expert pools require — as JSON, before a model is loaded. Upstream's `device_main.cpp`
prints the memory plan, which only exists after a model is open. The Windows setup refuses an engine
component without this program, so it ships beside `strata.exe` and `strata-vision.exe`.

### 5. Packaging

`wintrust.dll` and `imagehlp.dll` are added to the Windows system-DLL allowlist in
`tools/packaging/binary_deps.py`. Both are System32 libraries on Windows 10/11, imported by the bundled
`tbb12.dll` and `libiomp5md.dll`; without the entries the dependency check called a correct package
incomplete and `--verify` refused it.

## Build

Requirements: Visual Studio 2022 with the C++ desktop workload, Windows SDK, Intel oneAPI 2026.2 (DPC++
and oneMKL), CMake 3.24+, Ninja.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-sycl-windows.ps1
```

The script sets `INCLUDE`/`LIB`/`PATH` itself instead of calling `setvars.bat` or `vcvars64.bat`. That is
deliberate: both shell out to `reg.exe` to locate Visual Studio, and on a machine where `reg.exe` is
blocked by policy the resulting `INCLUDE` is incomplete and the build fails on `crtdbg.h`. Manual paths
produce the same binaries.

Useful switches:

```powershell
# AOT for a specific part instead of JIT SPIR-V (bmg-g21: B580/B570/Pro B60, bmg-g31: Pro B70)
... -File scripts\build-sycl-windows.ps1 -Aot bmg-g21

# pin a oneAPI version and keep its build tree separate
... -File scripts\build-sycl-windows.ps1 -OneApiVersion "2026.2" -BuildDir "build-sycl-2026.2"
```

The defaults are `STRATA_PORTABLE=ON`, `STRATA_SYCL_PARITY=OFF`, JIT, four jobs.

## Package

```powershell
# 1. collect the SYCL / MKL runtime beside the executables (app-local deployment)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package-runtime.ps1

# 2. package as an engine component
python tools\packaging\package_engine.py --src build-sycl-windows `
    --backend sycl --version 0.1.68 --platform windows-x86_64 --arch spir64 `
    --out out\engine --include strata-device.exe `
    --search "C:\Program Files (x86)\Intel\oneAPI\2026.2\bin"

# 3. verify: expected "ok (N files, manifest sha256 ...)"
python tools\packaging\package_engine.py --verify out\engine\0.1.68-windows-x86_64-sycl
```

Three arguments are not optional: `--arch spir64` (a SYCL package without an arch is refused),
`--include strata-device.exe` (the vision reader is picked up automatically, the device program is
not), and `--search` (the MKL and oneAPI runtime DLLs are not on the default search path).

An engine component needs `strata.exe`, `strata-device.exe` and `strata-vision.exe` together; the
client refuses a package missing any of the three.

A built 0.1.68 package is attached to the
[releases page](https://github.com/vigaice/strata-sycl-windows/releases), so building is only needed to
change something. It is signed with a local key; see *Known limits*.

### The `strata_control` dependency

`package_engine.py` and `feed_tool.py` import `strata_control`, which lives in upstream's `terminal/`
and is not part of this branch. Put it on `PYTHONPATH`:

```powershell
$env:PYTHONPATH = "C:\path\to\upstream\Strata\terminal"
```

An installed Strata's Control directory carries the same package, but only at that install's version.
An older Control lacks `shape_engine` and `package_engine.py` fails on import; the `terminal/` of the
upstream commit this branch is based on is the version that matches.

## Tested configuration

One machine, stated so the numbers are not read as a general claim:

| | |
| --- | --- |
| GPU | Intel Arc B580 (Xe2 / Battlemage), WDDM |
| OS | Windows 11 |
| Toolchain | oneAPI 2026.2, MSVC 14.44, Ninja |
| Model | a Qwen3.8-Flash-Next fine-tune (Swift 1.5), IQ3_S |

- 18 consecutive multi-turn runs: peak RSS 48.9 GB, spread across runs 47 MB, no discarded windows and
  no `did not finish within` timeouts.
- Decode throughput 17.5–42.4 tok/s, tracking draft acceptance (0.232–0.703) rather than any defect.
- Vision: GPU vs CPU RMS 4.8e-4 on the same image; 3.4e-2 across two different images, a 71× separation.
- The three executables run with 14 environment variables and a three-entry `PATH`
  (`component dir;System32;Windows`), i.e. with oneAPI uninstalled.

## Moving to a newer upstream

This branch starts from a snapshot, not from upstream's history, so `git subtree pull` and
`git merge` have no common ancestor to work from — they would replay the whole engine as new files.
The update is therefore a patch replay, which is why every port change carries the
`STRATA_WINDOWS_PATCH` marker: that marker is what makes the patch identifiable after an update.

```bash
# Git Bash on Windows; the same commands work on Linux and macOS
git remote add upstream https://github.com/Niko1221/Strata.git
git fetch upstream

# 1. keep the port as a patch against the current baseline (the import commit's SHA)
BASELINE=2af30ccaa0729177c4725ee2073f72bf550e2f86
git diff $BASELINE..HEAD -- engine tools/packaging > ../port.patch
test -s ../port.patch || { echo "port.patch is empty, stop"; exit 1; }

# 2. replace the tree with the new upstream's, wholesale
git worktree add ../upstream upstream/main
rm -rf engine tools/packaging
cp -r ../upstream/engine .
mkdir -p tools && cp -r ../upstream/tools/packaging tools/packaging
cp ../upstream/LICENSE ../upstream/.gitattributes .
git add -A && git commit -m "Re-import engine from upstream <new-sha>"

# 3. replay the port, resolving conflicts in the marked files
git apply --3way ../port.patch
git add -A && git commit -m "Replay the Windows SYCL port onto <new-sha>"
```

Step 2 deletes the working tree before copying, which is why step 1 checks that the patch is not
empty. `device_info_main.cpp` is an added file, so it survives in `port.patch` and comes back in
step 3.

Two things to check after step 3, because they are the ones upstream is most likely to have changed
underneath:

- `intel_gpu_pageable_host_faults()` and `spin_bound_for()` may have been fixed upstream for Windows
  too. If so, drop the local version rather than keeping two answers to one question.
- The `strata-device` target: if upstream grows a Windows-capable device program, use it instead of
  `device_info_main.cpp`.

## Known limits

- **Windows only.** The port compiles elsewhere only by accident; the shims are all under `_WIN32`, but
  nothing here was tested on Linux.
- **No AOT comparison.** An AOT build (`-Aot bmg-g21`) was attempted and the compiler stalled; the
  shipped configuration is JIT SPIR-V.
- **The signature is local, not upstream's.** A locally built component cannot carry the upstream
  signing key, so it is signed with a key generated on this machine and the public half is added to the
  client's trust list (`control\strata_control\update_keys.json`). The client then treats it as signed:
  `strata components engines` reports `signed`, `components use` switches to it, and
  `components install-file` accepts the zip. Two consequences: a Control component update replaces
  `update_keys.json` and the trust has to be added again, and another machine rejects the package
  unless it trusts the same key.
- **Image conversations were not exercised end to end** through the client; the vision program was
  tested on its own.
- The numbers in *Tested configuration* come from one machine and one model. They are not a benchmark.

## License

MIT. `LICENSE` keeps upstream's copyright notice unchanged and adds one line for this branch's port,
which is what MIT asks of a derived work; `NOTICE` records the baseline commit. "Strata" and the
upstream code are copyright Niko1221 and the Strata contributors.
