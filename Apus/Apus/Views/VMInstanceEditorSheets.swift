//
//  VMInstanceEditorSheets.swift
//  Apus
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Virtualization

// MARK: - 网络设置弹窗

struct NetworkSettingsSheet: View {
    var vmManager: VMManager
    let instance: VMInstance
    @Environment(\.dismiss) private var dismiss

    @State private var networkMode: VMNetworkMode
    @State private var bridgedInterfaceID: String?

    init(vmManager: VMManager, instance: VMInstance) {
        self.vmManager = vmManager
        self.instance = instance
        self._networkMode = State(initialValue: instance.networkMode)
        self._bridgedInterfaceID = State(initialValue: instance.bridgedInterfaceID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .font(.title)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("网络设置")
                                .font(.headline)
                            Text("为「\(instance.name)」配置网络连接方式")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("网络模式") {
                    Picker("模式", selection: $networkMode) {
                        ForEach(VMNetworkMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(networkMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if networkMode == .bridged {
                    Section("桥接接口") {
                        let interfaces = VMConfiguration.availableBridgedInterfaces
                        if interfaces.isEmpty {
                            Label("未检测到可用的网络接口", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else {
                            Picker("网络接口", selection: $bridgedInterfaceID) {
                                Text("自动选择").tag(nil as String?)
                                ForEach(interfaces, id: \.id) { iface in
                                    Text(iface.name).tag(iface.id as String?)
                                }
                            }
                        }
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("切换网络模式后需要重启虚拟机才能生效。", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Label("桥接模式需要 com.apple.vm.networking 权限。如果启动失败，将自动回退到 NAT 模式。", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    vmManager.updateNetworkMode(instance, mode: networkMode, bridgedInterfaceID: bridgedInterfaceID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 380)
    }
}

// MARK: - 编辑虚拟机配置弹窗

struct EditVMSheet: View {
    var vmManager: VMManager
    let instance: VMInstance
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var cpuCount: Int
    @State private var memoryGiB: Int
    @State private var diskSizeGiB: Int
    @State private var networkMode: VMNetworkMode
    @State private var bridgedInterfaceID: String?
    @State private var sharedDirectoryPath: String
    @State private var usbImagePath: String
    @State private var showSharedDirPicker = false
    @State private var showUSBImagePicker = false
    @State private var diskResizeError: String?
    @FocusState private var focusedField: ConfigField?

    enum ConfigField: Hashable {
        case cpu, memory, disk
    }

    init(vmManager: VMManager, instance: VMInstance) {
        self.vmManager = vmManager
        self.instance = instance
        self._name = State(initialValue: instance.name)
        self._cpuCount = State(initialValue: instance.cpuCount)
        self._memoryGiB = State(initialValue: instance.memoryGiB)
        self._diskSizeGiB = State(initialValue: instance.diskSizeGiB)
        self._networkMode = State(initialValue: instance.networkMode)
        self._bridgedInterfaceID = State(initialValue: instance.bridgedInterfaceID)
        self._sharedDirectoryPath = State(initialValue: instance.sharedDirectoryPath ?? "")
        self._usbImagePath = State(initialValue: instance.usbImagePath ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.title)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("编辑虚拟机配置")
                                .font(.headline)
                            Text("修改「\(instance.name)」的硬件和功能设置")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("基本信息") {
                    TextField("名称", text: $name)
                }

                Section("硬件配置") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("CPU:")
                                .frame(width: 40, alignment: .leading)
                            TextField("", value: $cpuCount, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .focused($focusedField, equals: .cpu)
                                .onSubmit { clampCPU() }
                            Text("核")
                            Spacer()
                            Stepper("", value: $cpuCount, in: minCPUCount...maxCPUCount)
                                .labelsHidden()
                        }
                        Text("范围: \(minCPUCount) – \(maxCPUCount) 核")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("内存:")
                                .frame(width: 40, alignment: .leading)
                            TextField("", value: $memoryGiB, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .focused($focusedField, equals: .memory)
                                .onSubmit { clampMemory() }
                            Text("GB")
                            Spacer()
                            Stepper("", value: $memoryGiB, in: minMemoryGiB...maxMemoryGiB)
                                .labelsHidden()
                        }
                        Text("范围: \(minMemoryGiB) – \(maxMemoryGiB) GB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if instance.isInstalled {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("磁盘:")
                                    .frame(width: 40, alignment: .leading)
                                TextField("", value: $diskSizeGiB, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                    .focused($focusedField, equals: .disk)
                                    .onSubmit { clampDisk() }
                                Text("GB")
                                Spacer()
                                Stepper("", value: $diskSizeGiB, in: instance.diskSizeGiB...maxDiskGiB, step: 32)
                                    .labelsHidden()
                            }
                            Text("当前 \(instance.diskSizeGiB) GB，仅支持扩容（最大 \(maxDiskGiB) GB）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = diskResizeError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                .onChange(of: focusedField) { _, newValue in
                    if newValue != .cpu { clampCPU() }
                    if newValue != .memory { clampMemory() }
                    if newValue != .disk { clampDisk() }
                }

                Section("网络") {
                    Picker("网络模式", selection: $networkMode) {
                        ForEach(VMNetworkMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Text(networkMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if networkMode == .bridged {
                        let interfaces = VMConfiguration.availableBridgedInterfaces
                        if interfaces.isEmpty {
                            Label("未检测到可用的网络接口", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Picker("桥接接口", selection: $bridgedInterfaceID) {
                                Text("自动选择").tag(nil as String?)
                                ForEach(interfaces, id: \.id) { iface in
                                    Text(iface.name).tag(iface.id as String?)
                                }
                            }
                        }
                    }
                }

                Section("共享文件夹 (VirtioFS)") {
                    HStack {
                        TextField("宿主机共享目录路径", text: $sharedDirectoryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { pickSharedDirectory() }
                        if !sharedDirectoryPath.isEmpty {
                            Button {
                                sharedDirectoryPath = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("清除共享文件夹")
                        }
                    }
                    Text("VM 启动后，共享文件夹将以 macOSGuestAutomountTag 自动挂载到访达侧边栏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("USB 大容量存储") {
                    HStack {
                        TextField("磁盘镜像路径 (ISO/DMG)", text: $usbImagePath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { pickUSBImage() }
                        if !usbImagePath.isEmpty {
                            Button {
                                usbImagePath = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("移除 USB 镜像")
                        }
                    }
                    Text("挂载 ISO 或 DMG 镜像为 USB 存储设备（只读），下次启动时生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("修改硬件配置需要重启虚拟机才能生效")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 720)
    }

    // MARK: - 硬件配置范围

    private var minCPUCount: Int {
        VZVirtualMachineConfiguration.minimumAllowedCPUCount
    }
    private var maxCPUCount: Int {
        ProcessInfo.processInfo.processorCount
    }
    private var minMemoryGiB: Int {
        max(2, Int(VZVirtualMachineConfiguration.minimumAllowedMemorySize / 1024 / 1024 / 1024))
    }
    private var maxMemoryGiB: Int {
        Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / 1024 / 1024 / 1024)
    }
    private var maxDiskGiB: Int { 2048 }

    private func clampCPU() {
        cpuCount = max(minCPUCount, min(cpuCount, maxCPUCount))
    }
    private func clampMemory() {
        memoryGiB = max(minMemoryGiB, min(memoryGiB, maxMemoryGiB))
    }
    private func clampDisk() {
        diskSizeGiB = max(instance.diskSizeGiB, min(diskSizeGiB, maxDiskGiB))
    }

    // MARK: - 文件选择

    private func pickSharedDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择共享文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sharedDirectoryPath = url.path
        }
    }

    private func pickUSBImage() {
        let panel = NSOpenPanel()
        panel.title = "选择 USB 磁盘镜像"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.diskImage, .data]
        if panel.runModal() == .OK, let url = panel.url {
            usbImagePath = url.path
        }
    }

    // MARK: - 保存

    private func save() {
        // 磁盘扩容（如果大小变化了）
        if instance.isInstalled && diskSizeGiB > instance.diskSizeGiB {
            if let error = vmManager.resizeDisk(for: instance, newSizeGiB: diskSizeGiB) {
                diskResizeError = error
                return
            }
        }

        vmManager.updateInstanceConfig(
            instance,
            name: name.trimmingCharacters(in: .whitespaces),
            cpuCount: cpuCount,
            memoryGiB: memoryGiB,
            networkMode: networkMode,
            bridgedInterfaceID: bridgedInterfaceID,
            sharedDirectoryPath: sharedDirectoryPath.isEmpty ? nil : sharedDirectoryPath,
            usbImagePath: usbImagePath.isEmpty ? nil : usbImagePath
        )
        dismiss()
    }
}
