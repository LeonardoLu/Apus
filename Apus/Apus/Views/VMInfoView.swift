//
//  VMInfoView.swift
//  Apus
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - VM 信息视图

struct VMInfoView: View {
    var vmManager: VMManager
    let instance: VMInstance
    @State private var showDeleteConfirmation = false
    @State private var showResetConfirmation = false
    @State private var showInstallSheet = false
    @State private var showNetworkSettings = false
    @State private var showEditSheet = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: instance.isInstalled ? "desktopcomputer" : "questionmark.circle")
                .font(.system(size: 56))
                .foregroundStyle(instance.isInstalled ? .green : .secondary)

            Text(instance.name)
                .font(.largeTitle.bold())

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("CPU").foregroundStyle(.secondary)
                    Text("\(instance.cpuCount) 核")
                }
                GridRow {
                    Text("内存").foregroundStyle(.secondary)
                    Text("\(instance.memoryGiB) GB")
                }
                GridRow {
                    Text("磁盘").foregroundStyle(.secondary)
                    Text("\(instance.diskSizeGiB) GB")
                }
                GridRow {
                    Text("创建时间").foregroundStyle(.secondary)
                    Text(instance.createdAt, style: .date)
                }
                GridRow {
                    Text("网络").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: instance.networkMode == .bridged ? "network" : "wifi.router")
                            .foregroundStyle(instance.networkMode == .bridged ? .blue : .secondary)
                            .font(.caption)
                        Text(instance.networkMode.displayName)
                    }
                }
                if let macAddress = instance.macAddress {
                    GridRow {
                        Text("MAC 地址").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(macAddress)
                                .font(.caption.monospaced())
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(macAddress, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .help("复制 MAC 地址")
                        }
                    }
                }
                if let sharedPath = instance.sharedDirectoryPath {
                    GridRow {
                        Text("共享文件夹").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.person.crop")
                                .foregroundStyle(.blue)
                                .font(.caption)
                            Text(sharedPath)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(sharedPath)
                        }
                    }
                }
                if let usbPath = instance.usbImagePath {
                    GridRow {
                        Text("USB 镜像").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "externaldrive.fill.badge.plus")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text(URL(fileURLWithPath: usbPath).lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                                .help(usbPath)
                        }
                    }
                }
                GridRow {
                    Text("状态").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(instance.isInstalled ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(instance.isInstalled ? "已安装" : "未安装")
                    }
                }
                GridRow {
                    Text("路径").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(instance.directoryURL.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(instance.directoryURL.path)
                        Button {
                            NSWorkspace.shared.open(instance.directoryURL)
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("在 Finder 中打开")
                    }
                }
            }

            HStack(spacing: 16) {
                if instance.isInstalled {
                    Button {
                        vmManager.startInstance(instance)
                    } label: {
                        Label("启动虚拟机", systemImage: "play.fill")
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vmManager.runtimes[instance.id]?.isActive == true)
                } else {
                    Button {
                        showInstallSheet = true
                    } label: {
                        Label("安装 macOS", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(vmManager.runtimes[instance.id]?.isActive == true)
                }

                // 编辑配置
                Button {
                    showEditSheet = true
                } label: {
                    Label("编辑配置", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(vmManager.runtimes[instance.id]?.isRunningOrPaused == true)

                if instance.isInstalled {
                    Menu {
                        Button("以恢复模式启动") {
                            vmManager.startInstanceInRecoveryMode(instance)
                        }
                        .disabled(vmManager.runtimes[instance.id]?.isActive == true)

                        Divider()

                        Button("克隆虚拟机") {
                            vmManager.cloneInstance(instance)
                        }

                        Divider()

                        Button("重置虚拟机") {
                            showResetConfirmation = true
                        }
                        .disabled(vmManager.runtimes[instance.id]?.isRunningOrPaused == true)
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.large)
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showInstallSheet) {
            InstallMacOSSheet(vmManager: vmManager, instance: instance)
        }
        .sheet(isPresented: $showNetworkSettings) {
            NetworkSettingsSheet(vmManager: vmManager, instance: instance)
        }
        .sheet(isPresented: $showEditSheet) {
            EditVMSheet(vmManager: vmManager, instance: instance)
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                vmManager.deleteInstance(instance)
            }
        } message: {
            Text("将删除「\(instance.name)」的所有数据，包括磁盘镜像。此操作不可撤销。")
        }
        .alert("确认重置", isPresented: $showResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                vmManager.resetInstance(instance)
            }
        } message: {
            Text("将清除「\(instance.name)」的安装数据（磁盘镜像、系统文件等），但保留虚拟机配置。重置后需要重新安装 macOS。")
        }
    }
}

// MARK: - 安装 macOS 弹窗（用于重置后重新安装）

struct InstallMacOSSheet: View {
    var vmManager: VMManager
    let instance: VMInstance
    @Environment(\.dismiss) private var dismiss

    @State private var ipswSource: IPSWSource = .download
    @State private var localIPSWURL: URL?
    @State private var showFileImporter = false

    enum IPSWSource: Hashable {
        case download
        case localFile
    }

    private var hasCachedIPSW: Bool {
        VMConstants.findCachedIPSW() != nil
    }

    private var isValid: Bool {
        ipswSource == .download || localIPSWURL != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("安装 macOS")
                                .font(.headline)
                            Text("为「\(instance.name)」安装 macOS 系统")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
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

                    if ipswSource == .download && hasCachedIPSW {
                        Label("检测到已缓存的 IPSW，将跳过下载", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("开始安装") { install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 400, height: 300)
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

    private func install() {
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
