# DittoCard — 双端测试版

Tauri 2、React、TypeScript 和独立 Python 3.12 后端。原有 SwiftUI 应用及根目录 `build.sh` 继续保留。

## 使用

1. Windows 11 x64 安装 Microsoft Store 版 iTunes，打开软件确认电脑已信任 iPhone。当前 Windows 运行库适配验证的是 Store iTunes；仅安装“Apple 设备”的配置尚未验收。DittoCard 不分发 Apple DLL。
2. 安装生成的 NSIS 包，连接并解锁手机，点击“扫描卡片”，在 Wallet 中切换目标卡片。
3. 停止扫描，选择已分类卡片，读取卡面。首次备份按设备和卡片隔离，包含原有缺失文件状态。
4. 选图、调整位置和缩放、生成预览，最后点击“应用卡面”。选图不会修改手机。
5. “恢复首次备份”恢复本应用第一次备份的卡面。请重新打开 Wallet 检查显示效果。

检测到未完成事务时，连接原设备并点击“继续恢复”。恢复操作前快照成功后，才能发起新的修改。不要删除事务文件。关闭窗口会等待当前操作到达安全节点；强制结束或断线后重启可继续恢复。

当前兼容门槛沿用已有原生应用：iOS 27.0，build `24A435`、`24A437`、`24A5390f`。USB 能连接不表示其他版本可以写入。

## 原版界面风格

桌面界面参照 `AirCardApp.swift`：62px 紧凑工具栏、设备状态胶囊、扫描提示条、290 × 182 卡面、自适应网格、卡片内读取 / 更换 / 导出按钮，以及底部状态和折叠日志。CSS 复现半透明材质、卡面光泽、悬停倾斜和读取扫光；减少动态效果的系统设置会关闭动画。系统原生毛玻璃和字体渲染在不同平台仍有差异。

点击已读取的卡面可缩放查看；标识可复制；列表隐藏仅作用于当前会话，可通过“显示已隐藏卡片”恢复，不删除备份。语言和明暗主题位于右上角设置菜单。更换卡面或拖入图片进入预览，生成裁剪预览后仍需点击“应用卡面”。底部按真实阶段显示不定进度，不显示估算百分比。

仅开发服务器支持 `http://localhost:1420/?preview=cards`，使用合成卡片检查外观，不执行设备操作；生产构建不包含此预览数据。

## 依赖、开发与构建

完整步骤见 [Windows 依赖与双端本地构建指南](../docs/desktop-build.md)，包含：

- Windows 安装版所需的 WebView2、Store iTunes、Apple 设备驱动与服务，以及连接排查。
- Windows PowerShell 的工具链安装、Python 虚拟环境、测试和 NSIS 打包命令。
- macOS arm64 / Intel 的工具链、原生 helper、Python 后端和 app / DMG 构建命令。
- 两端开发调试、桌面冒烟、安装验收和常见构建问题。

项目只在本地构建验证，不使用 GitHub Actions / CI。Windows 产物在 Windows 构建；Mac 产物在对应架构的 Mac 上构建。安装版包含 Python 后端，使用者无需安装开发工具。macOS 27 arm64 已完成本机构建、启动与设备自动发现；Intel 构建和 iPhone 卡片流程仍待验收。

构建顺序为：安装锁定依赖 → macOS 构建 helper → 测试 → `pnpm package:backend` → `pnpm bundle`。macOS 最后一步需要添加 `--config src-tauri/tauri.macos.conf.json`。首次开发启动也先准备后端资源，并显式设置 `AIRCARD_PYTHON`，避免依赖原型的本机路径。

## 数据与协议

- Windows：`%LOCALAPPDATA%/AirCardDesktop`；macOS：`~/Library/Application Support/AirCardDesktop`。
- `devices/`：设备和卡片各自的哈希目录、首次备份、预览；`transactions/`：操作前快照、Books 快照、可续接日志；`prepared/`：最终裁剪图片；`runtime/`：本机 Apple 运行库。
- 旧 `~/.aircard_cards.json` / `~/.lumicards_cards.json` 和已校验缓存复制到 `legacy/`，原文件保留。旧记录缺少设备归属，只作候选，不成为可恢复备份。
- 后端 stderr 诊断写入 Tauri 应用数据目录 `com.aircard.desktop/logs/backend.log`；原生失败诊断保留在对应事务目录，不进入 stdout 协议。

每行一个 UTF-8 JSON 请求：`{"v":1,"id":"unique-id","method":"overview","params":{}}`。返回同一个 id 的 `ok/result` 或 `ok/error.code`。进度消息携带 `event: progress`、`operationId` 和实际 `stage`。重复 id 返回之前的结果；同进程同一时刻只有一个设备事务。

允许的操作：`hello`、`overview`、`device`、`scan.start/stop`、`image.inspect/prepare`、`card.classify/read/apply/restore/export`、`recovery.resume`、`cancel`。`shutdown` 仅由 Rust 关闭窗口使用。界面不提供 shell 或任意设备路径接口。

## 验收边界

自动化测试覆盖隔离、原有缺失文件、备份损坏、部分写入回滚、恢复续接、worker 超时/崩溃、分片和非法消息、重复请求、图片和界面交互。模拟器故障测试不通过中断真实卡片写入制造故障。

Windows 真机和 macOS arm64 本地启动记录见 `../docs/desktop-validation.md`。测试版未签名，不含自动更新。Mac 卡片操作、无开发环境的独立 Windows 机器，以及各档高 DPI 的人工验收仍需对应环境，不能用构建成功替代。
