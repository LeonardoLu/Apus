//
//  ContentView.swift
//  Apus
//

import SwiftUI

struct ContentView: View {
    @Bindable var vmManager: VMManager
    @State private var showCreateSheet = false
    @State private var showDeleteAllConfirmation = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateVMSheet(vmManager: vmManager)
        }
        .alert("确认清除所有虚拟机", isPresented: $showDeleteAllConfirmation) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) {
                vmManager.deleteAllInstances()
            }
        } message: {
            Text("将删除所有虚拟机及其数据，包括磁盘镜像。此操作不可撤销。")
        }
    }

    // MARK: - 侧边栏

    /// 最多在侧边栏底部展示的常用操作数量，超出部分放入 toolbar
    private let maxQuickActions = 3

    /// 常用操作列表（后续可在此处继续追加）
    private var allQuickActions: [(title: String, icon: String, tint: Color, isDestructive: Bool, isDisabled: Bool, action: () -> Void)] {
        [
            (title: "新建虚拟机", icon: "plus.circle.fill", tint: .blue, isDestructive: false, isDisabled: false, action: { showCreateSheet = true }),
            (title: "导入虚拟机", icon: "square.and.arrow.down.fill", tint: .green, isDestructive: false, isDisabled: false, action: { importVM() }),
            (title: "清除所有虚拟机", icon: "trash.circle.fill", tint: .red, isDestructive: true, isDisabled: vmManager.instances.isEmpty, action: { showDeleteAllConfirmation = true }),
        ]
    }

    private var sidebar: some View {
        List(selection: $vmManager.selectedID) {
            ForEach(vmManager.instances) { instance in
                VMSidebarRow(
                    instance: instance,
                    runtime: vmManager.runtimes[instance.id]
                )
                .tag(instance.id)
                .contextMenu {
                    contextMenu(for: instance)
                }
            }
        }
        .navigationTitle("虚拟机")
        .toolbar {
            // 当常用操作超过 maxQuickActions 个时，多余的放入 toolbar 溢出菜单
            if allQuickActions.count > maxQuickActions {
                ToolbarItem {
                    Menu {
                        ForEach(Array(allQuickActions.dropFirst(maxQuickActions).enumerated()), id: \.offset) { _, action in
                            Button(role: action.isDestructive ? .destructive : nil) {
                                action.action()
                            } label: {
                                Label(action.title, systemImage: action.icon)
                            }
                            .disabled(action.isDisabled)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("更多操作")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            quickActionsBar
        }
        .overlay {
            if vmManager.instances.isEmpty {
                ContentUnavailableView {
                    Label("没有虚拟机", systemImage: "desktopcomputer")
                } description: {
                    Text("点击下方「新建虚拟机」创建一个新的 macOS 虚拟机")
                }
            }
        }
    }

    // MARK: - 常用操作栏

    private var quickActionsBar: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("常用操作")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.bottom, 2)

                let visibleActions = Array(allQuickActions.prefix(maxQuickActions))
                ForEach(Array(visibleActions.enumerated()), id: \.offset) { _, action in
                    quickActionButton(
                        title: action.title,
                        icon: action.icon,
                        tint: action.tint,
                        isDisabled: action.isDisabled,
                        action: action.action
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func quickActionButton(
        title: String,
        icon: String,
        tint: Color = .accentColor,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(isDisabled ? .secondary : tint)
                    .frame(width: 20)
                Text(title)
                    .font(.callout)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    // MARK: - 详情区域

    @ViewBuilder
    private var detail: some View {
        if let instance = vmManager.selectedInstance {
            detailContent(for: instance)
        } else {
            ContentUnavailableView(
                "选择虚拟机",
                systemImage: "desktopcomputer",
                description: Text("从侧边栏选择一个虚拟机，或创建一个新的虚拟机")
            )
        }
    }

    @ViewBuilder
    private func detailContent(for instance: VMInstance) -> some View {
        if let runtime = vmManager.runtimes[instance.id], runtime.isActive {
            switch runtime.state {
            case .downloading, .downloadPaused, .installing, .error:
                SetupProgressView(vmManager: vmManager, runtime: runtime, instance: instance)
            case .starting, .running, .pausing, .paused:
                if vmManager.detachedVMIDs.contains(instance.id) {
                    VMDetachedPlaceholder(vmManager: vmManager, instance: instance, runtime: runtime)
                } else {
                    VMRunningView(vmManager: vmManager, runtime: runtime, instance: instance)
                }
            case .idle:
                VMInfoView(vmManager: vmManager, instance: instance)
            }
        } else {
            VMInfoView(vmManager: vmManager, instance: instance)
        }
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func contextMenu(for instance: VMInstance) -> some View {
        let runtime = vmManager.runtimes[instance.id]

        if let runtime, runtime.isActive {
            switch runtime.state {
            case .running:
                Button("暂停") { vmManager.pauseVM(instanceID: instance.id) }
                Button("关机") { vmManager.shutdownVM(instanceID: instance.id) }
                Button("强制停止") { vmManager.stopVM(instanceID: instance.id) }
            case .paused:
                Button("恢复") { vmManager.resumeVM(instanceID: instance.id) }
                Button("强制停止") { vmManager.stopVM(instanceID: instance.id) }
            default:
                EmptyView()
            }
            Divider()
        } else if instance.isInstalled {
            Button("启动") { vmManager.startInstance(instance) }
            Button("以恢复模式启动") { vmManager.startInstanceInRecoveryMode(instance) }
            Divider()
        } else {
            Button("安装 macOS") { vmManager.downloadAndInstall(instance: instance) }
            Divider()
        }

        // 克隆
        if instance.isInstalled {
            Button("克隆虚拟机") { vmManager.cloneInstance(instance) }
        }

        // 导出
        Button("导出虚拟机…") { exportVM(instance) }

        Button("在 Finder 中显示") {
            NSWorkspace.shared.open(instance.directoryURL)
        }

        Divider()

        if instance.isInstalled {
            Button("重置虚拟机") {
                vmManager.resetInstance(instance)
            }
            .disabled(runtime?.isRunningOrPaused == true)
        }

        Button("删除虚拟机", role: .destructive) {
            vmManager.deleteInstance(instance)
        }
        .disabled(runtime?.isRunningOrPaused == true)
    }

    // MARK: - 导入 / 导出

    private func importVM() {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的虚拟机目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请选择包含 config.json 的虚拟机目录"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if vmManager.importInstance(from: url) != nil {
                NotificationManager.send(
                    title: "虚拟机导入成功",
                    body: "已成功导入虚拟机",
                    category: .installComplete)
            } else {
                AppLog.log("[导入] 从 \(url.path) 导入未成功")
            }
        }
    }

    private func exportVM(_ instance: VMInstance) {
        let panel = NSOpenPanel()
        panel.title = "选择导出目的地"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "将虚拟机「\(instance.name)」导出到所选目录"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try vmManager.exportInstance(instance, to: url)
                NotificationManager.send(
                    title: "虚拟机导出成功",
                    body: "「\(instance.name)」已导出到 \(url.lastPathComponent)",
                    category: .installComplete)
            } catch {
                AppLog.log("[导出] 导出失败: \(error.localizedDescription)")
            }
        }
    }
}

