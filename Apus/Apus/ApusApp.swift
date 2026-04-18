//
//  ApusApp.swift
//  Apus
//

import SwiftUI
import UserNotifications

@main
struct ApusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var vmManager = VMManager()

    var body: some Scene {
        Window("Apus", id: "main") {
            ContentView(vmManager: vmManager)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.vmManager = vmManager
                }
        }
        .defaultSize(width: 1100, height: 768)

        // 独立虚拟机窗口（按 VM ID 打开）
        WindowGroup("虚拟机", for: UUID.self) { $vmID in
            if let vmID {
                VMWindowView(vmManager: vmManager, instanceID: vmID)
            }
        }
        .defaultSize(width: 1024, height: 768)

        // 设置页面（⌘,）
        Settings {
            SettingsView(vmManager: vmManager)
        }

        // 状态栏菜单
        MenuBarExtra {
            StatusBarMenu(vmManager: vmManager)
        } label: {
            Image(systemName: vmManager.menuBarIcon)
        }
    }
}

// MARK: - 状态栏菜单（展示所有 VM 状态 + 系统资源）

struct StatusBarMenu: View {
    var vmManager: VMManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // ── 资源总览 ──
        Section("资源总览") {
            if vmManager.runningCount > 0 {
                Label(
                    "运行中: \(vmManager.runningCount) 台虚拟机",
                    systemImage: "play.circle.fill")
            } else {
                Label("无运行中的虚拟机", systemImage: "desktopcomputer")
            }
            Label(
                "CPU 分配: \(vmManager.totalAllocatedCPUs) / \(vmManager.hostCPUCount) 核",
                systemImage: "cpu")
            Label(
                "内存分配: \(vmManager.totalAllocatedMemoryGiB) / \(vmManager.hostMemoryGB) GB",
                systemImage: "memorychip")
        }

        Divider()

        // ── 虚拟机列表 ──
        if vmManager.instances.isEmpty {
            Text("暂无虚拟机")
                .foregroundStyle(.secondary)
        } else {
            ForEach(vmManager.instances) { instance in
                vmSection(for: instance)
            }
        }

        Divider()

        // ── 批量操作 ──
        if vmManager.runningCount > 0 {
            Button("停止所有虚拟机") {
                vmManager.forceStopAllVMs {}
            }
        }

        Divider()

        // ── 应用操作 ──
        Button("打开窗口") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")

        Button("打开应用目录") {
            openAppDirectory()
        }

        Button("设置…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Divider()

        Button("退出 Apus") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private func vmSection(for instance: VMInstance) -> some View {
        let runtime = vmManager.runtimes[instance.id]

        Section {
            // VM 名称 + 状态
            Label {
                HStack {
                    Text(instance.name)
                    Spacer()
                    if let runtime, runtime.isActive {
                        Text(runtime.statusLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(
                    systemName: runtime?.isActive == true
                        ? runtime!.stateIcon
                        : (instance.isInstalled ? "desktopcomputer" : "questionmark.circle"))
            }

            // 资源 & 运行时间
            if let runtime, runtime.isRunningOrPaused {
                Text("  \(runtime.cpuCount) 核 · \(runtime.memoryGiB) GB 内存")
                    .font(.caption)
                if let uptime = runtime.uptimeString {
                    Text("  运行时间: \(uptime)")
                        .font(.caption)
                }
            } else if let runtime, runtime.isActive {
                if case .downloading(let p) = runtime.state {
                    Text("  下载进度: \(Int(p * 100))%")
                        .font(.caption)
                }
                if case .downloadPaused(let p) = runtime.state {
                    Text("  下载已暂停: \(Int(p * 100))%")
                        .font(.caption)
                }
                if case .installing(let p) = runtime.state {
                    Text("  安装进度: \(Int(p * 100))%")
                        .font(.caption)
                }
                if let version = runtime.macOSVersion {
                    Text("  \(version)")
                        .font(.caption)
                }
            } else {
                Text(
                    "  \(instance.cpuCount) 核 · \(instance.memoryGiB) GB · \(instance.isInstalled ? "已就绪" : "未安装")"
                )
                .font(.caption)
            }

            // 快捷操作
            if let runtime {
                switch runtime.state {
                case .running:
                    Button("  暂停") { vmManager.pauseVM(instanceID: instance.id) }
                    Button("  关机") { vmManager.shutdownVM(instanceID: instance.id) }
                    Button("  强制停止") { vmManager.stopVM(instanceID: instance.id) }
                case .paused:
                    Button("  恢复") { vmManager.resumeVM(instanceID: instance.id) }
                    Button("  强制停止") { vmManager.stopVM(instanceID: instance.id) }
                case .downloading:
                    Button("  暂停下载") { vmManager.pauseDownload(instanceID: instance.id) }
                    Button("  取消下载") { vmManager.cancelDownload(instanceID: instance.id) }
                case .downloadPaused:
                    Button("  继续下载") { vmManager.resumeDownload(instance: instance) }
                    Button("  取消下载") { vmManager.cancelDownload(instanceID: instance.id) }
                default:
                    EmptyView()
                }
            } else if instance.isInstalled {
                Button("  启动") { vmManager.startInstance(instance) }
            }
        }
    }
}

// MARK: - 应用代理

class AppDelegate: NSObject, NSApplicationDelegate {
    var vmManager: VMManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 早于 SwiftUI 中 `VMManager` 初始化时也要保证目录与日志句柄就绪
        VMConstants.ensureDirectoriesExist()
        AppLog.prepare()
        let version =
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        AppLog.log("应用启动，版本 \(version) (\(build))，日志目录: \(VMConstants.logsDirectoryURL.path)")
        // 初始化通知系统并请求权限
        NotificationManager.setup()
        NotificationManager.requestPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.log("应用即将退出")
        AppLog.flushAndClose()
    }

    /// 关闭窗口后不退出（保留在状态栏）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 退出时确保所有虚拟机正确关闭
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vmManager, vmManager.hasActiveVMs else {
            return .terminateNow
        }

        vmManager.forceStopAllVMs {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
