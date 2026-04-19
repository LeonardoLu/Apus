//
//  CreateVMSheet.swift
//  Apus
//

import SwiftUI
import UniformTypeIdentifiers
import Virtualization

/// 创建新虚拟机的表单
struct CreateVMSheet: View {
    var vmManager: VMManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = "macOS 虚拟机"
    @State private var cpuCount = VMConfiguration.defaultCPUCount
    @State private var memoryGiB = VMConfiguration.defaultMemoryGiB
    @State private var diskSizeGiB = VMConfiguration.defaultDiskSizeGiB
    @State private var ipswSource: IPSWSource = .download
    @State private var localIPSWURL: URL?
    @State private var showFileImporter = false
    @State private var networkMode: VMNetworkMode = .nat
    @State private var bridgedInterfaceID: String?
    @FocusState private var focusedField: ConfigField?

    enum IPSWSource: Hashable {
        case download
        case localFile
    }

    enum ConfigField: Hashable {
        case cpu, memory, disk
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
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
                        Text("最低 \(minCPUCount) 核，当前主机共 \(maxCPUCount) 核")
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
                        Text("最低 \(minMemoryGiB) GB，最大 \(maxMemoryGiB) GB，建议 4 GB 以上以获得流畅体验")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                            Stepper("", value: $diskSizeGiB, in: minDiskGiB...maxDiskGiB, step: 32)
                                .labelsHidden()
                        }
                        Text("最低 \(minDiskGiB) GB，最大 \(maxDiskGiB) GB，建议 64 GB 以上以安装应用和存储数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: focusedField) { _, newValue in
                    // 当焦点离开某个输入框时，自动校正参数到合法范围
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
                        Label("桥接模式需要 com.apple.vm.networking 权限，如无该权限将自动回退到 NAT。", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("安装来源") {
                    Picker("IPSW 来源", selection: $ipswSource) {
                        Text("下载最新 macOS").tag(IPSWSource.download)
                        Text("本地 IPSW 文件").tag(IPSWSource.localFile)
                    }
                    .pickerStyle(.radioGroup)

                    if ipswSource == .localFile {
                        HStack {
                            Button("选择文件…") { showFileImporter = true }
                            if let url = localIPSWURL {
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    if ipswSource == .download
                        && FileManager.default.fileExists(
                            atPath: VMConstants.restoreImageURL.path)
                    {
                        Label("检测到已缓存的 IPSW，将跳过下载", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // 底部按钮
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("创建并安装") { createAndInstall() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 420, height: 650)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                localIPSWURL = url
            }
        }
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

    private var minDiskGiB: Int { 32 }
    private var maxDiskGiB: Int { 2048 }

    // MARK: - 参数校正（确保输入值在合法范围内）

    private func clampCPU() {
        cpuCount = max(minCPUCount, min(cpuCount, maxCPUCount))
    }

    private func clampMemory() {
        memoryGiB = max(minMemoryGiB, min(memoryGiB, maxMemoryGiB))
    }

    private func clampDisk() {
        diskSizeGiB = max(minDiskGiB, min(diskSizeGiB, maxDiskGiB))
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (ipswSource == .download || localIPSWURL != nil)
    }

    private func createAndInstall() {
        let instance = vmManager.createInstance(
            name: name.trimmingCharacters(in: .whitespaces),
            cpuCount: cpuCount,
            memoryGiB: memoryGiB,
            diskSizeGiB: diskSizeGiB,
            networkMode: networkMode,
            bridgedInterfaceID: bridgedInterfaceID)

        switch ipswSource {
        case .download:
            vmManager.downloadAndInstall(instance: instance)
        case .localFile:
            if let url = localIPSWURL {
                vmManager.installFromLocalIPSW(instance: instance, ipswURL: url)
            }
        }

        dismiss()
    }
}
