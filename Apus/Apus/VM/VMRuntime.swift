//
//  VMRuntime.swift
//  Apus
//

import Foundation
import Virtualization

// MARK: - VM 状态

enum VMState: Equatable {
    case idle
    case downloading(progress: Double)
    case downloadPaused(progress: Double)
    case installing(progress: Double)
    case starting
    case running
    case pausing
    case paused
    case error(String)
}

// MARK: - 每个 VM 的运行时（支持多 VM 同时运行）

@Observable
class VMRuntime {
    let instanceID: UUID
    var state: VMState = .idle {
        didSet {
            // 当 VM 进入运行/暂停状态时启动计时器，离开时停止
            if isRunningOrPaused {
                if uptimeTimer == nil { startUptimeTimer() }
            } else {
                stopUptimeTimer()
            }
        }
    }
    var virtualMachine: VZVirtualMachine?
    var startedAt: Date?
    let cpuCount: Int
    let memoryGiB: Int

    @ObservationIgnored var delegate: VMDelegateHandler?
    @ObservationIgnored nonisolated(unsafe) var downloadObserver: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) var downloadTask: URLSessionDownloadTask?
    @ObservationIgnored var downloadResumeData: Data?
    @ObservationIgnored var downloadSourceURL: URL?
    @ObservationIgnored var downloadDestinationURL: URL?
    @ObservationIgnored var isPausingDownload = false
    @ObservationIgnored var installProgressTask: Task<Void, Never>?
    var macOSVersion: String?

    /// 每秒递增的计数器，用于驱动 uptimeString 的 UI 刷新
    private(set) var uptimeTick: UInt = 0
    @ObservationIgnored private var uptimeTimer: Timer?

    init(instanceID: UUID, cpuCount: Int, memoryGiB: Int) {
        self.instanceID = instanceID
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
    }

    deinit {
        uptimeTimer?.invalidate()
    }

    var isActive: Bool {
        switch state {
        case .idle: false
        default: true
        }
    }

    var isRunningOrPaused: Bool {
        switch state {
        case .running, .paused, .starting, .pausing: true
        default: false
        }
    }

    var statusLabel: String {
        switch state {
        case .idle: "空闲"
        case .downloading(let p): "下载中 \(Int(p * 100))%"
        case .downloadPaused(let p): "下载已暂停 \(Int(p * 100))%"
        case .installing(let p): "安装中 \(Int(p * 100))%"
        case .starting: "启动中"
        case .running: "运行中"
        case .pausing: "暂停中"
        case .paused: "已暂停"
        case .error: "错误"
        }
    }

    var stateIcon: String {
        switch state {
        case .idle: "desktopcomputer"
        case .downloading, .installing: "arrow.down.circle.fill"
        case .downloadPaused: "pause.circle.fill"
        case .starting: "play.circle"
        case .running: "play.circle.fill"
        case .pausing: "pause.circle"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var uptimeString: String? {
        // 读取 uptimeTick 以建立 @Observable 观察依赖，确保每秒触发 UI 刷新
        _ = uptimeTick
        guard let startedAt, isRunningOrPaused else { return nil }
        let total = Int(Date().timeIntervalSince(startedAt))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - 运行时间计时器

    func startUptimeTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.uptimeTick &+= 1
        }
    }

    func stopUptimeTimer() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
    }
}
