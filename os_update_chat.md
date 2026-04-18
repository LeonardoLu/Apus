[4 tools called]

## 保留/恢复虚拟机用户数据的可行方案

**可以做到**，但需要根据升级方式选择不同策略。结合你的 Apus 项目现有功能，有以下几种方案：

---

### 方案一：OTA 就地升级（最简单，但风险高）

直接在虚拟机内通过「系统设置 → 软件更新」升级。如果成功，所有用户账号、开发环境、文件**自然保留**（跟真机升级一样）。

**风险控制**：利用 Apus 已有的 **克隆功能** 先备份一份：

```362:407:Apus/Apus/VM/VMManager.swift
    /// 克隆虚拟机（包括磁盘镜像、硬件模型等，生成新的机器标识和 MAC 地址）
    /// APFS 文件系统上使用 Copy-on-Write，克隆几乎是瞬间完成的
    @discardableResult
    func cloneInstance(_ instance: VMInstance) -> VMInstance? {
        guard instance.isInstalled else { return nil }
        // ... 复制 AuxiliaryStorage, Disk.img, HardwareModel ...
    }
```

> ✅ 推荐操作：**先克隆 → 再在副本上尝试 OTA 升级**。升级失败不影响原始 VM。

---

### 方案二：新建 VM + Migration Assistant 迁移（最稳妥）

1. **保留旧 VM 不动**
2. **新建 VM**，用最新 IPSW 全新安装新版 macOS
3. **同时启动两台 VM**（Apus 支持多 VM 并发运行），通过 **macOS 迁移助理（Migration Assistant）** 从旧 VM 网络迁移到新 VM

迁移助理可以迁移：
- ✅ 用户账号和密码
- ✅ 应用程序
- ✅ 文档和数据
- ✅ 系统设置

前提条件：两台 VM 需要在同一网络中。你的项目已支持 **NAT 和桥接网络**：

```952:956:Apus/Apus/VM/VMManager.swift
        vmConfig.networkDevices = [VMConfiguration.createNetworkDeviceConfiguration(
            macAddress: resolvedMACAddress(for: instance),
            networkMode: instance.networkMode,
            bridgedInterfaceID: instance.bridgedInterfaceID
        )]
```

> 如果使用 **桥接模式**，两台 VM 都会获得局域网 IP，迁移助理可以直接发现对方。NAT 模式下两台 VM 也在同一虚拟子网中，通常也能互相发现。

---

### 方案三：通过 VirtioFS 共享文件夹手动备份/恢复（灵活但需手动操作）

利用 Apus 已有的 **VirtioFS 共享文件夹**功能：

```979:989:Apus/Apus/VM/VMManager.swift
        // VirtioFS 共享文件夹
        if let sharedPath = instance.sharedDirectoryPath {
            let sharedURL = URL(fileURLWithPath: sharedPath)
            if FileManager.default.fileExists(atPath: sharedPath) {
                let shareDevice = VMConfiguration.createDirectoryShareDeviceConfiguration(sharedURL: sharedURL)
                vmConfig.directorySharingDevices = [shareDevice]
                NSLog("[Apus VirtioFS] 已配置共享文件夹: \(sharedPath)")
            }
        }
```

操作步骤：
1. 在旧 VM 中，将重要数据拷贝到 VirtioFS 共享文件夹（自动挂载到 Finder 侧边栏）
2. 新建 VM 安装新版 macOS
3. 为新 VM 配置同一个共享文件夹路径
4. 从共享文件夹恢复数据

适合备份的内容：
- `~/Documents`、`~/Desktop`、`~/Downloads` 等用户文件
- `~/.ssh`、`~/.gitconfig` 等开发配置
- Homebrew 的 `Brewfile`（用 `brew bundle dump` 导出）
- 项目代码仓库

---

### 方案四：Time Machine 备份到共享文件夹（完整恢复）

1. 在 VM 设置中配置一个 VirtioFS 共享文件夹指向宿主机的一个大容量目录
2. 在旧 VM 内将该共享文件夹设为 Time Machine 备份目标
3. 完成备份后，新建 VM 安装新版 macOS
4. 新 VM 首次设置时选择「从 Time Machine 备份恢复」

> ⚠️ 注意：Time Machine 通过 VirtioFS 备份可能速度较慢，且稳定性未经充分验证。

---

### 总结对比

| 方案 | 数据完整性 | 操作复杂度 | 风险 | 推荐场景 |
|------|-----------|-----------|------|---------|
| **OTA 就地升级**（先克隆） | ⭐⭐⭐⭐⭐ | 低 | 中（可能 kernel panic） | 小版本更新 |
| **Migration Assistant 迁移** | ⭐⭐⭐⭐⭐ | 中 | 低 | 大版本升级（最推荐） |
| **VirtioFS 手动备份** | ⭐⭐⭐ | 高 | 低 | 只需要保留文件和配置 |
| **Time Machine 恢复** | ⭐⭐⭐⭐⭐ | 中 | 中 | 需要完整系统恢复 |

**我最推荐的做法是**：先用 Apus 的克隆功能克隆一份 VM，在克隆的副本上直接尝试 OTA 升级。如果成功就万事大吉；如果失败，再走 Migration Assistant 方案。两种方案 Apus 当前的功能（克隆、多 VM 并发、桥接网络、VirtioFS 共享）都已经能很好地支持。