# AirCard Desktop — 测试版

Tauri 2、React、TypeScript 和独立 Python 3.12 后端。原有 SwiftUI 应用及根目录 `build.sh` 继续保留。

## 使用

1. Windows 11 x64 安装 Microsoft Store 版 iTunes，打开软件确认电脑已信任 iPhone。当前 Windows 运行库适配验证的是 Store iTunes；仅安装“Apple 设备”的配置尚未验收。AirCard 不分发 Apple DLL。
2. 安装生成的 NSIS 包，连接并解锁手机，点击“查找卡片”，在 Wallet 中切换目标卡片。
3. 停止扫描，选择已分类卡片，读取卡面。首次备份按设备和卡片隔离，包含原有缺失文件状态。
4. 选图、调整位置和缩放、生成预览，最后点击“应用卡面”。选图不会修改手机。
5. “恢复首次备份”恢复本应用第一次备份的卡面。请重新打开 Wallet 检查显示效果。

检测到未完成事务时，连接原设备并点击“继续恢复”。恢复操作前快照成功后，才能发起新的修改。不要删除事务文件。关闭窗口会等待当前操作到达安全节点；强制结束或断线后重启可继续恢复。

当前兼容门槛沿用已有原生应用：iOS 27.0，build `24A435`、`24A437`、`24A5390f`。USB 能连接不表示其他版本可以写入。

## 开发与构建

依赖：Node.js 22、pnpm 11.7.0、Rust 1.98.1、Python 3.12。Windows 需要 VS 2022 Build Tools 的 C++ 工具链；macOS 需要 Xcode Command Line Tools。

在仓库根目录安装锁定的 Python 依赖：

```powershell
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements-desktop.lock
$env:AIRCARD_PYTHON = (Resolve-Path .venv/Scripts/python.exe).Path
cd desktop
pnpm install --frozen-lockfile
pnpm dev
```

macOS 使用 `.venv/bin/python` 设置 `AIRCARD_PYTHON`，先在仓库根目录运行 `make all` 构建现有 AirTraffic helper。Mac 环境变量使用本机 shell 语法。

打包：

```powershell
pnpm package:backend
pnpm bundle
```

Windows 产物：`src-tauri/target/release/bundle/nsis/`。macOS 使用 `pnpm bundle --config src-tauri/tauri.macos.conf.json` 生成 app / DMG。分别在 arm64 和 x64 的 macOS 构建，最低系统版本 14.0。默认发布构建不含测试驱动插件。

后端按 PyInstaller onedir 放入应用资源 `backend/`，Rust 直接启动固定可执行程序。冻结后的原生 worker 使用同一程序的 `--native-worker` 模式。安装后无需 Python，不读取仓库 `.tmp`；运行库从用户安装的 Apple 组件复制至应用数据缓存。

## 测试

根目录执行 `python -m unittest discover -s tests -q`；desktop 目录执行 `pnpm test`。

桌面 WebdriverIO 测试：设置 `VITE_E2E=1`，运行 `pnpm tauri build --no-bundle --features e2e --config src-tauri/tauri.e2e.conf.json`，随后运行 `pnpm test:e2e`。指定独立的 `AIRCARD_DATA_DIR`，避免混用真实备份；可用 `AIRCARD_E2E_BINARY` 指向测试副本。嵌入驱动的 select 操作不发送 DOM change，冒烟测试显式派发该事件；React 交互测试另覆盖选择图片后必须点击应用才写入。

`.github/workflows/desktop.yml` 在 Windows、macOS arm64、macOS x64 上测试和生成构建产物，不自动发布。Mac 构建和真机验收在实际执行通过前均标记为待验收。

## 数据与协议

- Windows：`%LOCALAPPDATA%/AirCardDesktop`；macOS：`~/Library/Application Support/AirCardDesktop`。
- `devices/`：设备和卡片各自的哈希目录、首次备份、预览；`transactions/`：操作前快照、Books 快照、可续接日志；`prepared/`：最终裁剪图片；`runtime/`：本机 Apple 运行库。
- 旧 `~/.aircard_cards.json` / `~/.lumicards_cards.json` 和已校验缓存复制到 `legacy/`，原文件保留。旧记录缺少设备归属，只作候选，不成为可恢复备份。
- 后端 stderr 诊断写入 Tauri 应用数据目录 `com.aircard.desktop/logs/backend.log`；原生失败诊断保留在对应事务目录，不进入 stdout 协议。

每行一个 UTF-8 JSON 请求：`{"v":1,"id":"unique-id","method":"overview","params":{}}`。返回同一个 id 的 `ok/result` 或 `ok/error.code`。进度消息携带 `event: progress`、`operationId` 和实际 `stage`。重复 id 返回之前的结果；同进程同一时刻只有一个设备事务。

允许的操作：`hello`、`overview`、`device`、`scan.start/stop`、`image.inspect/prepare`、`card.classify/read/apply/restore/export`、`recovery.resume`、`cancel`。`shutdown` 仅由 Rust 关闭窗口使用。界面不提供 shell 或任意设备路径接口。

## 验收边界

自动化测试覆盖隔离、原有缺失文件、备份损坏、部分写入回滚、恢复续接、worker 超时/崩溃、分片和非法消息、重复请求、图片和界面交互。模拟器故障测试不通过中断真实卡片写入制造故障。

Windows 真机记录见 `../docs/desktop-validation.md`。测试版未签名，不含自动更新。Mac 实机、无开发环境的独立 Windows 机器，以及各档高 DPI 的人工验收仍需对应环境，不能用构建成功替代。
