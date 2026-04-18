//
//  VMConfiguration.swift
//  Apus
//

import Foundation
import Virtualization

enum VMConfiguration {

    // MARK: - 默认值

    static var defaultCPUCount: Int {
        let total = ProcessInfo.processInfo.processorCount
        return max(1, total - 1)
    }

    static let defaultMemoryGiB = 4
    static let defaultDiskSizeGiB = 128

    // MARK: - 约束值到合法范围

    static func clampCPUCount(_ count: Int) -> Int {
        var c = count
        c = max(c, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        c = min(c, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        return c
    }

    static func clampMemorySize(giB: Int) -> UInt64 {
        var size = UInt64(giB) * 1024 * 1024 * 1024
        size = max(size, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        size = min(size, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        return size
    }

    // MARK: - 设备配置

    static func createBootLoader() -> VZMacOSBootLoader {
        VZMacOSBootLoader()
    }

    static func createBlockDeviceConfiguration(diskURL: URL) throws
        -> VZVirtioBlockDeviceConfiguration
    {
        let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }

    static func createGraphicsDeviceConfiguration() -> VZMacGraphicsDeviceConfiguration {
        let config = VZMacGraphicsDeviceConfiguration()
        config.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)
        ]
        return config
    }

    static func createNetworkDeviceConfiguration(
        macAddress: VZMACAddress? = nil,
        networkMode: VMNetworkMode = .nat,
        bridgedInterfaceID: String? = nil
    ) -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        let resolvedMAC = macAddress ?? VZMACAddress.randomLocallyAdministered()
        config.macAddress = resolvedMAC

        switch networkMode {
        case .nat:
            config.attachment = VZNATNetworkDeviceAttachment()
            NSLog("[Apus Network] 网络设备已配置 — MAC: \(resolvedMAC.string), 模式: NAT")

        case .bridged:
            if let attachment = Self.createBridgedAttachment(interfaceID: bridgedInterfaceID) {
                config.attachment = attachment
                NSLog("[Apus Network] 网络设备已配置 — MAC: \(resolvedMAC.string), 模式: 桥接, 接口: \(bridgedInterfaceID ?? "自动")")
            } else {
                // 找不到桥接接口时回退到 NAT
                config.attachment = VZNATNetworkDeviceAttachment()
                NSLog("[Apus Network] ⚠️ 未找到桥接接口，已回退至 NAT 模式 — MAC: \(resolvedMAC.string)")
            }
        }

        return config
    }

    /// 创建桥接网络附件
    private static func createBridgedAttachment(interfaceID: String?) -> VZBridgedNetworkDeviceAttachment? {
        let interfaces = VZBridgedNetworkInterface.networkInterfaces
        let target: VZBridgedNetworkInterface?

        if let id = interfaceID {
            target = interfaces.first { $0.identifier == id }
        } else {
            // 自动选择第一个可用的非回环接口
            target = interfaces.first
        }

        guard let iface = target else { return nil }
        return VZBridgedNetworkDeviceAttachment(interface: iface)
    }

    /// 获取所有可用的桥接网络接口
    static var availableBridgedInterfaces: [(id: String, name: String)] {
        VZBridgedNetworkInterface.networkInterfaces.map { iface in
            (id: iface.identifier, name: "\(iface.localizedDisplayName ?? iface.identifier) (\(iface.identifier))")
        }
    }

    /// 检测桥接网络功能是否可用（需要 com.apple.vm.networking 权限）
    /// 通过尝试创建一个 bridged attachment 来检测
    static var isBridgedNetworkingAvailable: Bool {
        guard let iface = VZBridgedNetworkInterface.networkInterfaces.first else { return false }
        // 如果可以访问到接口列表且不为空，则认为基础条件满足
        // 实际权限检查会在 VM 启动时由框架进行
        let _ = VZBridgedNetworkDeviceAttachment(interface: iface)
        return true
    }

    // MARK: - VirtioFS 共享文件夹

    /// 创建 VirtioFS 文件共享设备配置
    /// - Parameter sharedURL: 宿主机上要共享的目录路径
    /// - Returns: 配置好的 VirtioFS 设备，tag 为 "shared"
    /// - Note: VM 内通过 `mount -t virtiofs shared /mount/point` 或 Finder 自动挂载
    static func createDirectoryShareDeviceConfiguration(sharedURL: URL) -> VZVirtioFileSystemDeviceConfiguration {
        let sharedDir = VZSharedDirectory(url: sharedURL, readOnly: false)
        let singleShare = VZSingleDirectoryShare(directory: sharedDir)
        let config = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        config.share = singleShare
        return config
    }

    // MARK: - USB 大容量存储设备

    /// 创建 USB 大容量存储设备配置（挂载 ISO/DMG 镜像）
    /// - Parameter imageURL: 磁盘镜像文件路径
    /// - Returns: USB 存储设备配置
    static func createUSBMassStorageDeviceConfiguration(imageURL: URL) throws -> VZUSBMassStorageDeviceConfiguration {
        let attachment = try VZDiskImageStorageDeviceAttachment(url: imageURL, readOnly: true)
        return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
    }

    // MARK: - 音频

    static func createSoundDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let config = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        config.streams = [inputStream, outputStream]
        return config
    }

    static func createPointingDeviceConfiguration() -> VZPointingDeviceConfiguration {
        VZMacTrackpadConfiguration()
    }

    static func createKeyboardConfiguration() -> VZKeyboardConfiguration {
        VZMacKeyboardConfiguration()
    }
}
