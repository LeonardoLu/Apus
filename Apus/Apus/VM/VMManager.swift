//
//  VMManager.swift
//  Apus
//

import Foundation
import Virtualization

// MARK: - VM 管理器（支持多 VM 同时运行）

@Observable
class VMManager {
    /// 所有虚拟机实例
    var instances: [VMInstance] = []

    /// 当前侧边栏选中的 VM ID
    var selectedID: UUID? {
        didSet {
            if let id = selectedID {
                UserDefaults.standard.set(id.uuidString, forKey: "lastSelectedVMID")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastSelectedVMID")
            }
        }
    }

    /// 每个活跃 VM 的运行时（下载/安装/运行 都会创建）
    var runtimes: [UUID: VMRuntime] = [:]

    /// 在独立窗口中显示的 VM ID 集合
    var detachedVMIDs: Set<UUID> = []

    /// IPSW 下载互斥标记
    @ObservationIgnored var isDownloadingIPSW = false

    // MARK: - 系统资源信息

    let hostCPUCount = ProcessInfo.processInfo.processorCount
    let hostMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024 / 1024)

    // MARK: - 计算属性

    var selectedInstance: VMInstance? {
        instances.first { $0.id == selectedID }
    }

    func instanceFor(id: UUID) -> VMInstance? {
        instances.first { $0.id == id }
    }

    var hasActiveVMs: Bool {
        runtimes.values.contains { $0.isActive }
    }

    var runningCount: Int {
        runtimes.values.filter(\.isRunningOrPaused).count
    }

    var totalAllocatedCPUs: Int {
        runtimes.values.filter(\.isRunningOrPaused).reduce(0) { $0 + $1.cpuCount }
    }

    var totalAllocatedMemoryGiB: Int {
        runtimes.values.filter(\.isRunningOrPaused).reduce(0) { $0 + $1.memoryGiB }
    }

    var menuBarIcon: String {
        let running = runtimes.values.contains { $0.state == .running }
        return running ? "play.circle.fill" : "desktopcomputer"
    }

    // MARK: - 初始化

    init() {
        VMConstants.ensureDirectoriesExist()
        AppLog.prepare()
        instances = VMInstance.loadAll()
        // 恢复上次选中的虚拟机
        if let savedIDString = UserDefaults.standard.string(forKey: "lastSelectedVMID"),
           let savedID = UUID(uuidString: savedIDString),
           instances.contains(where: { $0.id == savedID }) {
            selectedID = savedID
        }
    }

    // MARK: - CRUD 操作

    @discardableResult
    func createInstance(
        name: String, cpuCount: Int, memoryGiB: Int, diskSizeGiB: Int,
        networkMode: VMNetworkMode = .nat, bridgedInterfaceID: String? = nil
    ) -> VMInstance {
        var instance = VMInstance(
            name: name, cpuCount: cpuCount,
            memoryGiB: memoryGiB, diskSizeGiB: diskSizeGiB,
            networkMode: networkMode, bridgedInterfaceID: bridgedInterfaceID)
        // 在创建时生成并持久化 MAC 地址，确保安装和每次启动使用同一地址
        instance.macAddress = VZMACAddress.randomLocallyAdministered().string
        let fm = FileManager.default
        try? fm.createDirectory(at: instance.directoryURL, withIntermediateDirectories: true)
        try? instance.save()
        instances.append(instance)
        selectedID = instance.id
        return instance
    }

    func deleteInstance(_ instance: VMInstance) {
        if runtimes[instance.id] != nil {
            forceStopVM(instanceID: instance.id)
        }
        try? FileManager.default.removeItem(at: instance.directoryURL)
        instances.removeAll { $0.id == instance.id }
        if selectedID == instance.id {
            selectedID = instances.first?.id
        }
    }

    func renameInstance(_ instance: VMInstance, to newName: String) {
        guard let idx = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        instances[idx].name = newName
        try? instances[idx].save()
    }

    func updateNetworkMode(_ instance: VMInstance, mode: VMNetworkMode, bridgedInterfaceID: String? = nil) {
        guard let idx = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        instances[idx].networkMode = mode
        instances[idx].bridgedInterfaceID = bridgedInterfaceID
        try? instances[idx].save()
    }

    /// 重置虚拟机：停止运行、删除安装数据，保留配置以便重新安装
    func resetInstance(_ instance: VMInstance) {
        // 先停止运行中的 VM
        if runtimes[instance.id] != nil {
            forceStopVM(instanceID: instance.id)
        }

        let fm = FileManager.default
        // 删除安装产物（保留 config.json 和目录）
        let filesToDelete = [
            instance.auxiliaryStorageURL,
            instance.diskImageURL,
            instance.hardwareModelURL,
            instance.machineIdentifierURL,
            instance.saveFileURL,
        ]
        for fileURL in filesToDelete {
            try? fm.removeItem(at: fileURL)
        }
    }

    /// 删除所有虚拟机
    func deleteAllInstances(completion: (() -> Void)? = nil) {
        // 先停止所有运行中的 VM
        let activeIDs = Array(runtimes.keys)
        guard !activeIDs.isEmpty else {
            performDeleteAll()
            completion?()
            return
        }

        let group = DispatchGroup()
        for id in activeIDs {
            group.enter()
            forceStopVM(instanceID: id) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            self?.performDeleteAll()
            completion?()
        }
    }

    private func performDeleteAll() {
        let fm = FileManager.default
        for instance in instances {
            try? fm.removeItem(at: instance.directoryURL)
        }
        instances.removeAll()
        selectedID = nil
    }

    // MARK: - 编辑虚拟机配置

    /// 更新已创建 VM 的硬件配置（VM 必须处于停止状态）
    func updateInstanceConfig(
        _ instance: VMInstance,
        name: String? = nil,
        cpuCount: Int? = nil,
        memoryGiB: Int? = nil,
        networkMode: VMNetworkMode? = nil,
        bridgedInterfaceID: String?? = nil,
        sharedDirectoryPath: String?? = nil,
        usbImagePath: String?? = nil
    ) {
        guard let idx = instances.firstIndex(where: { $0.id == instance.id }) else { return }
        if let name { instances[idx].name = name }
        if let cpuCount { instances[idx].cpuCount = VMConfiguration.clampCPUCount(cpuCount) }
        if let memoryGiB {
            let clamped = VMConfiguration.clampMemorySize(giB: memoryGiB)
            instances[idx].memoryGiB = Int(clamped / 1024 / 1024 / 1024)
        }
        if let networkMode { instances[idx].networkMode = networkMode }
        if let bridgedInterfaceID { instances[idx].bridgedInterfaceID = bridgedInterfaceID }
        if let sharedDirectoryPath { instances[idx].sharedDirectoryPath = sharedDirectoryPath }
        if let usbImagePath { instances[idx].usbImagePath = usbImagePath }
        try? instances[idx].save()
    }

    // MARK: - 磁盘扩容

    /// 扩容虚拟机磁盘（仅支持增大，VM 必须处于停止状态）
    /// - Returns: 成功返回 nil，失败返回错误信息
    @discardableResult
    func resizeDisk(for instance: VMInstance, newSizeGiB: Int) -> String? {
        guard newSizeGiB > instance.diskSizeGiB else {
            return "新磁盘大小必须大于当前大小 (\(instance.diskSizeGiB) GB)"
        }
        guard runtimes[instance.id] == nil else {
            return "虚拟机正在运行中，请先停止虚拟机再扩容磁盘"
        }
        guard instance.isInstalled else {
            return "虚拟机尚未安装，无法扩容磁盘"
        }

        let diskURL = instance.diskImageURL
        let fd = open(diskURL.path, O_RDWR)
        guard fd != -1 else {
            return "无法打开磁盘镜像文件"
        }
        let result = ftruncate(fd, Int64(newSizeGiB) * 1024 * 1024 * 1024)
        close(fd)

        guard result == 0 else {
            return "磁盘扩容失败: errno=\(errno)"
        }

        // 更新实例配置
        if let idx = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[idx].diskSizeGiB = newSizeGiB
            try? instances[idx].save()
        }

        NSLog("[Apus Disk] 磁盘已扩容: \(instance.diskSizeGiB) GB → \(newSizeGiB) GB")
        return nil
    }

    // MARK: - VM 克隆

    /// 克隆虚拟机（包括磁盘镜像、硬件模型等，生成新的机器标识和 MAC 地址）
    /// APFS 文件系统上使用 Copy-on-Write，克隆几乎是瞬间完成的
    @discardableResult
    func cloneInstance(_ instance: VMInstance) -> VMInstance? {
        guard instance.isInstalled else { return nil }

        var clone = VMInstance(
            name: "\(instance.name) (副本)",
            cpuCount: instance.cpuCount,
            memoryGiB: instance.memoryGiB,
            diskSizeGiB: instance.diskSizeGiB,
            networkMode: instance.networkMode,
            bridgedInterfaceID: instance.bridgedInterfaceID,
            sharedDirectoryPath: instance.sharedDirectoryPath
        )
        clone.macAddress = VZMACAddress.randomLocallyAdministered().string

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: clone.directoryURL, withIntermediateDirectories: true)

            // 复制数据文件（APFS CoW 使得大文件复制接近零开销）
            let filesToCopy = ["AuxiliaryStorage", "Disk.img", "HardwareModel"]
            for file in filesToCopy {
                let src = instance.directoryURL.appendingPathComponent(file)
                let dst = clone.directoryURL.appendingPathComponent(file)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: dst)
                }
            }

            // 为克隆的 VM 生成新的机器标识符（避免与原 VM 冲突）
            let newMachineID = VZMacMachineIdentifier()
            try newMachineID.dataRepresentation.write(to: clone.machineIdentifierURL)

            try clone.save()
            instances.append(clone)
            selectedID = clone.id

            NSLog("[Apus Clone] 已克隆虚拟机: \(instance.name) → \(clone.name)")
            return clone
        } catch {
            NSLog("[Apus Clone] 克隆失败: \(error.localizedDescription)")
            try? fm.removeItem(at: clone.directoryURL)
            return nil
        }
    }

    // MARK: - VM 导出

    /// 导出虚拟机到指定目录
    func exportInstance(_ instance: VMInstance, to destinationURL: URL) throws {
        let fm = FileManager.default
        let exportDir = destinationURL.appendingPathComponent("\(instance.name)_\(instance.id.uuidString)", isDirectory: true)

        if fm.fileExists(atPath: exportDir.path) {
            try fm.removeItem(at: exportDir)
        }

        try fm.copyItem(at: instance.directoryURL, to: exportDir)
        NSLog("[Apus Export] 已导出虚拟机: \(instance.name) → \(exportDir.path)")
    }

    // MARK: - VM 导入

    /// 从指定目录导入虚拟机
    @discardableResult
    func importInstance(from sourceDirectory: URL) -> VMInstance? {
        // 尝试加载源目录的配置
        guard let sourceInstance = VMInstance.load(from: sourceDirectory) else {
            NSLog("[Apus Import] 无法从 \(sourceDirectory.path) 加载 VM 配置")
            return nil
        }

        var imported = VMInstance(
            name: sourceInstance.name,
            cpuCount: sourceInstance.cpuCount,
            memoryGiB: sourceInstance.memoryGiB,
            diskSizeGiB: sourceInstance.diskSizeGiB,
            networkMode: sourceInstance.networkMode,
            bridgedInterfaceID: sourceInstance.bridgedInterfaceID,
            sharedDirectoryPath: sourceInstance.sharedDirectoryPath
        )
        imported.macAddress = VZMACAddress.randomLocallyAdministered().string

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: imported.directoryURL, withIntermediateDirectories: true)

            // 复制所有数据文件
            let filesToCopy = ["AuxiliaryStorage", "Disk.img", "HardwareModel", "MachineIdentifier"]
            for file in filesToCopy {
                let src = sourceDirectory.appendingPathComponent(file)
                let dst = imported.directoryURL.appendingPathComponent(file)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: dst)
                }
            }

            try imported.save()
            instances.append(imported)
            selectedID = imported.id

            NSLog("[Apus Import] 已导入虚拟机: \(imported.name)")
            return imported
        } catch {
            NSLog("[Apus Import] 导入失败: \(error.localizedDescription)")
            try? fm.removeItem(at: imported.directoryURL)
            return nil
        }
    }

    // MARK: - MAC 地址管理

    /// 获取实例的 VZMACAddress，如果尚未持久化则生成一个并保存
    func resolvedMACAddress(for instance: VMInstance) -> VZMACAddress {
        if let saved = instance.macAddress, let mac = VZMACAddress(string: saved) {
            return mac
        }
        // 兼容旧版本创建的 VM（没有保存 MAC 地址）：生成并回写
        let mac = VZMACAddress.randomLocallyAdministered()
        if let idx = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[idx].macAddress = mac.string
            try? instances[idx].save()
        }
        return mac
    }

    // MARK: - 运行时管理

    func getOrCreateRuntime(for instance: VMInstance) -> VMRuntime {
        if let existing = runtimes[instance.id] {
            return existing
        }
        let runtime = VMRuntime(
            instanceID: instance.id,
            cpuCount: instance.cpuCount,
            memoryGiB: instance.memoryGiB)
        runtimes[instance.id] = runtime
        return runtime
    }

    func cleanupRuntime(for instanceID: UUID) {
        runtimes[instanceID]?.stopUptimeTimer()
        runtimes[instanceID]?.virtualMachine = nil
        runtimes[instanceID]?.delegate = nil
        runtimes[instanceID]?.downloadObserver = nil
        runtimes[instanceID]?.downloadTask = nil
        runtimes[instanceID]?.downloadResumeData = nil
        runtimes[instanceID]?.downloadSourceURL = nil
        runtimes[instanceID]?.downloadDestinationURL = nil
        runtimes[instanceID]?.isPausingDownload = false
        runtimes[instanceID]?.installProgressTask?.cancel()
        runtimes[instanceID]?.installProgressTask = nil
        runtimes[instanceID]?.startedAt = nil
        runtimes[instanceID]?.macOSVersion = nil
        detachedVMIDs.remove(instanceID)
        runtimes.removeValue(forKey: instanceID)
    }
}
