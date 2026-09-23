# AirCard Desktop 验证记录

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

## 待对应环境验收

- macOS 14+ arm64、x64 构建及真实设备流程。
- 无 Python 开发环境的另一台 Windows 11 机器。
- Windows 各档高 DPI、Retina 的人工操作检查。
