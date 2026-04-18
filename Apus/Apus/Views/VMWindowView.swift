//
//  VMWindowView.swift
//  Apus
//

import SwiftUI
import Virtualization

/// 独立窗口中展示的虚拟机视图
struct VMWindowView: View {
    var vmManager: VMManager
    let instanceID: UUID
    @State private var showCloseAlert = false
    @State private var windowDelegate: VMWindowCloseDelegate?
    @State private var showNetworkPopover = false
    @State private var vmIPAddress: String?

    private var instance: VMInstance? {
        vmManager.instanceFor(id: instanceID)
    }

    private var runtime: VMRuntime? {
        vmManager.runtimes[instanceID]
    }

    var body: some View {
        Group {
            if let instance, let runtime, runtime.isRunningOrPaused {
                VStack(spacing: 0) {
                    // 工具栏
                    vmToolbar(instance: instance, runtime: runtime)
                    Divider()
                    // VM 显示区域
                    if let vm = runtime.virtualMachine {
                        VMDisplayView(virtualMachine: vm)
                    } else {
                        loadingPlaceholder
                    }
                }
            } else {
                vmStoppedPlaceholder
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(WindowAccessor { window in
            setupWindowDelegate(for: window)
        })
        .alert("关闭虚拟机窗口", isPresented: $showCloseAlert) {
            Button("停止虚拟机", role: .destructive) {
                vmManager.stopVM(instanceID: instanceID)
                vmManager.detachedVMIDs.remove(instanceID)
                closeWindow()
            }
            Button("返回内嵌显示") {
                vmManager.detachedVMIDs.remove(instanceID)
                closeWindow()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请选择关闭窗口后的操作")
        }
        .onChange(of: runtime?.isRunningOrPaused) { _, newValue in
            // VM 停止后自动关闭独立窗口
            if newValue != true {
                vmManager.detachedVMIDs.remove(instanceID)
                closeWindow()
            }
        }
        .task(id: instanceID) {
            await detectIPPeriodically()
        }
    }

    // MARK: - 网络检测

    private func detectIPPeriodically() async {
        while !Task.isCancelled {
            if let mac = instance?.macAddress {
                vmIPAddress = VMNetworkHelper.detectIPAddress(forMAC: mac)
            }
            do {
                try await Task.sleep(for: .seconds(vmIPAddress == nil ? 3 : 10))
            } catch {
                break
            }
        }
    }

    // MARK: - 工具栏

    private func vmToolbar(instance: VMInstance, runtime: VMRuntime) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(for: runtime))
                    .frame(width: 8, height: 8)
                Text(instance.name)
                    .font(.headline)
                Text("— \(runtime.statusLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let uptime = runtime.uptimeString {
                    Text("· \(uptime)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // 资源显示
            HStack(spacing: 8) {
                Label("\(runtime.cpuCount) 核", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("\(runtime.memoryGiB) GB", systemImage: "memorychip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 网络信息
            Button {
                showNetworkPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "network")
                    if let ip = vmIPAddress {
                        Text(ip)
                            .monospacedDigit()
                    } else {
                        Text("网络")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showNetworkPopover) {
                VMNetworkInfoPopover(instance: instance)
            }

            // 操作按钮
            controlButtons(runtime: runtime)

            // 返回内嵌
            Button {
                vmManager.detachedVMIDs.remove(instanceID)
                closeWindow()
            } label: {
                Label("返回内嵌", systemImage: "rectangle.inset.filled")
            }
            .buttonStyle(.bordered)
            .help("关闭独立窗口，返回管理窗口中内嵌显示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func controlButtons(runtime: VMRuntime) -> some View {
        switch runtime.state {
        case .running:
            Button { vmManager.pauseVM(instanceID: instanceID) } label: {
                Label("暂停", systemImage: "pause.fill")
            }
            .buttonStyle(.bordered)

            Button { vmManager.shutdownVM(instanceID: instanceID) } label: {
                Label("关机", systemImage: "power")
            }
            .buttonStyle(.bordered)

            Button { vmManager.stopVM(instanceID: instanceID) } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)

        case .paused:
            Button { vmManager.resumeVM(instanceID: instanceID) } label: {
                Label("继续", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button { vmManager.stopVM(instanceID: instanceID) } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)

        case .starting, .pausing:
            ProgressView()
                .controlSize(.small)

        default:
            EmptyView()
        }
    }

    // MARK: - 占位视图

    private var loadingPlaceholder: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("正在启动虚拟机…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var vmStoppedPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("虚拟机已停止")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("此窗口即将关闭")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 辅助方法

    private func statusColor(for runtime: VMRuntime) -> Color {
        switch runtime.state {
        case .running: .green
        case .paused: .orange
        case .starting, .pausing: .yellow
        default: .gray
        }
    }

    private func setupWindowDelegate(for window: NSWindow) {
        guard windowDelegate == nil else { return }
        let delegate = VMWindowCloseDelegate { [self] in
            // 如果 VM 还在运行，显示确认弹窗
            if runtime?.isRunningOrPaused == true {
                showCloseAlert = true
                return false
            }
            // VM 已停止，直接关闭
            vmManager.detachedVMIDs.remove(instanceID)
            return true
        }
        delegate.originalDelegate = window.delegate
        window.delegate = delegate
        windowDelegate = delegate
    }

    private func closeWindow() {
        windowDelegate?.allowClose = true
        NSApp.keyWindow?.close()
    }
}

// MARK: - 窗口关闭代理

/// 拦截窗口关闭事件并转发其他代理调用
class VMWindowCloseDelegate: NSObject, NSWindowDelegate {
    var shouldCloseHandler: () -> Bool
    weak var originalDelegate: (any NSWindowDelegate)?
    var allowClose = false

    init(shouldCloseHandler: @escaping () -> Bool) {
        self.shouldCloseHandler = shouldCloseHandler
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return true }
        return shouldCloseHandler()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        originalDelegate?.windowDidBecomeKey?(notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        originalDelegate?.windowDidResignKey?(notification)
    }

    func windowDidResize(_ notification: Notification) {
        originalDelegate?.windowDidResize?(notification)
    }

    func windowWillClose(_ notification: Notification) {
        originalDelegate?.windowWillClose?(notification)
    }

    func windowDidMove(_ notification: Notification) {
        originalDelegate?.windowDidMove?(notification)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        originalDelegate?.windowDidBecomeMain?(notification)
    }

    func windowDidResignMain(_ notification: Notification) {
        originalDelegate?.windowDidResignMain?(notification)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        originalDelegate?.windowDidMiniaturize?(notification)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        originalDelegate?.windowDidDeminiaturize?(notification)
    }
}

// MARK: - NSWindow 访问器

/// 用于在 SwiftUI 中获取 NSWindow 引用的辅助视图
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
