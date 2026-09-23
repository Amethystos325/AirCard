# Windows 支持可行性评估

评估日期：2026-09-23。代码基线：`fd12a85`。

后续已实现并进行 Windows 真机原型验证；最新结果与运行方法见
[Windows 原型与真机验证](windows-prototype.md)。下文保留初始可行性评估。

## 结论

有可行的移植路线，但当前版本不能在 Windows 上完整构建或运行。
需要替换桌面界面、移植设备助手，并验证 AirTraffic 同步调用。
现有 Python 业务流程可以保留；仅修改构建脚本或安装 Windows Swift 不能解决问题。

最大的未决项是：Windows 上的 Apple 同步组件能否完成本项目依赖的
AirTraffic 操作。应先验证这部分，再投入完整界面和安装包开发。
本次完成的是源码审查、依赖调研和 Windows 测试基线，尚未实现 Windows 版，
也未进行任何真机卡面读写。

## 当前平台依赖

| 部分 | 代码位置 | Windows 所需工作 |
| --- | --- | --- |
| 桌面界面 | `AirCardApp.swift` | 使用 SwiftUI、AppKit、PDFKit；需要新增 Windows 界面或跨平台界面 |
| 设备连接、日志、文件传输 | `Sources/device_helper.m` | Objective-C/Foundation + MobileDevice 私有接口；需要 Windows 实现 |
| AirTraffic 同步 | `Sources/airtraffic_host.m` | 直接链接 AirTrafficHost.framework；需要验证 Windows DLL 接口或实现通信协议 |
| 图片处理 | `card_assets.py`、`aircard_backend.py`、`aircard.py` | PNG 转 PDF 强制使用 `/usr/bin/sips`；需要跨平台转换器并检查输出效果 |
| 恢复备份、缓存 | `card_export.py`、`card_cache.py` | POSIX 目录 `open/fsync` 在 Windows 报错；需要平台化持久化操作 |
| 路径、进程和终端扫描 | `aircard.py`、`aircard_backend.py`、`apply_card_skin.py` | 修正 PATH 分隔符、工具后缀、存储路径、UTF-8 编码和管道读取 |
| 打包 | `Makefile`、`build.sh` | 新增 Windows 构建入口和安装包，不使用 xcrun、codesign、lipo、DMG |

另有几个容易漏掉的问题：

- `aircard.py` 的交互扫描对 stdin 和子进程管道使用 `select.select`，不能原样移植到 Windows。
- 缓存和恢复目录硬编码为 `~/Library/Application Support/AirCard/`；Windows 应使用应用数据目录。
- 当前 helper 查找逻辑没有 Windows `.exe` 或 Python helper 命令的抽象。
- 文件 `chmod(0600)` 不能在 Windows 上提供与 POSIX 权限完全相同的语义。
- 扫描不只是读日志：当前版本还读取 `pass.json` 以验证卡片类型，涉及 AirTraffic 读取与恢复。
  因此“Windows 能显示日志”还不能算“完整扫描功能已移植”。
- `probe` 只检查会话、设备类型及 Books 状态；`airlift_compatible` 的现有判定
  不能代替一次实际的 AirTraffic 读写验证。

## 两种设备层方案

### 优先验证 Apple Windows DLL

现有开发者代码曾在 Windows 上加载 `CoreFoundation.dll`、
`iTunesMobileDevice.dll` 和 `AirTrafficHost.dll`，并查找 AirTraffic 同步函数。
这表明存在 Windows 对应组件的技术路线，但该示例环境是 Windows 10、
iTunes 12.5.3.16 和 iOS 10.1.1，不能据此保证现代安装包及 iOS 的兼容性。

来源：[开发者的 Windows DLL 调用示例](https://github.com/aizhou01/-)。

建议先从用户安装的 Apple 官方组件中定位 DLL，检查位数、依赖、导出符号、
调用约定及连接初始化。用独立 Windows helper 封装接口，保留目前的命令与 JSON 协议。
不要假设旧示例的函数签名、内存布局和 macOS 实现完全相同。
本机常见 Apple 安装目录与当前用户 Apple Appx 包查询没有发现这些组件，
因此本次未能进行 DLL 加载或函数验证；这不代表已穷尽所有自定义安装位置。

### 跨平台协议实现

`pymobiledevice3` 明确支持 Windows，并提供设备发现、日志和 AFC 文件访问。
这些能力可以替换设备助手中的一部分。其安装文档要求 Windows 安装 iTunes。

来源：[项目说明](https://github.com/doronz88/pymobiledevice3)、
[安装文档](https://doronz88.github.io/pymobiledevice3/installation/)。

本次检查上游文件树，没有发现按 AirTraffic/ATC 命名的现成服务实现。
这不是协议无法实现的证明，但不能假设安装该库就能替换 `airtraffic_host`。
本项目还需要 StreamingZip 上传、AirTraffic 消息交互、Books 状态保存与恢复，
必须逐一验证。该库声明 GPL-3.0，当前项目声明 MIT；若选用，需要在发布设计中
单独处理依赖许可，不能默认依赖许可与现有项目相同。

上游 [airlift 说明](https://github.com/0xjohnnydev/airlift/blob/main/README.md)
目前描述的是配对 Mac 路线，其架构使用 MobileDevice 和 AirTrafficHost。
不能把上游的 Mac 验证结果算作 Windows 验证结果。

## 建议实施顺序与验收条件

1. **设备连接和同步能力原型。** 在 Windows 上连接已信任的 iPhone，确认设备信息、
   AFC 与 unified log 可用；确认 Windows AirTraffic 连接和消息交互。
   日志应保留 `os_trace_relay` 对应的能力，不能只用 legacy syslog 替换。
2. **隔离测试文件的完整操作。** 使用专门的测试文件，验证写入、读取、字节校验、
   恢复和清理，并确认 Books 同步状态恢复。当前项目读文件会暂时移动原文件，
   故必须验证失败恢复后，才能进入真实卡面测试。
3. **移植共享后端。** 抽出设备命令和平台工具选择；替换 sips；处理 Windows
   缓存目录、持久化写入、中文路径、进程编码、超时及扫描取消。
   保留 macOS helper 路径以便回归。
4. **新增 Windows 界面。** 围绕现有 JSON 后端实现设备状态、扫描、分类、预览、
   图片选择、读取、导出和写入。技术选择可在原型通过后确定，无需先重写所有业务。
5. **打包与真机验收。** 在未安装开发环境的 Windows 11 上验证运行库和 Apple
   驱动依赖；覆盖断线、锁屏、取消、写回失败和恢复记录保留。
   最终验收必须包含 Wallet 实际显示新卡面，不能只以进程退出码为依据。

第一阶段通过前，无法可靠估计完整移植周期。GUI 与本地文件处理属于可控开发工作；
私有同步组件的兼容性是主要时间变量。

## Windows 实测基线

环境：Windows，Anaconda Python 3.13.9，AMD64。

```powershell
python -m unittest discover -s tests -v
```

共 32 项：14 通过，15 报错，1 失败，2 跳过。

- 15 项报错来自恢复备份/缓存流程中的目录 `os.open(..., os.O_RDONLY)`，
  Windows 返回 `PermissionError`。
- `test_flash_writes_pdf_and_removes_rendered_cache` 失败：该测试保留真实图片转换，
  当前实现依赖不存在的 `/usr/bin/sips`，导致 flash 返回失败。
- 2 项原生日志读取测试显式要求 macOS，故跳过。
- 设备调用大多被测试替身替代；通过的测试不证明 Windows 可以连接或修改真实 iPhone。

项目现有扫描验证文档只记录了 iPhone 15 Pro / iOS 18.6.2 的 Mac 扫描测试，
且注明当时没有刷写卡面。Windows 移植需要独立记录设备、系统、Apple 组件版本和实测范围。
