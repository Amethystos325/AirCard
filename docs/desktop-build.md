# DittoCard：依赖与双端本地构建

本文适用于 `frontend/cross-platform/` 下的 Tauri 2 + React + TypeScript + Python 桌面客户端。所有测试、打包和安装验收均在本地完成，不使用 GitHub Actions / CI。Windows 已完成本机构建和 Suica 真机验证；macOS 27 arm64 已完成本机构建、启动与设备自动发现，Intel 构建和 iPhone 卡片流程仍待执行，详见[验证记录](desktop-validation.md)。

## 运行安装版需要什么

| 平台 | 系统及运行依赖 | 不需要安装的开发工具 |
| --- | --- | --- |
| Windows | Windows 11 x64、Microsoft Edge WebView2 Runtime；连接手机还需要已验证的 Microsoft Store 版 iTunes 及其 Apple 设备驱动 / 服务 | Python、Node.js、pnpm、Rust、Visual Studio |
| macOS | 目标为 macOS 14+，安装与 CPU 架构匹配的应用；设备通信使用系统 Apple Framework | Python、Node.js、pnpm、Rust、Xcode |

安装包内含 PyInstaller 目录模式打包的 Python 后端。Windows 安装程序配置为检测 WebView2 并按需下载引导安装，缺少运行库时需要联网。离线安装前请预先安装 [WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/)。

### Windows 的 Apple 组件

1. 安装 [Microsoft Store 版 iTunes](https://apps.microsoft.com/detail/9pb2mz1zmb1s)，并打开一次。
2. 用 USB 连接 iPhone，保持解锁，在手机上确认“信任此电脑”。先确认 iTunes 能打开手机的设备页面，再启动 DittoCard。
3. 若安装驱动后仍不能连接，重新插拔 USB；安装程序要求重启时，先重启 Windows。

本项目验证的是 Store iTunes 的组件布局。仅安装“Apple 设备”（Apple Devices）、传统桌面 iTunes、Windows ARM64 的配置均未验收，不能据此保证可用。DittoCard 从用户安装的 iTunes 发现 Apple DLL 和 CoreFP 依赖，复制到 `%LOCALAPPDATA%/AirCardDesktop/runtime/` 供隔离 worker 使用；安装包不分发 Apple DLL，也不要求手工复制 DLL、修改注册表或使用仓库 `.tmp` 目录。

排查 Apple Mobile Device Service 状态可在 PowerShell 中执行：

```powershell
Get-Service -DisplayName 'Apple Mobile Device Service' -ErrorAction SilentlyContinue
```

无结果表示未找到该服务；请检查 iTunes 安装及其设备组件。配对超时、未信任或锁定时，先检查手机解锁状态、信任提示和 iTunes 设备页。若 DittoCard 已显示待恢复任务，重连后先继续恢复。

USB 连接成功不代表允许写入。当前桌面客户端沿用 iOS 27.0、build `24A435` / `24A437` / `24A5390f` 的兼容门槛。

## 源码构建工具

| 工具 | 本项目版本 / 要求 | 用途 |
| --- | --- | --- |
| Git | 能正常克隆仓库 | 获取源码 |
| Node.js | 22，本机验证版本为 22.22 | 前端构建及打包脚本 |
| pnpm | 11.7.0，与 `frontend/cross-platform/package.json` 一致 | 安装前端依赖、执行构建 |
| Rust / Cargo | 1.98.1，通过 rustup 安装 | Tauri 桌面程序 |
| Python | 3.12，Windows 使用 x64；Mac 使用与目标架构一致的解释器 | 后端、测试、PyInstaller |
| Windows 编译工具 | VS 2022 Build Tools，勾选“使用 C++ 的桌面开发”、MSVC v143 x64/x86 工具及 Windows SDK | Rust 的 MSVC 链接工具 |
| macOS 编译工具 | Xcode Command Line Tools，包含 `xcrun`、`clang`、`make` 和 `codesign` | 原生 helper 和 Tauri |

Windows 开发也需要 WebView2。平台工具的官方安装说明见 [Tauri 前置依赖](https://v2.tauri.app/start/prerequisites/)；Rust 使用 [rustup](https://www.rust-lang.org/tools/install)，Node.js 使用 [官方安装包](https://nodejs.org/en/download)。首次安装和构建需要联网下载依赖及打包工具。

Python 依赖由 `backend/requirements-desktop.lock` 锁定，包含 Pillow、ReportLab、pypdfium2、pymobiledevice3、pefile、PyInstaller 等；不需要逐个手工安装。前端使用 `pnpm-lock.yaml`，Rust 使用 `Cargo.lock`；`pnpm bundle` 会向 Cargo 传入 `--locked`。修改源码后的日常构建不要主动升级这些依赖。

## Windows 11 x64 构建（PowerShell 7）

安装上述工具后重新打开 PowerShell。以下命令从准备存放项目的目录开始；已有仓库则直接进入仓库根目录。每条命令成功后再执行下一条。

```powershell
git clone https://github.com/Amethystos325/AirCard.git
Set-Location AirCard

# 安装项目约定的工具版本；Rust 必须使用 MSVC target
npm install -g pnpm@11.7.0
rustup toolchain install 1.98.1-x86_64-pc-windows-msvc
rustup override set 1.98.1-x86_64-pc-windows-msvc

node --version
pnpm --version
rustc -vV
py -3.12 -c "import platform, struct; print(platform.python_version(), struct.calcsize('P') * 8)"

# 根目录：创建 Python 3.12 x64 环境并安装锁定依赖
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r backend/requirements-desktop.lock
$env:AIRCARD_PYTHON = (Resolve-Path .venv/Scripts/python.exe).Path

# 根目录：运行后端测试
& $env:AIRCARD_PYTHON -m unittest discover -s tests -q

# desktop 目录：前端测试、后端打包、安装包构建
Set-Location frontend/cross-platform
pnpm install --frozen-lockfile
pnpm test
pnpm package:backend
Remove-Item Env:VITE_E2E -ErrorAction SilentlyContinue
Remove-Item Env:AIRCARD_DATA_DIR -ErrorAction SilentlyContinue
pnpm bundle
```

Python 版本检查应显示 `3.12.x 64`，Rust host 应为 `x86_64-pc-windows-msvc`。若没有 `py` 启动器，用已安装的 Python 3.12 x64 的完整路径替代 `py -3.12`。虚拟环境不必激活，因此无需修改 PowerShell 执行策略。

产物（相对于仓库根目录）：

- 安装包：`frontend/cross-platform/src-tauri/target/release/bundle/nsis/DittoCard_0.2.0_x64-setup.exe`，版本号会随项目版本变化。
- 桌面程序：`frontend/cross-platform/src-tauri/target/release/DittoCard.exe`。
- 冻结后端：`build/desktop-backend/aircard-backend/`；打包脚本将其复制到 `frontend/cross-platform/src-tauri/binaries/backend/` 作为应用资源。

交付 NSIS 安装包。单独复制桌面 exe 或后端 exe 会遗漏资源；后端必须保留完整目录结构。

开发调试：完成上面依赖安装与 `pnpm package:backend` 后，在 `frontend/cross-platform/` 执行 `pnpm dev`。新开终端时，先从根目录重新设置 `AIRCARD_PYTHON`，再进入 `frontend/cross-platform/`。仅预览网页使用 `pnpm web`，不连接真实后端。

## macOS 14+ 构建（zsh / bash）

以下命令只在 Mac 终端执行，不在 Windows PowerShell 中执行。Apple Silicon 和 Intel 分别在本机原生架构环境构建，不要求合并成 Universal 安装包。

| 构建机器 | `uname -m` / Python 架构 | Rust host | 生成的桌面包 |
| --- | --- | --- | --- |
| Apple Silicon Mac | `arm64` | `aarch64-apple-darwin` | arm64 app / DMG |
| Intel Mac | `x86_64` | `x86_64-apple-darwin` | x64 app / DMG |

Apple Silicon 上不要使用 Rosetta 终端混合原生 arm64 Python 与 x64 Rust。PyInstaller 会打包当前解释器的架构，仅更改 Rust `--target` 不能完成整个应用的跨架构打包。

安装 Node.js 22、Python 3.12 和 rustup；如果没有 Xcode Command Line Tools，先执行 `xcode-select --install` 并完成安装。随后：

```sh
git clone https://github.com/Amethystos325/AirCard.git
cd AirCard
npm install -g pnpm@11.7.0
rustup toolchain install 1.98.1
rustup override set 1.98.1

uname -m
node --version
pnpm --version
rustc -vV
python3.12 -c 'import platform; print(platform.python_version(), platform.machine())'
xcode-select -p

# 根目录：原生 helper 和 Python 环境
make -C frontend/swift all
python3.12 -m venv .venv
.venv/bin/python -m pip install -r backend/requirements-desktop.lock
export AIRCARD_PYTHON="$PWD/.venv/bin/python"
"$AIRCARD_PYTHON" -m unittest discover -s tests -q

# desktop 目录：测试、打包后端和 app / DMG
cd frontend/cross-platform
pnpm install --frozen-lockfile
pnpm test
pnpm package:backend
unset VITE_E2E AIRCARD_DATA_DIR
pnpm bundle --config src-tauri/tauri.macos.conf.json
```

`make -C frontend/swift all` 当前生成最低系统版本 14.0 的 Universal `build/device_helper`、`build/airtraffic_host`，并进行本地 ad-hoc 签名。Tauri 后端打包脚本会在 PyInstaller 完成后原样复制 `airtraffic_host`，保留其系统 Framework 链接；桌面 app 和 Python 后端仍按本机架构生成。这里不包含公开发行签名或公证。

产物：`frontend/cross-platform/src-tauri/target/release/bundle/macos/` 下的 `.app`，以及 `frontend/cross-platform/src-tauri/target/release/bundle/dmg/` 下的 `.dmg`。从 DMG 安装 app 后再验收。开发调试同样在设置 `AIRCARD_PYTHON`、构建 helper 和打包后端之后，于 `frontend/cross-platform/` 执行 `pnpm dev`。

两个架构使用各自独立的 checkout / 构建目录，不复用另一种架构的 `.venv`、`node_modules`、`target` 或冻结后端。当前 Windows 机器不能完成 Mac 本地构建验收。

## 桌面冒烟与安装验收

以下可选自动化冒烟命令均从 `frontend/cross-platform/` 执行，先完成 `pnpm package:backend`。它们使用独立测试数据目录、测试应用标识和测试驱动；不替代真机验收。

Windows PowerShell：

```powershell
$env:VITE_E2E = '1'
$env:AIRCARD_DATA_DIR = Join-Path $env:TEMP 'AirCard desktop smoke'
pnpm bundle --no-bundle --features e2e --config src-tauri/tauri.e2e.conf.json
pnpm test:e2e
Remove-Item Env:VITE_E2E -ErrorAction SilentlyContinue
Remove-Item Env:AIRCARD_DATA_DIR -ErrorAction SilentlyContinue
pnpm bundle
```

macOS zsh / bash（待本地执行验证）：

```sh
export VITE_E2E=1
export AIRCARD_DATA_DIR="$(mktemp -d -t aircard-smoke)"
pnpm bundle --no-bundle --features e2e --config src-tauri/tauri.e2e.conf.json
pnpm test:e2e
unset VITE_E2E AIRCARD_DATA_DIR
pnpm bundle --config src-tauri/tauri.macos.conf.json
```

无论测试是否通过，交付打包和真机操作前都要清除这两个测试环境变量，并使用最后一条不带 `--features e2e` 的构建命令。若设置过 `AIRCARD_E2E_BINARY`，检查它是否仍指向当前测试程序。正常关闭测试窗口并等待后端退出后，再覆盖构建资源。

从安装目录启动应用，检查中文 / 英文、明暗主题、中文及含空格路径、高 DPI，以及 USB 发现、扫描分类、读取、备份导出。对明确选定的测试卡片完成更换与恢复，核对 Wallet 显示、Books 与暂存清理、待恢复记录。另用没有 Python / Node / Rust 的 Windows 机器验证运行依赖是否完整。

记录提交号、平台 / 架构、测试结果和产物校验值，更新[验证记录](desktop-validation.md)。Windows 用 `Get-FileHash -Algorithm SHA256 -LiteralPath '安装包完整路径'`；macOS 用 `shasum -a 256 'DMG完整路径'`。

## 常见构建问题

| 现象 | 检查项 |
| --- | --- |
| 找不到 `cargo` / `rustc` | 重开终端；检查 Windows `%USERPROFILE%/.cargo/bin` 或 Mac `~/.cargo/bin` 是否在 PATH |
| Windows 找不到 `link.exe` 或 MSVC 链接失败 | 检查 VS Build Tools 的 C++ 工作负载、MSVC 和 Windows SDK；使用 MSVC Rust toolchain |
| `pnpm` 找不到或版本不符 | 使用 `npm install -g pnpm@11.7.0`，重开终端并检查版本 |
| 找不到 Python、PyInstaller 或脚本访问 `.tmp/windows-prototype-py312` | 显式设置 `AIRCARD_PYTHON` 为当前 `.venv` 解释器的绝对路径；从仓库根目录安装锁定 Python 依赖 |
| 缺少 `binaries/backend` 或冻结资源 | 在 `frontend/cross-platform/` 先运行 `pnpm package:backend`，再运行 `pnpm dev` / `pnpm bundle` |
| Mac 缺少 `airtraffic_host` 或原生 framework 链接失败 | 检查 Command Line Tools 和所选 SDK，先在根目录运行 `make -C frontend/swift all`；保留实际错误用于 Mac 验收 |
| 构建成功但无法发现 iPhone | 构建不要求手机在线；真机通信另需 Apple 组件、解锁和信任，按本文运行依赖排查 |
| `1420` 端口被占用 | 检查是否已有本项目 Vite 服务，复用或正常停止旧开发会话 |
| 后端 DLL / exe 文件被占用 | 正常关闭使用该构建目录的应用及测试窗口，等后端安全退出后重试 |

## SwiftUI 构建入口

SwiftUI 版只在 Mac 构建，从仓库根目录运行 `frontend/swift/build.sh`。先准备 Python 3.12 环境和锁定依赖：

```sh
# macOS，仓库根目录
python3.12 -m venv .venv
.venv/bin/python -m pip install -r backend/requirements-desktop.lock
./frontend/swift/build.sh
```

生成当前架构的 `build/DittoCard.app` 和 `build/DittoCard.dmg`。脚本保留其他 `build/` 产物，并为 SwiftUI 应用冻结与本机架构匹配的事务后端。若要 Universal 应用，分别准备 arm64 与 x86_64 的 Python 环境，设置 `AIRCARD_PYTHON_ARM64`、`AIRCARD_PYTHON_X86_64` 及 `AIRCARD_SWIFT_ARCHES="arm64 x86_64"`。不要在 Windows 上用该脚本构建桌面客户端。
