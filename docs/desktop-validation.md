# AirCard Desktop 验证记录

本项目使用本地测试、构建和安装验收，不使用 GitHub Actions / CI。复现步骤见 `../desktop/README.md`；各平台结果仅由对应本地环境的实际执行确认。

日期：2026-09-23。Windows 11 x64，iPhone14,2，iOS 27.0 / 24A437。唯一更换测试卡片：用户明确指定的 Suica（卡片元数据为 JR 东日本）。不记录设备序列号或卡片标识。

## 已完成

- 设备发现、日志候选扫描、元数据分类和读取回写。
- 原始素材备份并校验：原 PDF 848,627 字节；@2x 和 @3x PNG 原本不存在。
- 生成 1536 × 969 蓝色测试卡面，写入两份 PNG 与 PDF，回读校验通过。
- 用户已确认在手机 Wallet 中看到“AirCard / WINDOWS TEST”蓝色卡面。
- 更换完成后的 Books 六个文件及原有存在状态恢复、暂存清理通过，无未完成事务。
- PyInstaller onedir 后端及 Rust 构建通过；桌面 WebdriverIO 已验证真实冻结后端 hello、中英文和深色主题。

## 首次备份恢复已通过

首次恢复遇到 Apple 同步超时，持久化事务保留并阻止新修改。检查发现一次搬移尚未开始；后续读回写超时则存在经过校验的本地副本。已增加这两种状态的恢复测试、逐文件回滚检查点，以及 Windows 文件短暂占用时的原子替换重试。没有通过强制中断真实写入制造故障。

中断事务已完成回滚，随后成功恢复首次备份：原 PDF 字节校验通过，两份原本不存在的 PNG 已移除，Books 恢复和暂存清理通过，待恢复记录为零。用户已确认手机 Wallet 恢复原卡面。

自动化：后端 67 项测试完成，65 项通过、2 项仅 macOS 原生测试在 Windows 跳过；前端 4 项通过，WebdriverIO 桌面冒烟 1 项通过。

## Windows 安装包验证

- NSIS 安装成功，测试版约 33.7 MB。安装目录含空格，冻结后端与构建产物校验一致。
- 清除 `PYTHONHOME`、`PYTHONPATH`、`VIRTUAL_ENV`、`AIRCARD_PYTHON`，PATH 仅保留 Windows System32；从安装目录启动冻结后端。
- 实际设备连接、Suica 卡面读取、原文件回写、PDF 预览、Books 恢复与清理通过；没有未完成事务。
- 成功导出至含中文及空格的 ZIP 路径，关闭协议后正常退出。
- 验证期间修复系统 PowerShell 路径发现，以及 Windows worker 继承主进程协议 stdin 导致的启动等待；worker 现使用独立的空输入，保留 stdout/stderr 捕获和超时边界。
- 安装包不含 Apple DLL；发布构建未启用 `e2e` feature，测试驱动权限仅在测试配置启用。

可交付安装包：`build/AirCardDesktop-0.2.0-windows-x64.exe`。

SHA-256：`410b9db9a882f1e39fae445d40219fbb47cd98e1f1398a6ab9289b1f402d1728`。

本机日志：`build/desktop-suica-acceptance.json`、`build/desktop-installed-verification.json`、`build/desktop-e2e.log`。这些产物不纳入 Git，不包含在公开文档中展示的设备标识。

## 本地构建复核（2026-09-23）

基于 `a135110`，移除桌面 GitHub Actions 工作流并更新本地构建文档后，在 Windows 11 x64 再次执行：后端 65 项通过、2 项 macOS 测试跳过；前端 4 项通过；`pnpm bundle` 完成 TypeScript / Vite、Rust release 和 NSIS 打包。复用先前已验证的冻结后端资源；本轮未重新执行安装与真机写入。

本次产物：`desktop/src-tauri/target/release/bundle/nsis/AirCard Desktop_0.2.0_x64-setup.exe`。

SHA-256：`d6cc9a7b23ee449eaff7f8c4fdb5be075eec732073fe22986d0c163434b4b198`。上面的 `build/` 交付副本及其安装验收记录保持对应原产物。

## 原版 UI 复刻复核（2026-09-23）

- 参照 `AirCardApp.swift` 恢复紧凑顶栏、设备胶囊、卡片内操作、扫描提示、空状态引导和底部日志；加入 CSS 半透明材质、倾斜光泽、读取扫光及大图缩放。
- 前端 8 项测试通过，覆盖选图和原生拖放只进入预览、明确点击才写入、卡片内读取锁定、大图查看、会话内隐藏及恢复、双语和日志。
- Windows WebdriverIO 冒烟 1 项通过，验证冻结后端、语言和主题。测试配置使用独立应用标识；结束时走正常窗口关闭和后端安全退出流程。测试驱动清理会输出非阻断警告，最终测试进程退出码为 0，无测试后端驻留。
- 使用合成卡片在本地浏览器检查 1100 × 780 和 820 × 600 窗口、浅色 / 深色、中文、更换预览和大图适应窗口。本轮未执行真实卡面写入，macOS 视觉尚未实机对照。
- 生产构建通过 TypeScript / Vite、Rust release 和 NSIS 打包；不含测试插件或开发预览数据。复用已验证的冻结 Python 后端，本轮未重装。

UI 复刻版安装包：`build/AirCardDesktop-0.2.0-windows-x64-ui.exe`。

SHA-256：`1cf8d835653672e1ef3e517bb16a7b623ef78293814531a7176e1201e3ce1e7d`。原 `build/AirCardDesktop-0.2.0-windows-x64.exe` 保留；构建目录下的 NSIS 产物已更新为本次 UI 版本。

## macOS 本地构建与界面验证（2026-09-24）

- 基于 `255bb35` 及本轮 Mac 打包修复，在 macOS 27.0 arm64、Xcode 27、Python 3.12.14、Rust 1.98.1 上完成原生 helper、冻结后端和 Tauri release 构建，生成 `.app` 与 `.dmg`。
- 后端运行 71 项测试（70 项通过、1 项跳过）；前端 8 项测试通过，TypeScript / Vite 生产构建通过。冻结后端的 `hello`、`shutdown` 协议通过；包内 `airtraffic_host` 直接执行正常返回参数错误，签名有效，系统 Framework 链接未被改写。
- 从 `.app` 实际启动，确认空状态、顶栏、底栏和状态提示显示；最终构建自动发现已连接的 iPhone。切换简体中文与深色主题正常。对照原 SwiftUI 应用窗口及合成卡片预览，卡片大小、网格、胶囊状态和卡片内按钮的布局基本一致；macOS 标题栏已隐藏标题文字。
- 修复 PyInstaller 收集系统私有 Framework 导致的 arm64 切片错误及 helper 链接改写；两个 Universal helper 的最低 macOS 版本现为 14.0。
- 设备自动发现和扫描已执行。扫描中的 `pass.json` 读取未能取得预期的恢复副本，因此无法确认原文件位置；这不等于已证实手机原文件缺失。Books 中的临时同步条目已按原快照恢复，没有开始写入卡面。用户目视检查 Wallet 未见异常后，将此次未解决的事务归档，保留完整本地恢复数据和设备暂存；对应卡片继续隔离，其他卡片可以扫描。此处不将真机卡片流程标记为通过。
- 新增一次性恢复重试及扫描遇到待恢复事务时自动停止的处理。归档后再次构建并启动 `.app`，待恢复提示已消失，其他卡片扫描入口可用；未安装到另一台 Mac，macOS 14 到 26 的实际运行也尚未验证。

产物：`desktop/src-tauri/target/release/bundle/dmg/AirCard Desktop_0.2.0_aarch64.dmg`。SHA-256：`95d2d24683169060ad43a3794fd66dcd93877acafbea2e5821b8da605056b12c`；`hdiutil verify` 通过。本地测试包未做发行签名或公证。

## 待对应环境验收

- macOS 14 到 26 的实际运行、Intel x64 构建及 iPhone 真机流程。
- 无 Python 开发环境的另一台 Windows 11 机器。
- Windows 各档高 DPI、Retina 的人工操作检查。
