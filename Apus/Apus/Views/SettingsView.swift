//
//  SettingsView.swift
//  Apus
//

import SwiftUI
import UserNotifications

struct SettingsView: View {
    var vmManager: VMManager
    @State private var ipswCacheSize: String = "计算中…"
    @State private var vmStorageSize: String = "计算中…"
    @State private var totalStorageSize: String = "计算中…"
    @State private var showDeleteIPSWConfirmation = false
    @State private var showDeleteAllVMsConfirmation = false
    @State private var showCleanExtraFilesConfirmation = false
    @State private var showCleanDownloadsDirConfirmation = false
    @State private var extraDownloadFiles: [VMConstants.DownloadFileInfo] = []
    @State private var extraFilesTotalSize: String = "0 字节"

    // 通知设置
    @AppStorage(NotificationManager.enabledKey) private var notificationsEnabled = true
    @AppStorage(NotificationManager.downloadCompleteKey) private var notifyDownloadComplete = true
    @AppStorage(NotificationManager.installCompleteKey) private var notifyInstallComplete = true
    @AppStorage(NotificationManager.vmErrorKey) private var notifyVMError = true
    @AppStorage(NotificationManager.vmStoppedKey) private var notifyVMStopped = false
    @AppStorage(NotificationManager.soundEnabledKey) private var notificationSoundEnabled = true
    @State private var notificationAuthStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gear")
                }

            notificationTab
                .tabItem {
                    Label("通知", systemImage: "bell")
                }

            storageTab
                .tabItem {
                    Label("存储", systemImage: "externaldrive")
                }

            aboutTab
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 500)
        .onAppear {
            refreshStorageInfo()
            refreshExtraFiles()
            refreshNotificationStatus()
        }
    }

    // MARK: - 通知

    private var notificationTab: some View {
        Form {
            Section("通知权限") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("授权状态")
                            .font(.body)
                        Text(notificationAuthStatusText)
                            .font(.caption)
                            .foregroundStyle(notificationAuthStatusColor)
                    }

                    Spacer()

                    if notificationAuthStatus == .notDetermined {
                        Button("请求授权") {
                            NotificationManager.requestPermission { _ in
                                refreshNotificationStatus()
                            }
                        }
                    } else if notificationAuthStatus == .denied {
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            Section("通知开关") {
                Toggle("启用通知", isOn: $notificationsEnabled)

                if notificationsEnabled {
                    Toggle("通知声音", isOn: $notificationSoundEnabled)
                }
            }

            if notificationsEnabled {
                Section("通知类别") {
                    Toggle(isOn: $notifyDownloadComplete) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("下载完成")
                            Text("IPSW 恢复镜像下载完成时通知")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $notifyInstallComplete) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("安装完成")
                            Text("macOS 虚拟机安装完成时通知")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $notifyVMError) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("错误通知")
                            Text("虚拟机发生错误或异常停止时通知")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $notifyVMStopped) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("虚拟机停止")
                            Text("虚拟机正常停止运行时通知")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("发送测试通知") {
                        sendTestNotification()
                    }
                    .disabled(notificationAuthStatus != .authorized)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var notificationAuthStatusText: String {
        switch notificationAuthStatus {
        case .authorized: "已授权"
        case .denied: "已拒绝 — 请在系统设置中开启"
        case .provisional: "临时授权"
        case .ephemeral: "临时会话"
        case .notDetermined: "未请求授权"
        @unknown default: "未知状态"
        }
    }

    private var notificationAuthStatusColor: Color {
        switch notificationAuthStatus {
        case .authorized, .provisional, .ephemeral: .green
        case .denied: .red
        case .notDetermined: .orange
        @unknown default: .secondary
        }
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section("数据目录") {
                LabeledContent("应用数据") {
                    HStack {
                        Text(VMConstants.appSupportURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(VMConstants.appSupportURL.path)

                        Button("在 Finder 中打开") {
                            openAppDirectory()
                        }
                    }
                }

                LabeledContent("虚拟机目录") {
                    HStack {
                        Text(VMConstants.vmsDirectoryURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(VMConstants.vmsDirectoryURL.path)

                        Button("打开") {
                            NSWorkspace.shared.open(VMConstants.vmsDirectoryURL)
                        }
                    }
                }

                LabeledContent("下载缓存") {
                    HStack {
                        Text(VMConstants.downloadsDirectoryURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(VMConstants.downloadsDirectoryURL.path)

                        Button("打开") {
                            NSWorkspace.shared.open(VMConstants.downloadsDirectoryURL)
                        }
                    }
                }
            }

            Section("系统信息") {
                LabeledContent("主机 CPU") {
                    Text("\(vmManager.hostCPUCount) 核")
                }
                LabeledContent("主机内存") {
                    Text("\(vmManager.hostMemoryGB) GB")
                }
                LabeledContent("虚拟机数量") {
                    Text("\(vmManager.instances.count) 个")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 存储

    private var storageTab: some View {
        Form {
            Section("存储使用") {
                LabeledContent("虚拟机数据") {
                    Text(vmStorageSize)
                }
                LabeledContent("IPSW 缓存") {
                    Text(ipswCacheSize)
                }
                LabeledContent("总计") {
                    Text(totalStorageSize)
                        .fontWeight(.medium)
                }
            }

            Section("缓存管理") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("IPSW 恢复镜像缓存")
                            .font(.body)
                        Text("删除后，下次安装虚拟机时需要重新下载")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("清除缓存", role: .destructive) {
                        showDeleteIPSWConfirmation = true
                    }
                    .disabled(
                        !FileManager.default.fileExists(
                            atPath: VMConstants.restoreImageURL.path)
                    )
                }
            }

            Section("下载目录管理") {
                if !extraDownloadFiles.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("发现多余文件")
                                .font(.body)
                            Text("下载目录中有 \(extraDownloadFiles.count) 个多余文件（共 \(extraFilesTotalSize)）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("清除多余文件", role: .destructive) {
                            showCleanExtraFilesConfirmation = true
                        }
                    }

                    ForEach(extraDownloadFiles) { file in
                        HStack {
                            Text(file.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(Self.formatBytes(file.size))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    HStack {
                        Text("下载目录无多余文件")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("清除整个下载目录")
                            .font(.body)
                        Text("删除下载目录中的所有文件，包括 IPSW 缓存和其他文件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("清除全部", role: .destructive) {
                        showCleanDownloadsDirConfirmation = true
                    }
                }
            }

            Section("危险操作") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("清除所有虚拟机")
                            .font(.body)
                        Text("删除所有虚拟机及其数据，包括磁盘镜像，此操作不可撤销")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("全部删除", role: .destructive) {
                        showDeleteAllVMsConfirmation = true
                    }
                    .disabled(vmManager.instances.isEmpty)
                }
            }

            Section {
                Button("刷新") {
                    refreshStorageInfo()
                    refreshExtraFiles()
                }
            }
        }
        .formStyle(.grouped)
        .alert("确认清除缓存", isPresented: $showDeleteIPSWConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                try? FileManager.default.removeItem(at: VMConstants.restoreImageURL)
                refreshStorageInfo()
            }
        } message: {
            Text("将删除已下载的 macOS 恢复镜像（IPSW）文件。")
        }
        .alert("确认删除所有虚拟机", isPresented: $showDeleteAllVMsConfirmation) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) {
                vmManager.deleteAllInstances {
                    refreshStorageInfo()
                    refreshExtraFiles()
                }
            }
        } message: {
            Text("将删除所有虚拟机（共 \(vmManager.instances.count) 个）及其全部数据，包括磁盘镜像。此操作不可撤销。")
        }
        .alert("确认清除多余文件", isPresented: $showCleanExtraFilesConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                VMConstants.cleanExtraDownloadFiles()
                refreshStorageInfo()
                refreshExtraFiles()
            }
        } message: {
            Text("将删除下载目录中的 \(extraDownloadFiles.count) 个多余文件。")
        }
        .alert("确认清除整个下载目录", isPresented: $showCleanDownloadsDirConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除全部", role: .destructive) {
                VMConstants.cleanDownloadsDirectory()
                refreshStorageInfo()
                refreshExtraFiles()
            }
        } message: {
            Text("将删除下载目录中的所有文件，包括已缓存的 IPSW 恢复镜像。下次安装虚拟机时需要重新下载。")
        }
    }

    // MARK: - 关于

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Apus")
                .font(.largeTitle.bold())

            Text("macOS 虚拟机管理器")
                .font(.title3)
                .foregroundStyle(.secondary)

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            {
                Text("版本 \(version) (\(build))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("基于 Apple Virtualization Framework")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 辅助方法

    private func refreshNotificationStatus() {
        NotificationManager.checkAuthorizationStatus { status in
            notificationAuthStatus = status
        }
    }

    private func sendTestNotification() {
        NotificationManager.send(
            title: "Apus 测试通知",
            body: "🎉 通知功能运行正常！",
            category: .downloadComplete)
    }

    private func refreshExtraFiles() {
        extraDownloadFiles = VMConstants.getExtraDownloadFiles()
        let totalBytes = extraDownloadFiles.reduce(UInt64(0)) { $0 + $1.size }
        extraFilesTotalSize = Self.formatBytes(totalBytes)
    }

    private func refreshStorageInfo() {
        Task {
            let vmsSize = Self.directorySize(url: VMConstants.vmsDirectoryURL)
            let dlSize = Self.directorySize(url: VMConstants.downloadsDirectoryURL)
            let total = vmsSize + dlSize

            await MainActor.run {
                vmStorageSize = Self.formatBytes(vmsSize)
                ipswCacheSize = Self.formatBytes(dlSize)
                totalStorageSize = Self.formatBytes(total)
            }
        }
    }

    static func directorySize(url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - 全局辅助函数

func openAppDirectory() {
    NSWorkspace.shared.open(VMConstants.appSupportURL)
}
