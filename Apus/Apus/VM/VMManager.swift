//
//  VMManager.swift
//  Apus
//

import Foundation
import Virtualization

// MARK: - VM 状态

enum VMState: Equatable {
    case idle
    case downloading(progress: Double)
    case downloadPaused(progress: Double)
    case installing(progress: Double)
    case starting
    case running
    case pausing
    case paused
    case error(String)
}

// MARK: - 每个 VM 的运行时（支持多 VM 同时运行）

@Observable
class VMRuntime {
    let instanceID: UUID
    var state: VMState = .idle {
        didSet {
            // 当 VM 进入运行/暂停状态时启动计时器，离开时停止
            if isRunningOrPaused {
                if uptimeTimer == nil { startUptimeTimer() }
            } else {
                stopUptimeTimer()
            }
        }
    }
    var virtualMachine: VZVirtualMachine?
    var startedAt: Date?
    let cpuCount: Int
    let memoryGiB: Int

    @ObservationIgnored var delegate: VMDelegateHandler?
    @ObservationIgnored nonisolated(unsafe) var downloadObserver: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) var downloadTask: URLSessionDownloadTask?
    @ObservationIgnored var downloadResumeData: Data?
    @ObservationIgnored var downloadSourceURL: URL?
    @ObservationIgnored var downloadDestinationURL: URL?
    @ObservationIgnored var isPausingDownload = false
    @ObservationIgnored var installProgressTask: Task<Void, Never>?
    var macOSVersion: String?

    /// 每秒递增的计数器，用于驱动 uptimeString 的 UI 刷新
    private(set) var uptimeTick: UInt = 0
    @ObservationIgnored private var uptimeTimer: Timer?

    init(instanceID: UUID, cpuCount: Int, memoryGiB: Int) {
        self.instanceID = instanceID
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
    }

    deinit {
        uptimeTimer?.invalidate()
    }

    var isActive: Bool {
        switch state {
        case .idle: false
        default: true
        }
    }

    var isRunningOrPaused: Bool {
        switch state {
        case .running, .paused, .starting, .pausing: true
        default: false
        }
    }

    var statusLabel: String {
        switch state {
        case .idle: "空闲"
        case .downloading(let p): "下载中 \(Int(p * 100))%"
        case .downloadPaused(let p): "下载已暂停 \(Int(p * 100))%"
        case .installing(let p): "安装中 \(Int(p * 100))%"
        case .starting: "启动中"
        case .running: "运行中"
        case .pausing: "暂停中"
        case .paused: "已暂停"
        case .error: "错误"
        }
    }

    var stateIcon: String {
        switch state {
        case .idle: "desktopcomputer"
        case .downloading, .installing: "arrow.down.circle.fill"
        case .downloadPaused: "pause.circle.fill"
        case .starting: "play.circle"
        case .running: "play.circle.fill"
        case .pausing: "pause.circle"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var uptimeString: String? {
        // 读取 uptimeTick 以建立 @Observable 观察依赖，确保每秒触发 UI 刷新
        _ = uptimeTick
        guard let startedAt, isRunningOrPaused else { return nil }
        let total = Int(Date().timeIntervalSince(startedAt))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - 运行时间计时器

    func startUptimeTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.uptimeTick &+= 1
        }
    }

    func stopUptimeTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
    }
}

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
    @ObservationIgnored private var isDownloadingIPSW = false

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
    private func resolvedMACAddress(for instance: VMInstance) -> VZMACAddress {
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

    private func getOrCreateRuntime(for instance: VMInstance) -> VMRuntime {
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

    private func cleanupRuntime(for instanceID: UUID) {
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

    // MARK: - 下载 & 安装

    func downloadAndInstall(instance: VMInstance) {
        let runtime = getOrCreateRuntime(for: instance)
        guard !runtime.isActive else { return }

        Task {
            do {
                let ipswURL: URL

                if let cachedIPSW = VMConstants.findCachedIPSW() {
                    // 从缓存的 IPSW 安装，加载版本信息
                    ipswURL = cachedIPSW
                    await loadMacOSVersionInfo(from: ipswURL, into: runtime)
                } else {
                    guard !isDownloadingIPSW else {
                        runtime.state = .error("另一个 IPSW 下载正在进行中，请稍后再试")
                        return
                    }
                    isDownloadingIPSW = true
                    runtime.state = .downloading(progress: 0)

                    let restoreImage: VZMacOSRestoreImage =
                        try await withCheckedThrowingContinuation { continuation in
                            VZMacOSRestoreImage.fetchLatestSupported { result in
                                continuation.resume(with: result)
                            }
                        }

                    // 保存 macOS 版本信息和下载源地址
                    runtime.macOSVersion = Self.formatMacOSVersion(restoreImage)
                    runtime.downloadSourceURL = restoreImage.url

                    // 生成版本化文件名
                    let v = restoreImage.operatingSystemVersion
                    let destinationURL = VMConstants.ipswURL(
                        majorVersion: v.majorVersion, minorVersion: v.minorVersion,
                        patchVersion: v.patchVersion, buildVersion: restoreImage.buildVersion)
                    runtime.downloadDestinationURL = destinationURL

                    try await downloadIPSW(from: restoreImage.url, runtime: runtime, destinationURL: destinationURL)
                    isDownloadingIPSW = false
                    ipswURL = destinationURL

                    NotificationManager.send(
                        title: "IPSW 下载完成",
                        body: "\(runtime.macOSVersion ?? "macOS") 恢复镜像已下载完成",
                        category: .downloadComplete)
                }

                runtime.state = .installing(progress: 0)
                try await performInstallation(
                    instance: instance, runtime: runtime, ipswURL: ipswURL)

                NotificationManager.send(
                    title: "macOS 安装完成",
                    body: "虚拟机「\(instance.name)」已安装完成，可以启动使用",
                    category: .installComplete)

                cleanupRuntime(for: instance.id)
            } catch let urlError as URLError where urlError.code == .cancelled {
                // 下载被暂停或取消
                if runtime.isPausingDownload {
                    // 暂停：保持 runtime 和 isDownloadingIPSW，等待用户继续
                    runtime.isPausingDownload = false
                } else {
                    // 取消：释放资源
                    isDownloadingIPSW = false
                }
            } catch {
                isDownloadingIPSW = false
                runtime.state = .error(error.localizedDescription)
                NotificationManager.send(
                    title: "虚拟机操作失败",
                    body: "「\(instance.name)」: \(error.localizedDescription)",
                    category: .vmError)
            }
        }
    }

    /// 继续被暂停的下载
    func resumeDownload(instance: VMInstance) {
        guard let runtime = runtimes[instance.id],
              case .downloadPaused = runtime.state else { return }

        Task {
            do {
                if case .downloadPaused(let p) = runtime.state {
                    runtime.state = .downloading(progress: p)
                }

                let destinationURL = runtime.downloadDestinationURL ?? VMConstants.restoreImageURL
                try await downloadIPSW(
                    from: runtime.downloadSourceURL ?? URL(string: "about:blank")!,
                    runtime: runtime,
                    resumeData: runtime.downloadResumeData,
                    destinationURL: destinationURL)
                runtime.downloadResumeData = nil
                isDownloadingIPSW = false

                NotificationManager.send(
                    title: "IPSW 下载完成",
                    body: "\(runtime.macOSVersion ?? "macOS") 恢复镜像已下载完成",
                    category: .downloadComplete)

                let ipswURL = destinationURL
                runtime.state = .installing(progress: 0)
                try await performInstallation(
                    instance: instance, runtime: runtime, ipswURL: ipswURL)

                NotificationManager.send(
                    title: "macOS 安装完成",
                    body: "虚拟机「\(instance.name)」已安装完成，可以启动使用",
                    category: .installComplete)

                cleanupRuntime(for: instance.id)
            } catch let urlError as URLError where urlError.code == .cancelled {
                if runtime.isPausingDownload {
                    runtime.isPausingDownload = false
                } else {
                    isDownloadingIPSW = false
                }
            } catch {
                isDownloadingIPSW = false
                runtime.state = .error(error.localizedDescription)
                NotificationManager.send(
                    title: "虚拟机操作失败",
                    body: "「\(instance.name)」: \(error.localizedDescription)",
                    category: .vmError)
            }
        }
    }

    /// 暂停正在进行的下载
    func pauseDownload(instanceID: UUID) {
        guard let runtime = runtimes[instanceID],
              let task = runtime.downloadTask,
              case .downloading(let progress) = runtime.state else { return }

        runtime.isPausingDownload = true
        task.cancel(byProducingResumeData: { data in
            Task { @MainActor in
                runtime.downloadResumeData = data
                runtime.downloadTask = nil
                runtime.state = .downloadPaused(progress: progress)
            }
        })
    }

    /// 取消正在进行或已暂停的下载
    func cancelDownload(instanceID: UUID) {
        guard let runtime = runtimes[instanceID] else { return }
        runtime.isPausingDownload = false
        runtime.downloadTask?.cancel()
        runtime.downloadTask = nil
        runtime.downloadResumeData = nil
        isDownloadingIPSW = false
        cleanupRuntime(for: instanceID)
    }

    func installFromLocalIPSW(instance: VMInstance, ipswURL: URL) {
        let runtime = getOrCreateRuntime(for: instance)
        guard !runtime.isActive else { return }

        Task {
            do {
                runtime.state = .installing(progress: 0)
                try await performInstallation(
                    instance: instance, runtime: runtime, ipswURL: ipswURL)

                NotificationManager.send(
                    title: "macOS 安装完成",
                    body: "虚拟机「\(instance.name)」已安装完成，可以启动使用",
                    category: .installComplete)

                cleanupRuntime(for: instance.id)
            } catch {
                runtime.state = .error(error.localizedDescription)
                NotificationManager.send(
                    title: "安装失败",
                    body: "「\(instance.name)」: \(error.localizedDescription)",
                    category: .vmError)
            }
        }
    }

    // MARK: - 下载 IPSW

    private func downloadIPSW(from url: URL, runtime: VMRuntime, resumeData: Data? = nil, destinationURL: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in

            let completionHandler: (URL?, URLResponse?, (any Error)?) -> Void = { localURL, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let localURL else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destinationURL)
                    try FileManager.default.moveItem(
                        at: localURL, to: destinationURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            let task: URLSessionDownloadTask
            if let resumeData {
                task = URLSession.shared.downloadTask(
                    withResumeData: resumeData, completionHandler: completionHandler)
            } else {
                task = URLSession.shared.downloadTask(
                    with: url, completionHandler: completionHandler)
            }

            runtime.downloadTask = task

            runtime.downloadObserver = task.progress.observe(
                \.fractionCompleted, options: [.new]
            ) { [weak runtime] _, change in
                guard let progress = change.newValue else { return }
                Task { @MainActor [weak runtime] in
                    if case .downloading = runtime?.state {
                        runtime?.state = .downloading(progress: progress)
                    }
                }
            }

            task.resume()
        }

        runtime.downloadObserver = nil
        runtime.downloadTask = nil
    }

    // MARK: - macOS 版本信息

    /// 格式化 macOS 版本字符串
    static func formatMacOSVersion(_ restoreImage: VZMacOSRestoreImage) -> String {
        let v = restoreImage.operatingSystemVersion
        var version = "macOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 {
            version += ".\(v.patchVersion)"
        }
        version += " (\(restoreImage.buildVersion))"
        return version
    }

    /// 从 IPSW 文件加载 macOS 版本信息
    private func loadMacOSVersionInfo(from ipswURL: URL, into runtime: VMRuntime) async {
        do {
            let restoreImage: VZMacOSRestoreImage = try await withCheckedThrowingContinuation {
                continuation in
                VZMacOSRestoreImage.load(from: ipswURL) { result in
                    continuation.resume(with: result)
                }
            }
            runtime.macOSVersion = Self.formatMacOSVersion(restoreImage)
        } catch {
            // 无法获取版本信息，不影响流程
        }
    }

    // MARK: - 安装 macOS

    private func performInstallation(
        instance: VMInstance, runtime: VMRuntime, ipswURL: URL
    ) async throws {
        let restoreImage: VZMacOSRestoreImage = try await withCheckedThrowingContinuation {
            continuation in
            VZMacOSRestoreImage.load(from: ipswURL) { result in
                continuation.resume(with: result)
            }
        }

        // 更新 macOS 版本信息（安装阶段也展示）
        if runtime.macOSVersion == nil {
            runtime.macOSVersion = Self.formatMacOSVersion(restoreImage)
        }

        guard let macOSConfig = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw NSError(
                domain: "Apus", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "没有找到可用的 macOS 配置"])
        }

        guard macOSConfig.hardwareModel.isSupported else {
            throw NSError(
                domain: "Apus", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "当前硬件模型不被支持"])
        }

        try FileManager.default.createDirectory(
            at: instance.directoryURL, withIntermediateDirectories: true)

        let platform = VZMacPlatformConfiguration()
        let auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: instance.auxiliaryStorageURL,
            hardwareModel: macOSConfig.hardwareModel,
            options: [])
        platform.auxiliaryStorage = auxiliaryStorage
        platform.hardwareModel = macOSConfig.hardwareModel
        platform.machineIdentifier = VZMacMachineIdentifier()

        try platform.hardwareModel.dataRepresentation.write(to: instance.hardwareModelURL)
        try platform.machineIdentifier.dataRepresentation.write(to: instance.machineIdentifierURL)

        createDiskImage(at: instance.diskImageURL, sizeGiB: instance.diskSizeGiB)

        let vmConfig = VZVirtualMachineConfiguration()
        vmConfig.platform = platform
        vmConfig.cpuCount = VMConfiguration.clampCPUCount(instance.cpuCount)
        vmConfig.memorySize = VMConfiguration.clampMemorySize(giB: instance.memoryGiB)
        vmConfig.bootLoader = VMConfiguration.createBootLoader()
        vmConfig.graphicsDevices = [VMConfiguration.createGraphicsDeviceConfiguration()]
        vmConfig.networkDevices = [VMConfiguration.createNetworkDeviceConfiguration(
            macAddress: resolvedMACAddress(for: instance),
            networkMode: instance.networkMode,
            bridgedInterfaceID: instance.bridgedInterfaceID
        )]
        vmConfig.audioDevices = [VMConfiguration.createSoundDeviceConfiguration()]
        vmConfig.storageDevices = [
            try VMConfiguration.createBlockDeviceConfiguration(diskURL: instance.diskImageURL)
        ]
        vmConfig.pointingDevices = [VMConfiguration.createPointingDeviceConfiguration()]
        vmConfig.keyboards = [VMConfiguration.createKeyboardConfiguration()]

        NSLog("[Apus Network] 安装阶段 — VM 配置: CPU=\(vmConfig.cpuCount), 内存=\(vmConfig.memorySize / 1024 / 1024 / 1024)GB, 网络模式=\(instance.networkMode.rawValue), 网络设备数=\(vmConfig.networkDevices.count)")
        try vmConfig.validate()
        NSLog("[Apus Network] 安装阶段 — VM 配置验证通过")

        let vm = VZVirtualMachine(configuration: vmConfig)

        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)

        runtime.installProgressTask = Task { [weak runtime] in
            while !Task.isCancelled {
                await MainActor.run { [weak runtime] in
                    runtime?.state = .installing(
                        progress: installer.progress.fractionCompleted)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            installer.install { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }

        runtime.installProgressTask?.cancel()
        runtime.installProgressTask = nil
    }

    // MARK: - 磁盘镜像

    private func createDiskImage(at url: URL, sizeGiB: Int) {
        let diskFd = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard diskFd != -1 else { return }
        ftruncate(diskFd, Int64(sizeGiB) * 1024 * 1024 * 1024)
        close(diskFd)
    }

    // MARK: - 虚拟机生命周期

    /// 启动指定虚拟机（多 VM 可同时运行）
    func startInstance(_ instance: VMInstance, recoveryMode: Bool = false) {
        guard runtimes[instance.id] == nil else { return }
        guard instance.isInstalled else { return }

        let runtime = getOrCreateRuntime(for: instance)

        do {
            try buildVirtualMachine(for: instance, runtime: runtime)
            startVM(for: instance, runtime: runtime, recoveryMode: recoveryMode)
        } catch {
            runtime.state = .error("创建虚拟机失败: \(error.localizedDescription)")
        }
    }

    /// 以 Recovery 模式启动虚拟机
    func startInstanceInRecoveryMode(_ instance: VMInstance) {
        startInstance(instance, recoveryMode: true)
    }

    private func buildVirtualMachine(for instance: VMInstance, runtime: VMRuntime) throws {
        let vmConfig = VZVirtualMachineConfiguration()

        let platform = VZMacPlatformConfiguration()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(
            contentsOf: instance.auxiliaryStorageURL)

        guard let hwData = try? Data(contentsOf: instance.hardwareModelURL),
            let hardwareModel = VZMacHardwareModel(dataRepresentation: hwData)
        else {
            throw NSError(
                domain: "Apus", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法加载硬件模型"])
        }
        guard hardwareModel.isSupported else {
            throw NSError(
                domain: "Apus", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "硬件模型不被当前主机支持"])
        }
        platform.hardwareModel = hardwareModel

        guard let midData = try? Data(contentsOf: instance.machineIdentifierURL),
            let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: midData)
        else {
            throw NSError(
                domain: "Apus", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法加载机器标识"])
        }
        platform.machineIdentifier = machineIdentifier

        vmConfig.platform = platform
        vmConfig.cpuCount = VMConfiguration.clampCPUCount(instance.cpuCount)
        vmConfig.memorySize = VMConfiguration.clampMemorySize(giB: instance.memoryGiB)
        vmConfig.bootLoader = VMConfiguration.createBootLoader()
        vmConfig.graphicsDevices = [VMConfiguration.createGraphicsDeviceConfiguration()]
        vmConfig.networkDevices = [VMConfiguration.createNetworkDeviceConfiguration(
            macAddress: resolvedMACAddress(for: instance),
            networkMode: instance.networkMode,
            bridgedInterfaceID: instance.bridgedInterfaceID
        )]
        vmConfig.audioDevices = [VMConfiguration.createSoundDeviceConfiguration()]

        // 存储设备：系统盘 + 可选的 USB 镜像
        var storageDevices: [VZStorageDeviceConfiguration] = [
            try VMConfiguration.createBlockDeviceConfiguration(diskURL: instance.diskImageURL)
        ]
        if let usbPath = instance.usbImagePath,
           FileManager.default.fileExists(atPath: usbPath) {
            do {
                let usbDevice = try VMConfiguration.createUSBMassStorageDeviceConfiguration(
                    imageURL: URL(fileURLWithPath: usbPath))
                storageDevices.append(usbDevice)
                NSLog("[Apus USB] 已挂载 USB 镜像: \(usbPath)")
            } catch {
                NSLog("[Apus USB] ⚠️ 无法挂载 USB 镜像: \(error.localizedDescription)")
            }
        }
        vmConfig.storageDevices = storageDevices

        vmConfig.pointingDevices = [VMConfiguration.createPointingDeviceConfiguration()]
        vmConfig.keyboards = [VMConfiguration.createKeyboardConfiguration()]

        // VirtioFS 共享文件夹
        if let sharedPath = instance.sharedDirectoryPath {
            let sharedURL = URL(fileURLWithPath: sharedPath)
            if FileManager.default.fileExists(atPath: sharedPath) {
                let shareDevice = VMConfiguration.createDirectoryShareDeviceConfiguration(sharedURL: sharedURL)
                vmConfig.directorySharingDevices = [shareDevice]
                NSLog("[Apus VirtioFS] 已配置共享文件夹: \(sharedPath)")
            } else {
                NSLog("[Apus VirtioFS] ⚠️ 共享文件夹路径不存在: \(sharedPath)")
            }
        }

        NSLog("[Apus] 启动阶段 — VM 配置: CPU=\(vmConfig.cpuCount), 内存=\(vmConfig.memorySize / 1024 / 1024 / 1024)GB, 网络模式=\(instance.networkMode.rawValue), 网络设备数=\(vmConfig.networkDevices.count)")
        for (i, netDev) in vmConfig.networkDevices.enumerated() {
            if let virtio = netDev as? VZVirtioNetworkDeviceConfiguration {
                NSLog("[Apus Network] 启动阶段 — 网络设备[\(i)]: MAC=\(virtio.macAddress.string), 附件=\(type(of: virtio.attachment as Any))")
            }
        }
        try vmConfig.validate()
        NSLog("[Apus] 启动阶段 — VM 配置验证通过")
        try vmConfig.validateSaveRestoreSupport()

        let vm = VZVirtualMachine(configuration: vmConfig)
        let delegate = VMDelegateHandler(instanceID: instance.id, manager: self)
        vm.delegate = delegate

        runtime.virtualMachine = vm
        runtime.delegate = delegate
    }

    private func startVM(for instance: VMInstance, runtime: VMRuntime, recoveryMode: Bool = false) {
        guard let vm = runtime.virtualMachine else { return }
        runtime.state = .starting

        if !recoveryMode && FileManager.default.fileExists(atPath: instance.saveFileURL.path) {
            restoreVM(for: instance, runtime: runtime)
        } else if recoveryMode {
            // Recovery 模式启动
            let options = VZMacOSVirtualMachineStartOptions()
            options.startUpFromMacOSRecovery = true
            vm.start(options: options) { [weak runtime] error in
                if let error {
                    runtime?.state = .error("Recovery 模式启动失败: \(error.localizedDescription)")
                } else {
                    runtime?.state = .running
                    runtime?.startedAt = Date()
                }
            }
        } else {
            vm.start { [weak runtime] result in
                if case let .failure(error) = result {
                    runtime?.state = .error("启动失败: \(error.localizedDescription)")
                } else {
                    runtime?.state = .running
                    runtime?.startedAt = Date()
                }
            }
        }
    }

    func pauseVM(instanceID: UUID) {
        guard let runtime = runtimes[instanceID], let vm = runtime.virtualMachine else { return }
        runtime.state = .pausing
        vm.pause { [weak runtime] result in
            if case let .failure(error) = result {
                runtime?.state = .error("暂停失败: \(error.localizedDescription)")
            } else {
                runtime?.state = .paused
            }
        }
    }

    func resumeVM(instanceID: UUID) {
        guard let runtime = runtimes[instanceID], let vm = runtime.virtualMachine else { return }
        vm.resume { [weak runtime] result in
            if case let .failure(error) = result {
                runtime?.state = .error("恢复失败: \(error.localizedDescription)")
            } else {
                runtime?.state = .running
            }
        }
    }

    /// 停止虚拟机（强制停止，立即生效）
    func stopVM(instanceID: UUID) {
        forceStopVM(instanceID: instanceID)
    }

    /// 优雅关机（向虚拟机发送关机请求，虚拟机可能不响应）
    func shutdownVM(instanceID: UUID) {
        guard let runtime = runtimes[instanceID], let vm = runtime.virtualMachine else { return }
        do {
            try vm.requestStop()
        } catch {
            // requestStop 失败时回退到强制停止
            forceStopVM(instanceID: instanceID)
        }
    }

    func forceStopVM(instanceID: UUID, completion: (() -> Void)? = nil) {
        guard let runtime = runtimes[instanceID], let vm = runtime.virtualMachine, vm.canStop
        else {
            cleanupRuntime(for: instanceID)
            completion?()
            return
        }
        vm.stop { [weak self] error in
            if let error {
                NSLog("强制停止虚拟机失败: \(error.localizedDescription)")
            }
            self?.cleanupRuntime(for: instanceID)
            completion?()
        }
    }

    private func restoreVM(for instance: VMInstance, runtime: VMRuntime) {
        guard let vm = runtime.virtualMachine else { return }
        vm.restoreMachineStateFrom(url: instance.saveFileURL) { [weak runtime] error in
            try? FileManager.default.removeItem(at: instance.saveFileURL)
            if error == nil {
                vm.resume { [weak runtime] result in
                    if case let .failure(error) = result {
                        runtime?.state = .error("恢复失败: \(error.localizedDescription)")
                    } else {
                        runtime?.state = .running
                        runtime?.startedAt = Date()
                    }
                }
            } else {
                vm.start { [weak runtime] result in
                    if case let .failure(error) = result {
                        runtime?.state = .error("启动失败: \(error.localizedDescription)")
                    } else {
                        runtime?.state = .running
                        runtime?.startedAt = Date()
                    }
                }
            }
        }
    }

    // MARK: - 批量操作

    /// 强制停止所有运行中的虚拟机
    func forceStopAllVMs(completion: @escaping () -> Void) {
        let ids = Array(runtimes.keys)
        guard !ids.isEmpty else { completion(); return }

        let group = DispatchGroup()
        for id in ids {
            group.enter()
            forceStopVM(instanceID: id) { group.leave() }
        }
        group.notify(queue: .main) { completion() }
    }

    /// 保存指定 VM 的状态并暂停
    func saveAndPauseVM(instanceID: UUID, completion: @escaping () -> Void) {
        guard let runtime = runtimes[instanceID],
            let vm = runtime.virtualMachine,
            let instance = instances.first(where: { $0.id == instanceID }),
            vm.state == .running
        else {
            completion()
            return
        }
        vm.pause { result in
            if case .failure = result {
                completion()
                return
            }
            vm.saveMachineStateTo(url: instance.saveFileURL) { error in
                if let error {
                    NSLog("保存 VM \(instance.name) 状态失败: \(error.localizedDescription)")
                }
                completion()
            }
        }
    }

    /// 清除错误状态
    func dismissError(instanceID: UUID) {
        cleanupRuntime(for: instanceID)
    }

    // MARK: - Delegate 回调

    func handleVMError(instanceID: UUID, error: Error) {
        let name = instances.first { $0.id == instanceID }?.name ?? "虚拟机"
        runtimes[instanceID]?.state = .error("虚拟机异常停止: \(error.localizedDescription)")
        runtimes[instanceID]?.virtualMachine = nil
        runtimes[instanceID]?.delegate = nil

        NotificationManager.send(
            title: "虚拟机异常停止",
            body: "「\(name)」: \(error.localizedDescription)",
            category: .vmError)
    }

    func handleGuestStopped(instanceID: UUID) {
        let name = instances.first { $0.id == instanceID }?.name ?? "虚拟机"
        cleanupRuntime(for: instanceID)

        NotificationManager.send(
            title: "虚拟机已停止",
            body: "虚拟机「\(name)」已停止运行",
            category: .vmStopped)
    }
}

// MARK: - VZ 虚拟机代理

class VMDelegateHandler: NSObject, VZVirtualMachineDelegate {
    let instanceID: UUID
    weak var manager: VMManager?

    init(instanceID: UUID, manager: VMManager) {
        self.instanceID = instanceID
        self.manager = manager
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        manager?.handleVMError(instanceID: instanceID, error: error)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        manager?.handleGuestStopped(instanceID: instanceID)
    }
}
