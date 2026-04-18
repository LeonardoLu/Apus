# Apus — Agent 工作说明

面向在本仓库中改代码、查问题的自动化助手与人类协作者。Apus 是 **macOS 原生 SwiftUI 应用**，用 **Virtualization.framework** 管理 **macOS 虚拟机**。

## 技术栈与运行环境

- **语言 / UI**：Swift、SwiftUI；界面与面向用户的文案以 **简体中文** 为主（与现有代码一致）。
- **核心框架**：`Virtualization`（`VZVirtualMachine`、macOS 安装器与 IPSW 流程等）。
- **宿主系统**：需在 **Apple Silicon macOS** 上开发与运行；模拟器无法替代真机虚拟化能力。

## 仓库布局


| 路径                                    | 说明                                                                      |
| ------------------------------------- | ----------------------------------------------------------------------- |
| `Apus/Apus.xcodeproj/`                | Xcode 工程                                                                |
| `Apus/Apus/`                          | 应用源码（`ApusApp.swift`、`ContentView.swift`、`NotificationManager.swift` 等） |
| `Apus/Apus/VM/`                       | 虚拟机领域逻辑：`VMManager`、`VMInstance`、`VMConfiguration`、`VMConstants`        |
| `Apus/Apus/Views/`                    | 独立视图组件（如创建 VM、设置、显示窗口等）                                                 |
| `Apus/ApusTests/`、`Apus/ApusUITests/` | 单元测试与 UI 测试                                                             |
| `demo/`                               | 与主应用分离的演示或辅助内容（改前确认用途）                                                  |
| `os_update_chat.md`、`porting_chat.md` | 讨论/备忘文档，**非**构建依赖                                                       |


## 构建与运行

1. 用 **Xcode** 打开 `Apus/Apus.xcodeproj`。
2. 选择 **Apus** scheme，目标为 **My Mac**（Apple Silicon）。
3. 虚拟化、网络客户端等能力见 `Apus/Apus/Apus.entitlements`；桥接网络可能需额外系统权限（代码中已有回退与说明）。

修改后若条件允许，应在 Xcode 内 **Build** 或通过 `xcodebuild` 验证编译通过。

## 架构要点（改代码前先读）

- `**VMManager`**：虚拟机列表持久化、IPSW 下载/安装、启停、暂停、克隆、导入导出、磁盘扩容等与 `VZVirtualMachine` 相关的编排中心。
- `**VMRuntime` / `VMState**`：单台 VM 的运行时状态与 UI 绑定（含下载进度、运行时长等）。
- `**VMInstance**`：`Codable` 配置模型；注意 **向后兼容** `config.json`（解码时处理缺失字段）。
- `**VMConfiguration`**：把 `VMInstance` 转为 `VZVirtualMachineConfiguration`（图形、网络 NAT/桥接、VirtioFS、USB 镜像等）。
- `**ContentView` 与 `ApusApp**`：主导航、菜单栏、`WindowGroup` 多窗口与 `Settings` 场景入口。

新增功能时优先 **扩展现有类型**，避免平行的第二套 VM 状态机。

## 编码约定

- 与现有文件保持同一风格：命名、注释密度、`import` 顺序、SwiftUI 组织方式。
- 用户可见字符串、日志中面向用户的说明：**简体中文**（技术标识符、API、符号名保持英文）。
- 避免无关重构、大范围格式化或与任务无关的文件改动。
- 涉及文件系统路径、网络与虚拟化权限时，保持与现有 `NSLog` / 错误处理模式一致；不要静默吞掉关键错误。

## 安全与隐私

- 不要提交证书、密钥、个人路径或本机独有数据。
- 虚拟机数据目录可能含用户系统镜像；文档或示例中勿使用真实用户路径。

## 测试

- 有逻辑变更时，优先补充或更新 `ApusTests` 中可单元测试的部分；UI 流变更考虑 `ApusUITests`。
- 无法在沙箱 CI 中完整验证虚拟化时，在说明中注明需在真机 Xcode 下手动验证。

## 与用户协作

- 交付说明写清 **改了什么、为什么**，以及如何在 Xcode 中验证。
- 若需求涉及桥接网络、USB 挂载、大版本 macOS 行为差异，先对照代码与 `os_update_chat.md` / `porting_chat.md` 中的结论再实现。