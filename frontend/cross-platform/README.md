# DittoCard 跨端客户端

本目录包含 React 界面和 Tauri 桌面程序。Windows 与 macOS 使用仓库中的同一套 Python 后端。当前版本为 `0.2.0`。

## 使用流程

1. 连接并解锁 iPhone，确认信任这台电脑。Windows 11 x64 需要已验证的 Microsoft Store 版 iTunes 和 WebView2 Runtime。
2. 点击“扫描卡片”，在手机 Wallet 中打开目标卡片；停止扫描后选择卡片。
3. 使用“读取卡面”保存首次备份。选择新图片后，可调整位置、缩放并生成预览；只有点击“应用卡面”才会开始更换。
4. 使用“恢复首次备份”恢复最初保存的素材，重新打开 Wallet 检查显示。

操作中断时，连接原设备并使用“继续恢复”。应用会保留恢复记录并限制相关卡片的新操作。若某张卡片被标记为未解决，可在应用内重新检查；其他卡片仍可继续扫描。不要手动删除备份或事务目录。

当前卡面操作仅对 iOS 27.0 的 `24A435`、`24A437`、`24A5390f` 构建开放。其他设备或系统版本的连接成功不代表卡面操作已验证。

## 开发与构建

从仓库根目录准备 Python 3.12 环境并安装 `backend/requirements-desktop.lock`，然后进入本目录。macOS 还需先运行 `make -C frontend/swift all`。安装 Node.js 22、pnpm 11.7.0 和 Rust 1.98.1 后执行：

```sh
pnpm install --frozen-lockfile
pnpm test
pnpm package:backend
pnpm bundle
```

macOS 最后一条命令需加 `--config src-tauri/tauri.macos.conf.json`。打包脚本通过 `AIRCARD_PYTHON` 指定 Python 解释器；建议使用仓库 `.venv` 中解释器的绝对路径。完整的 Windows PowerShell、macOS 命令及产物位置见[构建指南](../../docs/desktop-build.md)。

仅开发服务器可使用 `http://localhost:1420/?preview=cards` 查看合成卡片。此预览不执行设备操作，也不包含在生产构建中。

## 数据与验证范围

Windows 数据位于 `%LOCALAPPDATA%/AirCardDesktop`，macOS 数据位于 `~/Library/Application Support/AirCardDesktop/`。`devices/` 存放按设备和卡片区分的记录与首次备份，`transactions/` 存放可继续的操作记录。旧版卡片标识只作为待重新关联的候选，不自动成为可恢复备份。

Windows 真机已完成读取、更换和恢复。macOS arm64 已完成构建、启动与设备发现，真机卡面流程仍待验证。详情见[验证记录](../../docs/desktop-validation.md)。
