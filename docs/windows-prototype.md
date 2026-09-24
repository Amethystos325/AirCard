# Windows 原型与真机验证

## 结果

2026-09-23 已在 Windows 11 x64、Python 3.12.13、Microsoft Store iTunes
`12139.11001.62009.0`、USB 连接的 `iPhone14,2 / iOS 27.0` 上验证。

**Windows 设备层的核心原型验证通过：Grappa 认证，以及隔离文件的四轮传输、
两次读回、恢复和清理，均已在真机完成。**
这不是可更换卡面的 Windows 发布版。

| 验证项 | 真机结果 |
| --- | --- |
| USB 发现、配对、设备信息 | 通过 |
| AFC、os_trace_relay、streaming_zip_conduit、atc 服务 | 均能打开 |
| unified log 流 | 5 秒内解析 9,689 条记录，其中 2,238 条匹配 Wallet 相关关键词 |
| 卡片扫描 | 此次观测得到 0 个候选；没有验证完整卡片检测及 pass.json 分类 |
| Media 测试文件写入、读回、覆盖、恢复、删除 | 通过；测试目录已清理 |
| StreamingZip 上传及解包 | 通过；测试 payload 字节与 symlink 类型均经 AFC 检查 |
| Windows Apple DLL 加载 | CoreFoundation、MobileDevice、AirTrafficHost 均成功 |
| AirTraffic 初始消息 | 收到 InstalledAssets、AssetMetrics、SyncAllowed |
| Grappa 会话 | 已建立，ATHostConnectionGetGrappaSessionId 非零 |
| 开始同步 | RequestingSync 后收到 ReadyForSync；MetadataSyncFinished 后收到 AssetManifest |
| Media 以外的测试文件读写 | `/var/tmp/aircard-probe-*.bin` 写入 → 移回读出 → 写回 → 再移回读出，通过；两次 294 字节均与原始 payload 一致 |
| Books 恢复及测试清理 | 六个受跟踪文件与本轮及最初备份均一致；12 个暂存路径全部不存在；SQLite quick_check 为 ok |
| 本轮手机端错误监测 | 2,555 条 atc 日志中，SQLite I/O、Grappa、测试资产不存在错误计数均为 0 |
| Wallet 卡面写入 | 未执行 |

本次完整成功记录：

- `build/windows-probe/airlift-canary.json`：`status=passed`、`airtrafficVerified=true`、`walletWriteVerified=false`。
- `build/windows-probe/recovery-0d25de2b1587d5dbdb1d3e7399fb1435/state.json`：四次传输均成功，两个读回 SHA-256 与原始 payload 相同，恢复/清理标志全部为 true。
- `build/windows-probe/canary-log-summary.json`：仅保存错误计数，不保留原始设备日志。
- `build/windows-probe/post-canary-verification.json`：另开连接独立复查 Books、数据库完整性及暂存清理，全部通过。

初始失败在手机端表现为：

```text
Grappa session could not be established. Aborting
```

主机端追踪进一步定位到 `RegOpenKeyExA(HKLM, Software\Apple Inc.\CoreFP)`
返回 2（键不存在），随后记录 `Failed to initialize grappa, err=-42404`。
为隔离 worker 提供其已安装 CoreFP.dll 的正确路径后，同步认证通过。

随后发现每轮替换 Books 清单会使手机清理上一轮遗漏的资产，导致刚写入的测试文件
在下一次读回前被删除。原型现在保留原有 Books 条目和各轮测试条目，分配不冲突的
Item ID，并为第二次读回使用不同的资产标识。修正清单后已成功读回第一次写入的文件。
该失败轮次已恢复 Books、读回校验并清理测试文件；记录在
`build/windows-probe/recovery-b8b8113deea2df8a5f16a42b37db41f2/state.json`。

先前对已映射数据库直接写回造成手机同步进程 SQLite I/O 错误。
恢复已改为临时文件写入、读回校验后 rename 替换，避免截断现有映射；
用户重启手机清除旧映射后，六个受跟踪文件仍与恢复备份一致，SQLite quick_check 通过。
随后完整四轮复验成功，未再观察到 SQLite I/O 错误；结束后的独立复查亦通过。
同步未就绪时原型不会上传 ZIP 或替换 Books 输入。

## 使用

依赖 Python 3.12 x64（带 `py` 启动器）或 `uv`，以及 Apple 官方 iTunes 组件。
Python 3.13 在本机安装完整 pymobiledevice3 依赖时，因 lzfse 缺少相应 Windows wheel
而要求 C++ 编译器；原型因此单独使用 3.12。

```powershell
# 创建独立环境并安装锁定版本依赖；随后执行组件检查。
.\backend\run_windows_probe.ps1 -Setup

# 设备保持解锁，并确认已信任这台电脑。
.\backend\run_windows_probe.ps1 -Command device
.\backend\run_windows_probe.ps1 -Command services
.\backend\run_windows_probe.ps1 -Command trace -Seconds 15

# 仅使用新生成的 Media 测试文件。
.\backend\run_windows_probe.ps1 -Command afc-canary

# 读取初始同步消息，与测试同步是否就绪是两个不同步骤。
.\backend\run_windows_probe.ps1 -Command atc-handshake
.\backend\run_windows_probe.ps1 -Command atc-sync-check

# 前置同步检查通过后，测试随机 /var/tmp 文件的完整循环。
# 会暂时更改 Books 同步输入；成功时校验恢复并清理测试数据。
.\backend\run_windows_probe.ps1 -Command airlift-canary
```

多个 USB 设备连接时使用 `-Udid` 指定目标。用 `-Report` 指定 JSON 输出位置；
默认输出到 `build/windows-probe/` 下的独立文件。
`-DllDir` 可为 doctor 增加搜索目录；`-AppleRuntime` 可指定包含完整可加载
x64 Apple DLL 的目录。默认运行时准备只覆盖本次测试过的 Store iTunes 包布局。
Apple Devices、传统桌面 iTunes 和 ARM64 环境尚未验证。

命令返回非零退出码表示失败、被阻塞或观察结果不足。
`doctor` 的 `observed` 和 `atc-handshake` 的 `passed` 只表示各自检查完成，
必须同时阅读 `airtrafficVerified`、`walletWriteVerified` 等字段，不能当作卡面写入成功。

## 实现与兼容性发现

- `backend/windows_probe.py`：环境与 PE 导出检查、USB 配对、服务、日志、AFC、隔离子进程。
- `backend/windows_airtraffic.py`：ctypes 调用 Windows Apple DLL，遵循已有 macOS helper 的消息顺序。
- `backend/windows_apple_runtime.py`：worker 内的 Store CoreFP 路径适配及退出清理。
- `windows_canary.py`：随机测试路径、Books 备份校验、失败恢复和受限清理。
- `backend/run_windows_probe.ps1`：Windows 启动和环境安装入口。

本机 iTunes 对 pymobiledevice3 默认 `qt4i-usbmuxd / pymobiledevice3` 标识的 Connect
请求发生超时；相同请求改用 AirCard 标识后成功。原型仅在自己的进程中适配请求标识，
锁定 pymobiledevice3 11.17.0，没有修改安装包源码。尚不推断此行为在其他 iTunes 版本的原因。

直接从 WindowsApps 路径加载 DLL 出现 Access denied。原型从用户已安装的 iTunes
复制 DLL 到被 Git 忽略的 `.tmp/apple-runtime/`，供隔离 worker 加载。
没有下载第三方 DLL，也没有将 Apple 二进制纳入项目分发。
原型不会写入系统注册表。

本机 Store 包中的 CoreFP 注册位于包内 Registry.dat，LibraryPath 使用包根路径占位符。
普通未打包进程不能假设拥有 iTunes 的包内运行环境。
`backend/windows_apple_runtime.py` 创建进程私有 hive，仅在 AirTrafficHost 导入表中重定向
`RegOpenKeyExA/W` 对这一精确 HKLM 键的查询。其余键仍走系统 API，
Apple 的认证函数与 DLL 文件保持原样。worker 退出前恢复导入表并删除私有 hive。
这是针对已验证 x64 版本的实验适配；没有系统/用户注册表改动或 Apple DLL 再分发。
本机实测 ANSI/Unicode 查询、其他 HKLM 键访问、导入表恢复及临时 hive 清理均通过。

## 恢复与边界

`airlift-canary` 仅针对固定 `/var/tmp` 目录下的新随机 `aircard-probe-*.bin`，
验证写入 → 移回 Media 读回 → 写回恢复 → 再次移回读回并清除。
这条完整链路已通过模拟测试和上述设备配置的真机验证。
结果只证明这一环境下的隔离文件传输能力，尚未验证真实卡片文件或其他 iOS/Apple 组件版本。

Books 原有六个受跟踪文件保存到每次运行的 `recovery-*` 目录，保存大小与 SHA-256；
恢复前验证全部备份，恢复后检查字节和存在状态。原型在收到失败时保留本地备份。
受跟踪路径与现有 macOS helper 一致；并非整个设备或整个 Books 库的备份。
不要与其他同步操作同时运行 canary，以免恢复覆盖并发修改。
未来如果在真正传输后中断，随机测试文件可能遗留；查看该次 `state.json` 的阶段和路径，
保留恢复目录。不要将这条实验路径直接用于真实 Wallet 文件。

native worker 设有独立超时并会被结束；设备操作和恢复也有时间上限。
报告不保存原始设备日志、卡片标识或 UDID；本地恢复记录保留设备标识的哈希，用于区分设备。

## 自动化验证

```powershell
& .\.tmp\windows-prototype-py312\Scripts\python.exe -m unittest discover -s tests -p test_windows_probe.py -v
```

15 项测试覆盖日志长度/字节序/截断、多行记录、客户端标识适配、AFC 回读与清理、
路径冲突、备份篡改拒绝恢复、symlink 清理边界、同步失败后 Books 恢复、
前置检查失败时禁止暂存、精确注册表重定向范围、严格 canary 路径限制、
不截断原文件的恢复，以及保留原有/前序 Books 条目的模拟 canary 循环。
这些测试不能代替真机同步成功；旧 macOS 应用的 Windows 测试失败项本次未修改。

## 下一步

原型验收条件已满足：两次读回均与 payload 一致、Books 恢复验证成功、
测试文件及暂存清理完成。Windows 设备通信和 AirTraffic 传输路线已得到真机支持。

下一阶段是将这套设备层接入卡片发现/读取/恢复流程，移植图片转换和文件持久化，
再新增 Windows GUI 与安装包。当前尚未接入这些功能，也未改动 macOS 业务入口。

外部参考：[pymobiledevice3](https://github.com/doronz88/pymobiledevice3)、
[Windows AirTraffic 调用声明](https://github.com/peter158/MobileDevice-1/blob/master/AirTrafficHost.py)。
