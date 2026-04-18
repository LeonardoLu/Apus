//
//  SetupView.swift
//  Apus
//

import SwiftUI

/// 下载/安装进度视图（每个 VM 独立运行时）
struct SetupProgressView: View {
    var vmManager: VMManager
    var runtime: VMRuntime
    let instance: VMInstance
    @State private var showCancelConfirmation = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: stateIcon)
                .font(.system(size: 56))
                .foregroundStyle(stateIconColor)
                .symbolEffect(.pulse, options: .repeating, isActive: isAnimating)

            Text(instance.name)
                .font(.largeTitle.bold())

            // macOS 版本信息
            if let version = runtime.macOSVersion {
                Text(version)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Group {
                switch runtime.state {
                case .downloading(let progress):
                    downloadingSection(progress: progress)
                case .downloadPaused(let progress):
                    downloadPausedSection(progress: progress)
                case .installing(let progress):
                    progressSection(
                        title: "正在安装 macOS…",
                        systemImage: "shippingbox",
                        progress: progress)
                case .error(let message):
                    errorSection(message: message)
                default:
                    EmptyView()
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .alert("确认取消下载", isPresented: $showCancelConfirmation) {
            Button("继续下载", role: .cancel) {}
            Button("取消下载", role: .destructive) {
                vmManager.cancelDownload(instanceID: instance.id)
            }
        } message: {
            Text("取消后将丢失已下载的进度，下次需要重新下载。")
        }
    }

    // MARK: - 状态图标

    private var stateIcon: String {
        switch runtime.state {
        case .downloading: "arrow.down.circle"
        case .downloadPaused: "pause.circle"
        case .installing: "shippingbox"
        case .error: "exclamationmark.triangle"
        default: "macbook.and.arrow.down"
        }
    }

    private var stateIconColor: Color {
        switch runtime.state {
        case .downloading: .blue
        case .downloadPaused: .orange
        case .installing: .blue
        case .error: .red
        default: .blue
        }
    }

    private var isAnimating: Bool {
        switch runtime.state {
        case .downloading, .installing: true
        default: false
        }
    }

    // MARK: - 下载中

    private func downloadingSection(progress: Double) -> some View {
        VStack(spacing: 16) {
            Label("正在下载 macOS 恢复镜像…", systemImage: "arrow.down.circle")
                .font(.headline)

            ProgressView(value: max(0, progress), total: 1.0)
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)

            Text("\(Int(progress * 100))%")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    vmManager.pauseDownload(instanceID: instance.id)
                } label: {
                    Label("暂停下载", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showCancelConfirmation = true
                } label: {
                    Label("取消下载", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }

            Text("请勿关闭应用")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 下载已暂停

    private func downloadPausedSection(progress: Double) -> some View {
        VStack(spacing: 16) {
            Label("下载已暂停", systemImage: "pause.circle")
                .font(.headline)
                .foregroundStyle(.orange)

            ProgressView(value: max(0, progress), total: 1.0)
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)

            Text("已完成 \(Int(progress * 100))%")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    vmManager.resumeDownload(instance: instance)
                } label: {
                    Label("继续下载", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    showCancelConfirmation = true
                } label: {
                    Label("取消下载", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 通用进度

    private func progressSection(title: String, systemImage: String, progress: Double) -> some View
    {
        VStack(spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            ProgressView(value: max(0, progress), total: 1.0)
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)

            Text("\(Int(progress * 100))%")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("请勿关闭应用")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 错误

    private func errorSection(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.red)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button {
                    vmManager.dismissError(instanceID: instance.id)
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    vmManager.deleteInstance(instance)
                } label: {
                    Label("删除虚拟机", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
