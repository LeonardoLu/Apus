//
//  ContentView.swift
//  Apus
//

import SwiftUI
import UniformTypeIdentifiers
import Virtualization

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
                NSLog("[Apus Export] 导出失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 侧边栏行

struct VMSidebarRow: View {
    let instance: VMInstance
    var runtime: VMRuntime?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        guard let runtime, runtime.isActive else {
            return instance.isInstalled ? "desktopcomputer" : "questionmark.circle"
        }
        return runtime.stateIcon
    }

    private var iconColor: Color {
        guard let runtime, runtime.isActive else {
            return instance.isInstalled ? .secondary : .gray
        }
        switch runtime.state {
        case .running: return .green
        case .paused: return .orange
        case .downloadPaused: return .orange
        case .downloading, .installing, .starting, .pausing: return .blue
        case .error: return .red
        case .idle: return .secondary
        }
    }

    private var subtitle: String {
        guard let runtime, runtime.isActive else {
            return instance.isInstalled
                ? "\(instance.cpuCount) 核 · \(instance.memoryGiB) GB"
                : "未安装"
        }
        return runtime.statusLabel
    }
}

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

// MARK: - 网络信息弹出面板

struct VMNetworkInfoPopover: View {
    let instance: VMInstance
    @State private var vmIPAddress: String?
    @State private var gatewayIP: String?
    @State private var isDetecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            Label("网络信息", systemImage: "network")
                .font(.headline)

            Divider()

            // 网络模式
            networkInfoRow(
                label: "网络模式",
                value: instance.networkMode.displayName,
                icon: instance.networkMode == .bridged ? "network" : "wifi.router"
            )

            // MAC 地址
            if let mac = instance.macAddress {
                copyableRow(label: "MAC 地址", value: mac, icon: "barcode")
            }

            // VM IP
            HStack {
                Label("虚拟机 IP", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                if isDetecting && vmIPAddress == nil {
                    ProgressView()
                        .controlSize(.mini)
                    Text("检测中…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else if let ip = vmIPAddress {
                    Text(ip)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    copyButton(ip)
                } else {
                    Text("未检测到")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            // 网关 IP
            if let gw = gatewayIP {
                copyableRow(label: "网关 (宿主机)", value: gw, icon: "wifi.router")
            }

            Divider()

            // 使用提示
            VStack(alignment: .leading, spacing: 6) {
                Text("访问提示")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                if let ip = vmIPAddress {
                    HStack(spacing: 4) {
                        Text("从宿主机 SSH 到 VM:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("ssh user@\(ip)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let gw = gatewayIP {
                    HStack(spacing: 4) {
                        Text("从 VM 访问宿主机:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(gw)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if vmIPAddress == nil && !isDetecting {
                    Text("VM 启动后需等待片刻，系统分配 IP 后即可检测到")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // 刷新按钮
            HStack {
                Spacer()
                Button {
                    detectNetworkInfo()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDetecting)
            }
        }
        .padding()
        .frame(minWidth: 340, maxWidth: 340, minHeight: 280, alignment: .top)
        .onAppear {
            detectNetworkInfo()
        }
    }

    // MARK: - 辅助视图

    private func networkInfoRow(label: String, value: String, icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.callout)
        }
    }

    private func copyableRow(label: String, value: String, icon: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            copyButton(value)
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("复制到剪贴板")
    }

    // MARK: - 网络检测

    private func detectNetworkInfo() {
        isDetecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ip = instance.macAddress.flatMap { VMNetworkHelper.detectIPAddress(forMAC: $0) }
            let gw = VMNetworkHelper.detectGatewayIP()
            DispatchQueue.main.async {
                vmIPAddress = ip
                gatewayIP = gw
                isDetecting = false
            }
        }
    }
}

// MARK: - 网络信息辅助工具

enum VMNetworkHelper {
    /// 通过 ARP 表查找 VM 的 IP 地址（根据 MAC 地址匹配）
    static func detectIPAddress(forMAC macAddress: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let targetMAC = normalizeMAC(macAddress)

        for line in output.components(separatedBy: "\n") {
            // ARP 输出格式: ? (192.168.64.2) at a6:64:b3:1d:7e:e0 on bridge100 ifscope [ethernet]
            let parts = line.components(separatedBy: " ")
            guard parts.count >= 4, parts[3] != "(incomplete)" else { continue }
            let arpMAC = normalizeMAC(parts[3])
            if arpMAC == targetMAC {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
        }
        return nil
    }

    /// 获取宿主机网关 IP（bridge100 接口地址）
    static func detectGatewayIP() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = ["bridge100"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") {
                let parts = trimmed.components(separatedBy: " ")
                if parts.count >= 2 {
                    return parts[1]
                }
            }
        }
        return nil
    }

    /// 规范化 MAC 地址：统一为小写、每段补全为两位十六进制
    private static func normalizeMAC(_ mac: String) -> String {
        mac.lowercased()
            .split(separator: ":")
            .map { $0.count == 1 ? "0\($0)" : String($0) }
            .joined(separator: ":")
    }
}
