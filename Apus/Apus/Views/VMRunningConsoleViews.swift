//
//  VMRunningConsoleViews.swift
//  Apus
//

import SwiftUI
import AppKit

// MARK: - 运行视图

struct VMRunningView: View {
    var vmManager: VMManager
    var runtime: VMRuntime
    let instance: VMInstance
    @Environment(\.openWindow) private var openWindow
    @State private var showNetworkPopover = false
    @State private var vmIPAddress: String?

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
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

                controlButtons

                // 在新窗口中打开
                Button {
                    vmManager.detachedVMIDs.insert(instance.id)
                    openWindow(value: instance.id)
                } label: {
                    Label("新窗口", systemImage: "macwindow.badge.plus")
                }
                .buttonStyle(.bordered)
                .help("在独立窗口中打开虚拟机")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if let vm = runtime.virtualMachine {
                VMDisplayView(virtualMachine: vm)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在启动虚拟机…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: instance.id) {
            await detectIPPeriodically()
        }
    }

    private func detectIPPeriodically() async {
        while !Task.isCancelled {
            if let mac = instance.macAddress {
                vmIPAddress = VMNetworkHelper.detectIPAddress(forMAC: mac)
            }
            do {
                try await Task.sleep(for: .seconds(vmIPAddress == nil ? 3 : 10))
            } catch {
                break
            }
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        switch runtime.state {
        case .running:
            Button { vmManager.pauseVM(instanceID: instance.id) } label: {
                Label("暂停", systemImage: "pause.fill")
            }
            .buttonStyle(.bordered)

            Button { vmManager.shutdownVM(instanceID: instance.id) } label: {
                Label("关机", systemImage: "power")
            }
            .buttonStyle(.bordered)

            Button { vmManager.stopVM(instanceID: instance.id) } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)

        case .paused:
            Button { vmManager.resumeVM(instanceID: instance.id) } label: {
                Label("继续", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button { vmManager.stopVM(instanceID: instance.id) } label: {
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

    private var statusColor: Color {
        switch runtime.state {
        case .running: .green
        case .paused: .orange
        case .starting, .pausing: .yellow
        default: .gray
        }
    }
}

// MARK: - 独立窗口占位视图

struct VMDetachedPlaceholder: View {
    var vmManager: VMManager
    let instance: VMInstance
    var runtime: VMRuntime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("虚拟机正在独立窗口中运行")
                .font(.title2.bold())

            Text("「\(instance.name)」已在独立窗口中显示")
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Circle()
                    .fill(runtime.state == .running ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(runtime.statusLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let uptime = runtime.uptimeString {
                    Text("· \(uptime)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 16) {
                Button {
                    openWindow(value: instance.id)
                    NSApp.activate()
                } label: {
                    Label("切换到独立窗口", systemImage: "macwindow")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    vmManager.detachedVMIDs.remove(instance.id)
                } label: {
                    Label("返回内嵌显示", systemImage: "rectangle.inset.filled")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
