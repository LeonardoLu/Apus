//
//  VMManager+InstallDownload.swift
//  Apus
//

import Foundation
import Virtualization

extension VMManager {

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
}
