# DittoCard

DittoCard 是用于读取、预览、更换和恢复 iPhone Wallet 卡面图片的桌面应用。项目包含 macOS 原生 SwiftUI 版，以及 Windows / macOS 跨端版。更换前会保存并校验首次备份；操作中断后可在应用内继续恢复。

## 当前支持范围

| 客户端 | 已验证 | 仍需验证 |
| --- | --- | --- |
| Windows 跨端版 | Windows 11 x64、Microsoft Store 版 iTunes；已在真机完成卡面读取、更换和首次备份恢复 | 其他 iTunes 安装方式、Windows ARM64、更多设备与系统版本 |
| macOS 跨端版 | arm64 应用构建、启动、设备发现和界面操作 | 真机卡面读取、更换、恢复；Intel 构建及其他系统版本 |
| macOS SwiftUI 版 | arm64 应用和 DMG 构建、启动、离线预览与界面操作 | 真机卡面读取、更换、恢复；Intel 构建及其他系统版本 |

卡面操作目前只对 iOS 27.0 的 `24A435`、`24A437`、`24A5390f` 构建开放。设备能连接不代表其他版本已通过验证。各平台的历史实测范围见[验证记录](docs/desktop-validation.md)。

## 使用

1. 连接并解锁 iPhone，在手机上确认信任这台电脑。
2. 在应用中点击“扫描卡片”，然后在手机的 Wallet 中打开目标卡片。
3. 停止扫描，选择识别出的卡片，点击“读取卡面”。
4. 选择图片并调整预览，确认后点击“应用卡面”。选图和预览本身不会写入手机。
5. 如需撤销更换，使用“恢复首次备份”；重新打开 Wallet 检查显示结果。

首次成功读取或首次更换前保存的原始素材会按设备和卡片分别保留。若出现待恢复事务，请连接同一台手机并使用“继续恢复”，完成后再进行新的更换。不要删除应用数据目录中的备份或事务文件。

## 项目目录

| 路径 | 内容 |
| --- | --- |
| `backend/` | 共用 Python 后端、依赖清单、Windows 诊断工具及后端打包配置 |
| `frontend/swift/` | SwiftUI 界面、原生 helper、素材与构建脚本 |
| `frontend/cross-platform/` | React、Tauri 和 Rust 跨端客户端 |
| `tests/` | 后端自动化测试 |
| `docs/` | 构建、验证与设备检测文档 |

`build/`、`.venv/` 和各前端依赖与构建目录是本地生成内容。用户卡片记录、首次备份和未完成事务位于 Windows 的 `%LOCALAPPDATA%/AirCardDesktop` 或 macOS 的 `~/Library/Application Support/AirCardDesktop/`，不在仓库内。

## 构建

完整步骤、依赖版本和产物路径见[双端构建指南](docs/desktop-build.md)。跨端版的使用说明见[客户端 README](frontend/cross-platform/README.md)。

macOS SwiftUI 版可在仓库根目录执行：

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r backend/requirements-desktop.lock
./frontend/swift/build.sh
```

当前架构的产物位于 `build/DittoCard.app` 和 `build/DittoCard.dmg`。构建成功只说明该环境可以生成应用；真机操作请以[验证记录](docs/desktop-validation.md)为准。

## 维护者

- [@mak5er](https://github.com/mak5er)
- [@Lumid-Off](https://github.com/Lumid-Off)
