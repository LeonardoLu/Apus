//
//  VMInstance.swift
//  Apus
//

import Foundation

// MARK: - 网络模式

/// 虚拟机网络连接模式
enum VMNetworkMode: String, Codable, CaseIterable, Identifiable {
    /// NAT 模式 — VM 通过主机 NAT 网关上网（默认，无需额外权限）
    case nat
    /// 桥接模式 — VM 直接连接到物理网卡（需要 com.apple.vm.networking 权限，VPN 下推荐）
    case bridged

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nat: "NAT（网络地址转换）"
        case .bridged: "桥接（直连物理网卡）"
        }
    }

    var description: String {
        switch self {
        case .nat: "通过主机 NAT 上网，简单易用。主机开启 VPN 时可能导致 VM 无法联网。"
        case .bridged: "直接桥接到物理网络接口，VM 获得独立 IP。即使主机开启 VPN 也不受影响。"
        }
    }
}

/// 单个虚拟机实例的配置与元数据
struct VMInstance: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var cpuCount: Int
    var memoryGiB: Int
    var diskSizeGiB: Int
    let createdAt: Date
    /// 持久化的 MAC 地址，确保每次启动网络接口一致
    var macAddress: String?
    /// 网络连接模式（NAT 或桥接）
    var networkMode: VMNetworkMode
    /// 桥接模式下使用的网络接口标识符（如 "en0"）
    var bridgedInterfaceID: String?
    /// VirtioFS 共享文件夹路径（宿主机路径）
    var sharedDirectoryPath: String?
    /// USB 大容量存储设备镜像路径（ISO/DMG 等）
    var usbImagePath: String?

    init(
        name: String,
        cpuCount: Int = VMConfiguration.defaultCPUCount,
        memoryGiB: Int = 4,
        diskSizeGiB: Int = 128,
        networkMode: VMNetworkMode = .nat,
        bridgedInterfaceID: String? = nil,
        sharedDirectoryPath: String? = nil,
        usbImagePath: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
        self.diskSizeGiB = diskSizeGiB
        self.createdAt = Date()
        self.macAddress = nil  // 由 VMManager 在创建时通过 VZMACAddress 生成
        self.networkMode = networkMode
        self.bridgedInterfaceID = bridgedInterfaceID
        self.sharedDirectoryPath = sharedDirectoryPath
        self.usbImagePath = usbImagePath
    }

    // MARK: - 自定义 Codable（兼容旧版本 config.json 中无新增字段）

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        memoryGiB = try container.decode(Int.self, forKey: .memoryGiB)
        diskSizeGiB = try container.decode(Int.self, forKey: .diskSizeGiB)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        networkMode = try container.decodeIfPresent(VMNetworkMode.self, forKey: .networkMode) ?? .nat
        bridgedInterfaceID = try container.decodeIfPresent(String.self, forKey: .bridgedInterfaceID)
        sharedDirectoryPath = try container.decodeIfPresent(String.self, forKey: .sharedDirectoryPath)
        usbImagePath = try container.decodeIfPresent(String.self, forKey: .usbImagePath)
    }
}

// MARK: - 文件路径（每个 VM 独立目录）

extension VMInstance {
    /// ~/…/VMs/<uuid>/
    var directoryURL: URL {
        VMConstants.vmsDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var auxiliaryStorageURL: URL { directoryURL.appendingPathComponent("AuxiliaryStorage") }
    var diskImageURL: URL { directoryURL.appendingPathComponent("Disk.img") }
    var hardwareModelURL: URL { directoryURL.appendingPathComponent("HardwareModel") }
    var machineIdentifierURL: URL { directoryURL.appendingPathComponent("MachineIdentifier") }
    var saveFileURL: URL { directoryURL.appendingPathComponent("SaveFile.vzvmsave") }
    var configFileURL: URL { directoryURL.appendingPathComponent("config.json") }

    /// 检查该 VM 是否已完成安装
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: hardwareModelURL.path)
    }
}

// MARK: - 持久化

extension VMInstance {
    /// 将配置写入 config.json
    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: configFileURL, options: .atomic)
    }

    /// 从目录中加载 VM 配置
    static func load(from directory: URL) -> VMInstance? {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VMInstance.self, from: data)
    }

    /// 扫描 VMs 目录，加载所有虚拟机实例
    static func loadAll() -> [VMInstance] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: VMConstants.vmsDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        let configName = "config.json"
        return entries.compactMap { url -> VMInstance? in
            let isDir =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }
            let configURL = url.appendingPathComponent(configName)
            guard fm.fileExists(atPath: configURL.path) else { return nil }
            guard let instance = VMInstance.load(from: url) else {
                AppLog.log("[配置] 无法解析虚拟机配置: \(configURL.path)")
                return nil
            }
            return instance
        }
        .sorted { $0.createdAt < $1.createdAt }
    }
}
