# Windows 诊断工具

`backend/run_windows_probe.ps1` 是独立的 Windows 设备诊断入口。跨端客户端已经提供卡面扫描、读取、更换和恢复；日常使用请打开应用，无需先运行诊断工具。

## 已验证范围

2026-09-23 在 Windows 11 x64、Python 3.12、Microsoft Store 版 iTunes 和 iOS 27.0 设备上，完成了 USB 发现、配对、日志读取和隔离测试文件的写入、读回、恢复与清理。这些结果只对应当时的设备与软件组合。跨端客户端的实际卡面操作结果见[验证记录](desktop-validation.md)。

## 使用

从仓库根目录打开 PowerShell。准备 Python 3.12 x64 或 `uv`，安装并启动已验证的 iTunes 版本，连接、解锁手机并确认信任电脑：

```powershell
.\backend\run_windows_probe.ps1 -Setup
.\backend\run_windows_probe.ps1 -Command doctor
.\backend\run_windows_probe.ps1 -Command device
.\backend\run_windows_probe.ps1 -Command services
.\backend\run_windows_probe.ps1 -Command trace -Seconds 15
```

`-Udid` 可在连接多个设备时指定目标，`-Report` 可指定 JSON 结果文件。默认报告位于被 Git 忽略的 `build/windows-probe/`。命令返回非零退出码时，应查看报告中的错误信息；设备可连接不代表卡面操作兼容。

诊断工具和跨端客户端只验证了上述 iTunes 安装方式。其他安装方式及 Windows ARM64 尚未验收。
