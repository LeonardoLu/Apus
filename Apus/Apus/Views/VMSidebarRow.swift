//
//  VMSidebarRow.swift
//  Apus
//

import SwiftUI

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
