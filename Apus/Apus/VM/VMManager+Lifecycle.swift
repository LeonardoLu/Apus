//
//  VMManager+Lifecycle.swift
//  Apus
//

import Foundation
import Virtualization

extension VMManager {

// MARK: - 虚拟机生命周期

/// 启动指定虚拟机（多 VM 可同时运行）
func startInstance(_ instance: VMInstance, recoveryMode: Bool = false) {
    guard runtimes[instance.id] == nil else {
        AppLog.log("[启动]「\(instance.name)」已有活动运行时，忽略重复启动")
        return
    }
    guard instance.isInstalled else {
        AppLog.log("[启动]「\(instance.name)」尚未安装，无法启动")
        return
    }

    let runtime = getOrCreateRuntime(for: instance)
    AppLog.log(
        "[启动]「\(instance.name)」(\(instance.id))\(recoveryMode ? " [恢复模式]" : "")")

    do {
        try buildVirtualMachine(for: instance, runtime: runtime)
        startVM(for: instance, runtime: runtime, recoveryMode: recoveryMode)
    } catch {
        AppLog.log("[启动]「\(instance.name)」构建失败: \(error.localizedDescription)")
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
            AppLog.log("[USB] 已挂载镜像: \(usbPath)")
        } catch {
            AppLog.log("[USB] 无法挂载镜像: \(error.localizedDescription) — \(usbPath)")
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
            AppLog.log("[VirtioFS] 已配置共享文件夹: \(sharedPath)")
        } else {
            AppLog.log("[VirtioFS] 共享文件夹路径不存在: \(sharedPath)")
        }
    }

    AppLog.log(
        "[启动/配置] CPU=\(vmConfig.cpuCount), 内存=\(vmConfig.memorySize / 1024 / 1024 / 1024)GB, 网络=\(instance.networkMode.rawValue), 网卡数=\(vmConfig.networkDevices.count)")
    for (i, netDev) in vmConfig.networkDevices.enumerated() {
        if let virtio = netDev as? VZVirtioNetworkDeviceConfiguration {
            AppLog.log(
                "[启动/网络] 设备[\(i)] MAC=\(virtio.macAddress.string), 附件=\(type(of: virtio.attachment as Any))")
        }
    }
    try vmConfig.validate()
    AppLog.log("[启动/配置] 校验通过")
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
                AppLog.log("[启动] Recovery 模式失败（\(instance.name)）: \(error.localizedDescription)")
                runtime?.state = .error("Recovery 模式启动失败: \(error.localizedDescription)")
            } else {
                AppLog.log("[启动]「\(instance.name)」已进入 Recovery 运行状态")
                runtime?.state = .running
                runtime?.startedAt = Date()
            }
        }
    } else {
        vm.start { [weak runtime] result in
            if case let .failure(error) = result {
                AppLog.log("[启动]「\(instance.name)」冷启动失败: \(error.localizedDescription)")
                runtime?.state = .error("启动失败: \(error.localizedDescription)")
            } else {
                AppLog.log("[启动]「\(instance.name)」已运行")
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
            let name = self.instances.first { $0.id == instanceID }?.name ?? "\(instanceID)"
            AppLog.log("[暂停]「\(name)」失败: \(error.localizedDescription)")
            runtime?.state = .error("暂停失败: \(error.localizedDescription)")
        } else {
            let name = self.instances.first { $0.id == instanceID }?.name ?? "\(instanceID)"
            AppLog.log("[暂停]「\(name)」已暂停")
            runtime?.state = .paused
        }
    }
}

func resumeVM(instanceID: UUID) {
    guard let runtime = runtimes[instanceID], let vm = runtime.virtualMachine else { return }
    vm.resume { [weak runtime] result in
        if case let .failure(error) = result {
            let name = self.instances.first { $0.id == instanceID }?.name ?? "\(instanceID)"
            AppLog.log("[恢复]「\(name)」失败: \(error.localizedDescription)")
            runtime?.state = .error("恢复失败: \(error.localizedDescription)")
        } else {
            let name = self.instances.first { $0.id == instanceID }?.name ?? "\(instanceID)"
            AppLog.log("[恢复]「\(name)」已继续运行")
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
    let name = instances.first { $0.id == instanceID }?.name ?? "\(instanceID)"
    do {
        try vm.requestStop()
        AppLog.log("[关机] 已向「\(name)」发送优雅关机请求")
    } catch {
        AppLog.log("[关机]「\(name)」requestStop 失败，改为强制停止: \(error.localizedDescription)")
        forceStopVM(instanceID: instanceID)
    }
}

func forceStopVM(instanceID: UUID, completion: (() -> Void)? = nil) {
    guard let runtime = runtimes[instanceID], let vm = runtime.virtualMachine, vm.canStop
    else {
        let label =
            instances.first { $0.id == instanceID }.map { "「\($0.name)」" } ?? "id=\(instanceID)"
        AppLog.log("[停止] \(label) 未执行 VZ stop（无运行时或不可 stop），已清理状态")
        cleanupRuntime(for: instanceID)
        completion?()
        return
    }
    let name = instances.first { $0.id == instanceID }?.name ?? "\(instanceID)"
    vm.stop { [weak self] error in
        if let error {
            AppLog.log("[停止]「\(name)」stop 回调错误: \(error.localizedDescription)")
        } else {
            AppLog.log("[停止]「\(name)」已强制停止")
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
                    AppLog.log(
                        "[休眠恢复]「\(instance.name)」从休眠镜像恢复后 resume 失败: \(error.localizedDescription)")
                    runtime?.state = .error("恢复失败: \(error.localizedDescription)")
                } else {
                    AppLog.log("[休眠恢复]「\(instance.name)」已从休眠恢复运行")
                    runtime?.state = .running
                    runtime?.startedAt = Date()
                }
            }
        } else {
            let reason = error.map { $0.localizedDescription } ?? "未知错误"
            AppLog.log("[休眠恢复]「\(instance.name)」恢复休眠状态失败，尝试冷启动: \(reason)")
            vm.start { [weak runtime] result in
                if case let .failure(error) = result {
                    AppLog.log("[休眠恢复]「\(instance.name)」冷启动失败: \(error.localizedDescription)")
                    runtime?.state = .error("启动失败: \(error.localizedDescription)")
                } else {
                    AppLog.log("[休眠恢复]「\(instance.name)」冷启动成功")
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

    AppLog.log("[停止] 批量强制停止 \(ids.count) 台活动虚拟机")
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
                AppLog.log("[休眠] 保存「\(instance.name)」状态失败: \(error.localizedDescription)")
            } else {
                AppLog.log("[休眠]「\(instance.name)」状态已写入 \(instance.saveFileURL.lastPathComponent)")
            }
            completion()
        }
    }
}

/// 清除错误状态
func dismissError(instanceID: UUID) {
    let name = instances.first { $0.id == instanceID }?.name ?? "\(instanceID)"
    AppLog.log("[界面] 用户已关闭「\(name)」的错误状态")
    cleanupRuntime(for: instanceID)
}

// MARK: - Delegate 回调

func handleVMError(instanceID: UUID, error: Error) {
    let name = instances.first { $0.id == instanceID }?.name ?? "虚拟机"
    AppLog.log("[虚拟机错误]「\(name)」(\(instanceID)): \(error.localizedDescription)")
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
    AppLog.log("[虚拟机]「\(name)」(\(instanceID)) 客户机已正常停止")
    cleanupRuntime(for: instanceID)

    NotificationManager.send(
        title: "虚拟机已停止",
        body: "虚拟机「\(name)」已停止运行",
        category: .vmStopped)
}
}
