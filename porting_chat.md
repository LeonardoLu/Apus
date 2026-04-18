## 好消息：主机和 VM 之间其实已经可以互通

使用 `VZNATNetworkDeviceAttachment` 时，Apple 的 vmnet 框架会在宿主机上创建一个虚拟网桥接口（通常是 `bridge100`），所有 VM 和宿主机都在同一个子网（`192.168.64.0/24`）上：

```
宿主机 (192.168.64.1) ←→ bridge100 虚拟网桥
     ↕                        ↕                ↕
   VM-A (192.168.64.2)   VM-B (192.168.64.3)  ...
```

### 验证步骤

**1. 在 VM 内查看 IP 地址：**
打开虚拟机中的「终端」执行：

```bash
ifconfig en0
# 或
ipconfig getifaddr en0
```

你会看到类似 `192.168.64.2` 的地址。

**2. 从宿主机访问 VM：**

```bash
# 宿主机终端
ping 192.168.64.2        # ping VM
ssh user@192.168.64.2    # SSH 连入 VM（需先在 VM 内开启远程登录）
curl http://192.168.64.2:8080  # 访问 VM 上的 Web 服务
```

**3. 从 VM 访问宿主机：**

```bash
# VM 内终端
ping 192.168.64.1        # 网关 IP 就是宿主机
```

**4. VM 之间互访：**

```bash
# VM-A 内
ping 192.168.64.3        # 直接 ping VM-B
```

> **所以 host ↔ VM、VM ↔ VM 互访本身就是可用的**，不需要额外的端口转发。

---

## 什么时候需要真正的端口转发？

只有当你想让 **局域网中的其他物理设备**（如另一台电脑、手机）访问 VM 时，才需要端口转发。

### 方案一：macOS 内置 PF 防火墙转发（推荐）

在宿主机上用 `pfctl` 设置端口转发，把宿主机的某个端口映射到 VM：

```bash
# 将宿主机的 8080 端口转发到 VM 的 80 端口
echo "rdr pass on en0 proto tcp from any to any port 8080 -> 192.168.64.2 port 80" | sudo pfctl -ef -
```

取消转发：

```bash
sudo pfctl -d
```

### 方案二：SSH 隧道（最简单，无需 root）

```bash
# 在宿主机上执行，将本机 8080 转发到 VM 的 80
ssh -L 0.0.0.0:8080:localhost:80 user@192.168.64.2
```

这样局域网内任何设备访问 `宿主机IP:8080` 就等于访问 `VM:80`。

### 方案三：在 App 内集成端口转发功能

如果你想在 Apus 中提供 UI 化的端口转发管理，可以用 `NWListener` + `NWConnection` 实现一个用户态的 TCP 代理：

```swift
import Network

class PortForwarder {
    private var listener: NWListener?
    
    /// 将宿主机 localPort 转发到 vmIP:remotePort
    func start(localPort: UInt16, vmIP: String, remotePort: UInt16) throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: localPort)!)
        
        listener?.newConnectionHandler = { incomingConnection in
            // 建立到 VM 的连接
            let vmEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(vmIP),
                port: NWEndpoint.Port(rawValue: remotePort)!)
            let vmConnection = NWConnection(to: vmEndpoint, using: .tcp)
            
            // 双向转发数据
            self.relay(from: incomingConnection, to: vmConnection)
            self.relay(from: vmConnection, to: incomingConnection)
            
            incomingConnection.start(queue: .global())
            vmConnection.start(queue: .global())
        }
        
        listener?.start(queue: .global())
    }
    
    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in
                    self.relay(from: source, to: destination)
                })
            }
            if isComplete || error != nil {
                destination.cancel()
            }
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
    }
}
```

这个方案的好处是：

- **不需要 root 权限**
- **不需要特殊 entitlement**
- **可以做成 UI 界面**，让用户可视化地管理转发规则
- **兼容 App Sandbox / Mac App Store**（只需 `com.apple.security.network.server` entitlement）

### 在 Apus 中的集成思路

可以在 `VMInstance` 中增加一个端口转发规则列表：

```swift
struct PortForwardRule: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String           // 如 "SSH", "Web Server"
    var hostPort: UInt16       // 宿主机端口
    var guestPort: UInt16      // VM 端口
    var proto: String          // "tcp" 或 "udp"
    var enabled: Bool
}

struct VMInstance: Codable, Identifiable, Hashable {
    // ... existing ...
    var portForwardRules: [PortForwardRule] = []
}
```

然后在 VM 启动时自动根据规则启动 `PortForwarder`，VM 停止时清理。

---

## 总结


| 需求         | 方案                  | 是否已可用 |
| ---------- | ------------------- | ----- |
| 宿主机 → VM   | 直接用 192.168.64.x 访问 | ✅ 已可用 |
| VM → 宿主机   | 访问 192.168.64.1     | ✅ 已可用 |
| VM ↔ VM    | 互相用 192.168.64.x 访问 | ✅ 已可用 |
| 局域网设备 → VM | 需要端口转发              | 需实现   |


**对于你问的场景（主机和 VM 互访），现在就已经能用了**。只是你可能还不知道 VM 的 IP 地址——可以考虑在 Apus 的 UI 上显示 VM 的 IP 地址信息，方便用户使用。